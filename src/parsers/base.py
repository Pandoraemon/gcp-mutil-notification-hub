"""ParsedAlert 契约 —— 系统唯一的内部接口。

parsers → router → card_builder → webhook_sender 全靠这个结构体串联。
任何新增数据源只需产出符合本契约的对象，无需改动下游。
契约不变量由 BaseParser.parse() 在返回前统一断言，违反即 PermanentError。
"""

import logging
from abc import ABC, abstractmethod
from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from errors import PermanentError

logger = logging.getLogger(__name__)

SUPPORTED_ALERT_TYPES = frozenset({'monitoring', 'service_health', 'billing', 'scc', 'test_event'})
ALERT_TYPES = SUPPORTED_ALERT_TYPES
SEVERITIES = ['INFO', 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL']   # 有序，索引即级别

MAX_TITLE_LENGTH = 100

# 卡片按钮 URL 白名单：incident.url / finding.externalUri 等字段由消息发送方控制，
# 任何有权编辑告警策略或 SCC 资源命名的人都能往里塞任意地址。按钮文案固定为
# "查看详情"，用户点开前看不到真实目标 —— 这是钓鱼出口，必须收口到 Google Cloud 域名。
CONSOLE_URL_PREFIXES = ('https://console.cloud.google.com/', 'https://cloud.google.com/')

# 模板目录：契约要求每个 type 都有同名模板 {type}_card.json.j2
# （飞书模板目录同时充当「已支持告警类型」的登记表：企业微信 / 钉钉渲染器用 Python 构造、
#  对所有类型通用，因此不另设模板；新增类型仍须先补飞书模板）
_TEMPLATE_DIR = Path(__file__).resolve().parent.parent / 'channels' / 'feishu' / 'templates'


@dataclass(frozen=True)
class ParsedAlert:
    """归一化后的告警。字段语义见 docs/internal/alert-contract.md。"""

    type: str                                 # ∈ ALERT_TYPES，且存在同名模板
    severity: str                             # ∈ SEVERITIES，由 severity.py 归一化
    title: str                                # ≤ 100 字符，超长截断
    fields: dict[str, str] = field(default_factory=dict)   # 有序，渲染顺序即 UI 顺序
    dedup_key: str = ''                       # 幂等去重键，非空
    console_url: str | None = None         # 缺省时卡片不渲染按钮（不要用 '#' 占位）
    timestamp: str = ''                       # ISO-8601 UTC，展示时转 UTC+8
    source_project: str = ''                  # 回环保护判定用
    raw_severity: str = ''                    # 归一化前的原始值，仅用于日志排查


def truncate_title(title: str) -> str:
    """标题超长截断并加省略号（契约不变量 3 的配套工具）。"""
    text = ' '.join(str(title).split()) or '(无标题)'
    if len(text) <= MAX_TITLE_LENGTH:
        return text
    return text[:MAX_TITLE_LENGTH - 3] + '...'


def to_iso8601(value: Any) -> str:
    """把各数据源五花八门的时间表示统一成 ISO-8601 UTC 字符串。

    支持：epoch 秒（int/float/数字字符串）、RFC3339 字符串、空值。
    无法识别时返回空串 —— 时间戳是选填字段，不值得让整条告警失败。
    """
    if value in (None, ''):
        return ''
    if isinstance(value, (int, float)) or (isinstance(value, str) and value.isdigit()):
        try:
            return datetime.fromtimestamp(int(value), tz=UTC).strftime('%Y-%m-%dT%H:%M:%SZ')
        except (OverflowError, OSError, ValueError):
            return ''
    text = str(value).strip()
    try:
        parsed = datetime.fromisoformat(text.replace('Z', '+00:00'))
    except ValueError:
        return text          # 保留原样，展示层会原样输出
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC).strftime('%Y-%m-%dT%H:%M:%SZ')


