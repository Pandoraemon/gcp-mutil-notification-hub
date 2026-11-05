"""飞书发送：签名、业务码校验、退避重试与出口速率控制。

⚠️ 飞书返回 HTTP 200 不代表成功。签名错误、机器人被移出群、参数非法时，
飞书照样返回 200，错误码在响应体里（如 {"code":19021,"msg":"sign match fail"}）。
只判断 status_code == 200 会导致所有卡片被静默丢弃而日志显示"发送成功"。

令牌桶 + 退避重试循环在 channels.base.WebhookSender（三个渠道共用），
本模块只负责飞书特有的两件事：签名放进请求体（prepare），以及业务码分类（classify）。
"""

import time
from typing import Any

import requests

from channels.base import MAX_ATTEMPTS
from channels.base import WebhookSender as BaseWebhookSender
from channels.feishu.signer import sign
from config import Target
from errors import AlertHubError, PermanentError, TransientError

__all__ = ['MAX_ATTEMPTS', 'PERMANENT_CODES', 'FeishuSender', 'WebhookSender']

# 飞书业务错误码分类：这些是配置问题，重试无意义
PERMANENT_CODES = {
    19001: 'param invalid: incoming webhook access token invalid（webhook URL 里的 token 不对）',
    19021: 'sign match fail（签名密钥与机器人配置不匹配）',
    19024: 'invalid timestamp（客户端时钟偏移过大）',
    9499: 'bot not in chat（机器人已被移出群）',
}


class FeishuSender(BaseWebhookSender):
    """飞书自定义机器人发送器 —— 必须作为模块级单例使用。"""

    channel = 'feishu'

    def prepare(self, target: Target, payload: dict[str, Any]) -> tuple[str, dict[str, Any]]:
        body: dict[str, Any] = {'msg_type': 'interactive', 'card': payload}
        if target.secret:
            timestamp = str(int(time.time()))
            body['timestamp'] = timestamp
            body['sign'] = sign(timestamp, target.secret)
        return target.webhook, body

    def classify(self, resp: requests.Response) -> AlertHubError | None:
        return self._classify(resp)

    @staticmethod
    def _classify(resp: requests.Response) -> AlertHubError | None:
        """None 表示成功；否则返回应抛出的异常（永久 / 瞬时），并带上 http_status / feishu_code。"""
        status = resp.status_code
        if status == 429:
            return TransientError('feishu 429 rate limited', http_status=status)
        if status >= 500:
            return TransientError(f'feishu {status}', http_status=status)
        if status != 200:
            return PermanentError(f'feishu HTTP {status}: {resp.text[:200]}', http_status=status)

        # HTTP 200 —— 必须继续检查业务码
        try:
            data = resp.json()
        except ValueError:
            # 200 却不是 JSON：多半是网关/代理返回的错误页，按瞬时处理以便进入 DLQ 可见
            return TransientError(f'feishu non-JSON 200 response: {resp.text[:200]}',
                                  http_status=status)
        if not isinstance(data, dict):
            # 合法 JSON 但不是对象（list / str / null）：同样不是飞书的正常响应形状
            return TransientError(f'feishu non-object JSON 200 response: {resp.text[:200]}',
                                  http_status=status)

        code = data.get('code', -1)
        if isinstance(code, int) and not isinstance(code, bool) and code == 0:
            return None
        feishu_code = code if isinstance(code, int) and not isinstance(code, bool) else None
        if code in PERMANENT_CODES:
            return PermanentError(f'feishu code={code}: {PERMANENT_CODES[code]}',
                                  http_status=status, feishu_code=feishu_code)
        return TransientError(f'feishu code={code}: {resp.text[:200]}',
                              http_status=status, feishu_code=feishu_code)


# 向后兼容：迁移前的引用路径是 feishu.webhook_sender.WebhookSender
WebhookSender = FeishuSender
