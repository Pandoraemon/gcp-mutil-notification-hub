"""通用 Webhook 发送器：出口令牌桶 + 有限次退避重试 + 失败分类。

三个渠道的投递循环完全相同，差别只在两处，由子类实现：
- prepare(target, payload) -> (url, body)：签名放 body（飞书）还是 query（钉钉），或不签名（企微）；
- classify(resp) -> Exception | None：None 表示成功，否则返回应抛出的 PermanentError / TransientError。

⚠️ 三个平台都会在业务失败时返回 HTTP 200（错误码在响应体里）。只判断 status_code == 200
会导致所有消息被静默丢弃而日志显示\"发送成功\" —— 因此 classify 是每个子类的必答题。

ack / nack 的唯一判据是「重试能否改变结果」：
- PermanentError：立即抛出、不做函数内重试（main.py ack + ERROR）；
- TransientError：函数内最多 MAX_ATTEMPTS 次退避重试，仍失败则抛出（main.py nack → Pub/Sub 重投 → DLQ）；
- 子类可通过 should_retry_in_process() 让某些瞬时错误跳过函数内重试，直接交给 Pub/Sub 退避
  （例如钉钉 130101 会封禁 10 分钟，1/2/4 秒的函数内重试只会白耗令牌）。
"""

import logging
import random
import time
from abc import ABC, abstractmethod
from collections.abc import Mapping
from typing import Any

import requests

from channels.rate_limiter import TokenBucket
from config import Config, Target
from errors import AlertHubError, PermanentError, TransientError
from log_utils import mask_webhook

logger = logging.getLogger(__name__)

MAX_ATTEMPTS = 3

# 连接超时 3 秒、读超时 10 秒：三次尝试 + 退避的最坏耗时仍远小于函数 60 秒超时
REQUEST_TIMEOUT = (3, 10)


def code_fields(channel: str, exc: BaseException | None) -> dict[str, Any]:
    """失败日志的排障字段：http_status / platform_code，飞书额外保留 feishu_code（向后兼容）。"""
    fields: dict[str, Any] = {
        'channel': channel,
        'http_status': getattr(exc, 'http_status', None),
        'platform_code': getattr(exc, 'platform_code', None),
    }
    if channel == 'feishu':
        fields['feishu_code'] = getattr(exc, 'feishu_code', None)
    return fields


def classify_errcode_response(resp: requests.Response, *, platform: str,
                              permanent_codes: Mapping[int, str],
                              code_key: str = 'errcode') -> AlertHubError | None:
    """企业微信 / 钉钉共用的响应分类：HTTP 200 + errcode=0 才算成功。

    - 429 / 5xx / 200 却非 JSON / JSON 不是对象 → TransientError（重试可能变好；进 DLQ 可见）
    - 其他非 200 HTTP 状态 → PermanentError（与飞书一致：多为 URL 写错，重试不会变对）
    - errcode ∈ permanent_codes → PermanentError（配置/参数问题）
    - 其余非 0 errcode（含 -1 系统繁忙、限流码、未知码）→ TransientError
      未知码按瞬时处理：最坏结果是多重试几次后进 DLQ（可重放），而不是把告警静默 ack 掉
    """
    status = resp.status_code
    if status == 429:
        return TransientError(f'{platform} 429 rate limited', http_status=status)
    if status >= 500:
        return TransientError(f'{platform} {status}', http_status=status)
    if status != 200:
        return PermanentError(f'{platform} HTTP {status}: {resp.text[:200]}', http_status=status)

    try:
        data = resp.json()
    except ValueError:
        return TransientError(f'{platform} non-JSON 200 response: {resp.text[:200]}', http_status=status)
    if not isinstance(data, dict):
        return TransientError(f'{platform} non-object JSON 200 response: {resp.text[:200]}',
                              http_status=status)

    code = data.get(code_key, -1)
    # bool 是 int 的子类：{"errcode": false} 不能被当成 0
    platform_code = code if isinstance(code, int) and not isinstance(code, bool) else None
    if platform_code == 0:
        return None
    if platform_code in permanent_codes:
        return PermanentError(f'{platform} {code_key}={code}: {permanent_codes[platform_code]}',
                              http_status=status, platform_code=platform_code)
    return TransientError(f'{platform} {code_key}={code}: {resp.text[:200]}',
                          http_status=status, platform_code=platform_code)


