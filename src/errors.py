"""失败分类：永久性 vs 瞬时性。

区分二者是本项目可靠性的基础：
- PermanentError：消息本身或配置有问题，重试一万次也没用 → ack 丢弃 + ERROR 日志
- TransientError：对端抖动，值得重试 → nack → Pub/Sub 重试 5 次后进 DLQ
- SkipAlert：消息合法、但按设计【不该发卡】（例如预算周期状态推送）→ ack + INFO 日志

无论哪一类都必须留下可观测信号，禁止静默丢弃。
"""


class AlertHubError(Exception):
    """本项目所有自定义异常的基类。

    http_status / feishu_code 为排障用的独立字段（可为 None）：
    让 Logs Explorer 能按 jsonPayload.feishu_code=19021 过滤，而不是只能全文搜异常字符串。

    platform_code 是渠道无关的业务码（飞书 code / 企业微信 errcode / 钉钉 errcode），
    可按 jsonPayload.platform_code=45009 过滤。feishu_code 为向后兼容保留：
    只传 feishu_code 时 platform_code 自动取同值，存量的飞书日志过滤器不受影响。
    """

    def __init__(self, message: str = '', *,
                 http_status: int | None = None,
                 feishu_code: int | None = None,
                 platform_code: int | None = None) -> None:
        super().__init__(message)
        self.http_status = http_status
        self.feishu_code = feishu_code
        self.platform_code = platform_code if platform_code is not None else feishu_code


class PermanentError(AlertHubError):
    """永久性失败：重试无意义（畸形消息、签名密钥错误、机器人被移出群等）。"""


class TransientError(AlertHubError):
    """瞬时性失败：值得重试（5xx、429、连接超时、DNS 失败等）。"""


class SkipAlert(AlertHubError):
    """按设计跳过：消息格式正确、也不是故障，只是不值得打扰群聊。

    与 PermanentError 的区别在于日志级别：PermanentError 记 ERROR（有人该来看），
    SkipAlert 只记 INFO（预期内行为）。reason 用于日志中的 jsonPayload.reason 字段。
    """

    def __init__(self, reason: str, detail: str = '') -> None:
        super().__init__(detail or reason)
        self.reason = reason
