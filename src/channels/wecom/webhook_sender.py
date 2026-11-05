"""企业微信群机器人发送：无签名（凭据就是 URL 里的 key），只做 errcode 分类。

⚠️ 企业微信对业务失败同样返回 HTTP 200，错误码在 errcode 字段（0 才是成功）。

错误码来源：
- 全局错误码 https://developer.work.weixin.qq.com/document/path/90313
- 群机器人频率限制 https://developer.work.weixin.qq.com/document/path/91770（每个机器人 20 条/分钟）
"""

from typing import Any

import requests

from channels.base import WebhookSender, classify_errcode_response
from config import Target
from errors import AlertHubError

# 重试不可能改变结果的错误：webhook 失效 / 机器人被移出或停用 / 请求参数非法 / 消息超限。
# 未列出的 errcode（含 -1 系统繁忙、45009 接口调用超过限制、45033 并发超限）一律按瞬时处理。
PERMANENT_CODES: dict[int, str] = {
    93000: '消息推送 webhook url 不合法或已被移除出群',
    93001: '当前群聊不允许推送消息',
    93004: '消息推送被停用',
    93008: '机器人不在群里',
    93017: '请求内容不能为空',
    40008: '不合法的 msgtype',
    40035: '不合法的参数',
    40039: '不合法的 url 长度（上限 1024 字节）',
    40058: '不合法的参数',
    40063: '参数为空',
    44004: '消息 content 为空',
    45002: '消息内容大小超过限制',
    42030: 'template_card 缺失 appid / url',
    42031: 'template_card.card_type 不合法',
    42033: 'template_card 缺失 title',
    42035: 'template_card.horizontal_content_list 数组长度不合法',
}

# 明确的瞬时码（仅作文档与测试锚点；未知码本来就按瞬时处理）
TRANSIENT_CODES: dict[int, str] = {
    -1: '系统繁忙',
    45009: '接口调用超过限制（约 1 分钟后自动解除）',
}


class WecomSender(WebhookSender):
    """企业微信群机器人发送器 —— 必须作为模块级单例使用。"""

    channel = 'wecom'

    def prepare(self, target: Target, payload: dict[str, Any]) -> tuple[str, dict[str, Any]]:
        return target.webhook, payload

    def classify(self, resp: requests.Response) -> AlertHubError | None:
        return classify_errcode_response(resp, platform='wecom', permanent_codes=PERMANENT_CODES)