class WebhookSender(ABC):
    """持有连接池与令牌桶的发送器 —— 必须作为模块级单例使用（见 main.py）。"""

    channel: str = ''

    def __init__(self, bucket: TokenBucket | None = None) -> None:
        self._session = requests.Session()
        self._bucket = bucket or TokenBucket(rate_per_minute=Config.MAX_SENDS_PER_MINUTE)

    @abstractmethod
    def prepare(self, target: Target, payload: dict[str, Any]) -> tuple[str, dict[str, Any]]:
        """返回 (请求 URL, JSON 请求体)。签名在此完成（每次 send 只调用一次）。"""

    @abstractmethod
    def classify(self, resp: requests.Response) -> AlertHubError | None:
        """None 表示成功；否则返回应抛出的异常（永久 / 瞬时），并带上 http_status / platform_code。"""

    def should_retry_in_process(self, exc: AlertHubError) -> bool:  # pylint: disable=unused-argument
        """瞬时错误是否值得在函数内重试。默认是；子类可对\"短时间内必然再失败\"的错误码返回 False。"""
        return True

    def send(self, target: Target, payload: dict[str, Any]) -> None:
        url, body = self.prepare(target, payload)

        last_exc: AlertHubError = TransientError('no attempt was made')
        for attempt in range(MAX_ATTEMPTS):
            # 速率控制在【出口】而非实例数上（见 rate_limiter.py 的说明）。
            # 每次 HTTP 尝试都取令牌：内部重试也是真实出口请求，否则 429/5xx 风暴下
            # 实际出口速率会是配置值的 MAX_ATTEMPTS 倍。
            waited = self._bucket.acquire()
            if waited > 0:
                logger.info('Rate limited by local token bucket',
                            extra={'waited_s': round(waited, 2), 'group': target.group_name,
                                   'attempt': attempt + 1, 'channel': self.channel})

            try:
                resp = self._session.post(url, json=body, timeout=REQUEST_TIMEOUT)
            except requests.RequestException as exc:
                last_exc = TransientError(f'network error: {exc}')
            else:
                outcome = self.classify(resp)
                if outcome is None:
                    logger.debug('IM platform accepted the message',
                                 extra={'group': target.group_name, 'attempt': attempt + 1,
                                        'channel': self.channel})
                    return
                last_exc = outcome

            if isinstance(last_exc, PermanentError):
                raise last_exc

            if not self.should_retry_in_process(last_exc):
                # 不做函数内重试 ≠ 放弃：异常照常抛出 → main.py nack → Pub/Sub 指数退避重投
                logger.warning('Transient failure not retried in-process, deferring to Pub/Sub redelivery',
                               extra={'attempt': attempt + 1, 'group': target.group_name,
                                      'webhook': mask_webhook(target.webhook),
                                      'error': str(last_exc), **code_fields(self.channel, last_exc)})
                raise last_exc

            if attempt == MAX_ATTEMPTS - 1:
                break

            backoff = min(2 ** attempt, 8) + random.uniform(0, 0.5)   # 抖动避免同步重试
            logger.warning('Send failed, retrying',
                           extra={'attempt': attempt + 1, 'backoff_s': round(backoff, 2),
                                  'group': target.group_name,
                                  'webhook': mask_webhook(target.webhook),
                                  'error': str(last_exc), **code_fields(self.channel, last_exc)})
            time.sleep(backoff)

        raise last_exc
