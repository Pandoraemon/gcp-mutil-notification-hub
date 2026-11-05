"""渠道注册表：按 Config.NOTIFY_CHANNEL 返回 (builder, sender)。

main.py 在模块导入时调用一次 create()，得到的两个对象作为模块级单例：
sender 持有令牌桶与连接池，若每次调用新建，速率限制形同虚设。
"""

from typing import Any, Protocol

from channels.base import WebhookSender
from channels.dingtalk.card_builder import DingtalkCardBuilder
from channels.dingtalk.webhook_sender import DingtalkSender
from channels.feishu.card_builder import CardBuilder as FeishuCardBuilder
from channels.feishu.webhook_sender import FeishuSender
from channels.rate_limiter import TokenBucket
from channels.wecom.card_builder import WecomCardBuilder
from channels.wecom.webhook_sender import WecomSender
from config import Config, ConfigError
from parsers.base import ParsedAlert


class MessageBuilder(Protocol):
    """渲染器契约：ParsedAlert → 交给 sender.prepare() 的 payload；渲染缺陷抛 PermanentError。"""

    def build(self, alert: ParsedAlert) -> dict[str, Any]:  # pragma: no cover - 协议声明
        ...


_REGISTRY: dict[str, tuple[type, type[WebhookSender]]] = {
    'feishu': (FeishuCardBuilder, FeishuSender),
    'wecom': (WecomCardBuilder, WecomSender),
    'dingtalk': (DingtalkCardBuilder, DingtalkSender),
}


def create(channel: str | None = None,
           bucket: TokenBucket | None = None) -> tuple[MessageBuilder, WebhookSender]:
    """返回所选渠道的 (builder, sender)。channel 缺省取 Config.NOTIFY_CHANNEL。

    Config.load() 已拒绝非法渠道；这里再校验一次，防止绕过 Config 的调用方静默拿到飞书。
    """
    name = channel or Config.NOTIFY_CHANNEL
    try:
        builder_cls, sender_cls = _REGISTRY[name]
    except KeyError as exc:
        raise ConfigError(f'未知投递渠道: {name!r}，可选 {sorted(_REGISTRY)}') from exc
    return builder_cls(), sender_cls(bucket=bucket)