def stringify_fields(raw_fields: Mapping[Any, Any]) -> dict[str, str]:
    """把字段值统一成 str（契约要求），并丢弃空值以免卡片出现空行。

    注意：这里【不做任何转义或清洗】—— 转义是渲染层（| tojson）的责任。
    """
    result: dict[str, str] = {}
    for key, value in raw_fields.items():
        if value is None or value == '':
            continue
        result[str(key)] = value if isinstance(value, str) else str(value)
    return result


def validate_console_url(url: Any) -> str | None:
    """卡片按钮 URL 白名单校验：不在白名单内返回 None 并记 WARNING。

    返回 None 的语义是"不渲染按钮"（契约：缺省时不渲染）。调用方通常写成
    `validate_console_url(untrusted) or default_url`，让安全的默认控制台链接兜底。
    """
    if url is None or url == '':
        return None
    text = str(url).strip()
    if text.startswith(CONSOLE_URL_PREFIXES):
        return text
    logger.warning(
        'console_url rejected by allowlist, button will use default or be omitted',
        extra={'reason': 'console_url_rejected', 'url_prefix': text[:120]},
    )
    return None


def validate_alert(alert: ParsedAlert) -> None:
    """契约不变量断言。违反即 PermanentError（重试无意义）。"""
    if not isinstance(alert, ParsedAlert):
        raise PermanentError(f'parser 未返回 ParsedAlert: {type(alert)!r}')
    if alert.type not in ALERT_TYPES:
        raise PermanentError(f'未知告警类型: {alert.type!r}')
    if not (_TEMPLATE_DIR / f'{alert.type}_card.json.j2').is_file():
        raise PermanentError(f'类型 {alert.type} 缺少模板 {alert.type}_card.json.j2')
    if alert.severity not in SEVERITIES:
        raise PermanentError(f'非法严重性: {alert.severity!r}')
    if not alert.title:
        raise PermanentError('title 不能为空')
    if len(alert.title) > MAX_TITLE_LENGTH:
        raise PermanentError(f'title 超过 {MAX_TITLE_LENGTH} 字符')
    if not isinstance(alert.fields, dict):
        raise PermanentError('fields 必须是 dict')
    for key, value in alert.fields.items():
        if not isinstance(key, str) or not isinstance(value, str):
            raise PermanentError(f'fields 的 key/value 必须是 str: {key!r}={value!r}')
    if not alert.dedup_key:
        raise PermanentError('dedup_key 不能为空')
    # 纵深防御：解析器应已经过 validate_console_url；漏掉的直接按契约违约处理
    if alert.console_url is not None and not str(alert.console_url).startswith(CONSOLE_URL_PREFIXES):
        raise PermanentError(f'console_url 不在白名单内: {str(alert.console_url)[:120]!r}')


class BaseParser(ABC):
    """解析器抽象基类。

    子类只实现 _parse()，契约校验由本类统一负责 —— 避免每个解析器各写一份、
    写漏一个就让畸形数据流到下游。
    """

    alert_type: str = ''

    def __init__(self, attributes: Mapping[str, str] | None = None) -> None:
        # Pub/Sub 消息属性：Billing 的 budgetId 等关键信息只在属性里
        self.attributes: Mapping[str, str] = attributes or {}

    def parse(self, message: dict[str, Any]) -> ParsedAlert:
        try:
            alert = self._parse(message)
        except (KeyError, TypeError, ValueError, AttributeError) as exc:
            # 字段缺失/类型不符都是消息本身的问题，重试无意义 → 归为永久性失败
            # （PermanentError 不是这些类型的子类，会原样向上传递）
            raise PermanentError(f'{type(self).__name__} 解析失败: {exc}') from exc
        validate_alert(alert)
        return alert

    @abstractmethod
    def _parse(self, message: dict[str, Any]) -> ParsedAlert:
        """把原始消息转成 ParsedAlert（不需要自己做契约校验）。"""
