"""钉钉自定义机器人发送：加签放 query、errcode 分类、130101 不做函数内重试。

⚠️ 钉钉对业务失败同样返回 HTTP 200，错误码在 errcode 字段（0 才是成功）。

- 加签：https://open.dingtalk.com/document/robots/customize-robot-security-settings
- 消息类型：https://open.dingtalk.com/document/orgapp/custom-bot-send-message-type
- 错误码：钉钉开放平台错误码页为前端渲染，下列取值来自公开资料与社区实测（待官方页面二次确认）。
"""

import time
from typing import Any

import requests

from channels.base import WebhookSender, classify_errcode_response
from channels.dingtalk.signer import sign
from config import Target
from errors import AlertHubError

# 发送太快（20 条/分钟），触发后限流约 10 分钟
RATE_LIMITED_CODE = 130101

# 重试不可能改变结果的错误：安全设置不符（签名/关键词/IP）、token 不存在、请求格式错误。
# 未列出的 errcode（含 -1 系统繁忙、130101 限流、未知码）一律按瞬时处理。
PERMANENT_CODES: dict[int, str] = {
    310000: '安全设置校验失败（sign not match / keywords not in content / ip not in whitelist）',
    300001: 'access_token 不存在或机器人已被删除',
    300005: 'token is not exist（webhook token 无效）',
    40035: '缺少参数 json（请求体非法）',
    43004: '无效的 HTTP HEADER Content-Type',
}


class DingtalkSender(WebhookSender):
    """钉钉自定义机器人发送器 —— 必须作为模块级单例使用。"""

    channel = 'dingtalk'

    def prepare(self, target: Target, payload: dict[str, Any]) -> tuple[str, dict[str, Any]]:
        if not target.secret:
            # DINGTALK_*_SECRET=NONE：机器人使用「自定义关键词」或「IP 地址段」安全设置，不加签
            return target.webhook, payload
        timestamp_ms = str(int(time.time() * 1000))
        url = f'{target.webhook}&timestamp={timestamp_ms}&sign={sign(timestamp_ms, target.secret)}'
        return url, payload

    def classify(self, resp: requests.Response) -> AlertHubError | None:
        return classify_errcode_response(resp, platform='dingtalk', permanent_codes=PERMANENT_CODES)

    def should_retry_in_process(self, exc: AlertHubError) -> bool:
        # 130101 会封禁约 10 分钟：函数内 1/2/4 秒的重试必然再失败，只会白耗令牌并拉长函数执行时间。
        # 直接抛出交给 Pub/Sub 指数退避（min/max backoff 由订阅的 retry policy 决定）。
        return exc.platform_code != RATE_LIMITED_CODE
