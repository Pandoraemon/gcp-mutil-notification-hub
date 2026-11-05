"""解析器分发：根据消息形状与 Pub/Sub 属性挑选解析器。

识别不了的消息一律 PermanentError —— 重试同一条畸形消息毫无意义，
但必须留下 ERROR 日志（由 main.py 负责记录原始 payload 前缀）。
"""

from collections.abc import Mapping
from typing import Any

from errors import PermanentError
from parsers.base import ALERT_TYPES, SEVERITIES, BaseParser, ParsedAlert, validate_alert
from parsers.billing import BillingParser
from parsers.monitoring import MonitoringParser
from parsers.scc import SccParser
from parsers.service_health import ServiceHealthParser
from parsers.test_event import TestEventParser

__all__ = [
    'ALERT_TYPES', 'SEVERITIES', 'BaseParser', 'ParsedAlert', 'validate_alert',
    'BillingParser', 'MonitoringParser', 'SccParser', 'ServiceHealthParser',
    'TestEventParser', 'get_parser',
]

_SERVICE_HEALTH_LOG = 'servicehealth.googleapis.com'


def get_parser(message: dict[str, Any],
               attributes: Mapping[str, str] | None = None) -> BaseParser:
    """按消息内容选择解析器。

    输入可能是任意合法 JSON（list / str / number / null），不只是对象 ——
    非 dict 一律 PermanentError，不能让 .get() 的 AttributeError 穿透成 nack。
    """
    attrs: Mapping[str, str] = attributes or {}

    if not isinstance(message, dict):
        raise PermanentError(f'消息体不是 JSON 对象: {type(message).__name__}')

    if message.get('type') == 'test_event' or attrs.get('source') == 'self-test':
        return TestEventParser(attrs)

    if 'incident' in message:
        incident = message.get('incident')
        if not isinstance(incident, dict):
            raise PermanentError(f'incident 必须是 JSON 对象: {type(incident).__name__}')
        resource = incident.get('resource')
        res_type = str(resource.get('type') or '') if isinstance(resource, dict) else ''
        policy_name = str(incident.get('policy_name') or '')
        if res_type == 'servicehealth.googleapis.com/Event' or policy_name.startswith('GCP Service Health'):
            return ServiceHealthParser(attrs)
        return MonitoringParser(attrs)

    if 'finding' in message or 'notificationConfigName' in message:
        return SccParser(attrs)

    if 'budgetId' in attrs or 'budgetAmount' in message or 'alertThresholdExceeded' in message:
        return BillingParser(attrs)

    if 'jsonPayload' in message:
        log_name = str(message.get('logName') or '')
        payload = message.get('jsonPayload')
        if not isinstance(payload, dict):
            payload = {}
        if _SERVICE_HEALTH_LOG in log_name or 'category' in payload:
            return ServiceHealthParser(attrs)

    raise PermanentError(
        f'无法识别的消息类型（顶层键: {sorted(message)[:8]}，属性: {sorted(attrs)[:8]}）'
    )
