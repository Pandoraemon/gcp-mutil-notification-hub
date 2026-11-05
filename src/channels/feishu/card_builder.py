"""飞书 Interactive Card 渲染（Jinja2）。

⚠️ 本模块的头号风险是 JSON 转义。告警文本里出现 "、\\、换行是常态
（SCC finding 描述、日志 message、告警策略文档几乎必然包含），
把原始值直接插进 JSON 字符串会渲染出非法 JSON → json.loads 抛错 → 重试 → 全部进 DLQ。
所有插值【必须】经过 | tojson（该过滤器自带外层引号，模板里不要再包 "）。
"""

import json
import logging
import os
from datetime import UTC, datetime, timedelta, timezone
from typing import Any

from jinja2 import Environment, FileSystemLoader, StrictUndefined, TemplateError, TemplateNotFound

from errors import PermanentError
from parsers.base import ParsedAlert

logger = logging.getLogger(__name__)

_TEMPLATE_DIR = os.path.join(os.path.dirname(__file__), 'templates')
FALLBACK_TEMPLATE = 'generic_card.json.j2'   # 必须存在，见 tests/test_card_builder.py

_UTC8 = timezone(timedelta(hours=8))

SEVERITY_ICONS = {
    'CRITICAL': '🔴', 'HIGH': '🟠', 'MEDIUM': '🟡', 'LOW': '🔵', 'INFO': '⚪',
}
# 飞书卡片 header.template 的合法取值（非任意颜色名）
SEVERITY_COLORS = {
    'CRITICAL': 'red', 'HIGH': 'orange', 'MEDIUM': 'yellow', 'LOW': 'blue', 'INFO': 'grey',
}


class CardBuilder:
    """飞书 Interactive Card 构造器（基于 Jinja2 模板）"""

    def __init__(self) -> None:
        self.jinja_env = Environment(
            loader=FileSystemLoader(_TEMPLATE_DIR),
            # 模板里引用未定义变量时立刻报错，而不是静默渲染成空串
            # （空串会产出 "content": "" 这类看起来正常、实则丢字段的卡片）
            undefined=StrictUndefined,
            autoescape=False,          # 目标是 JSON 不是 HTML，转义交给 | tojson
            keep_trailing_newline=False,
        )
        # 启动期即校验降级模板存在，避免"降级路径本身抛 TemplateNotFound"
        self.jinja_env.get_template(FALLBACK_TEMPLATE)

    def build(self, alert: ParsedAlert) -> dict[str, Any]:
        """按告警类型选择模板并渲染为飞书卡片 dict。"""
        template_name = f'{alert.type}_card.json.j2'
        try:
            template = self.jinja_env.get_template(template_name)
        except TemplateNotFound:
            logger.warning('Template missing, using fallback',
                           extra={'template': template_name, 'alert_type': alert.type})
            template = self.jinja_env.get_template(FALLBACK_TEMPLATE)

        context = {
            'severity': alert.severity,
            'severity_icon': self._severity_icon(alert.severity),
            'severity_color': self._severity_color(alert.severity),
            'title': alert.title,
            'fields': alert.fields,              # 保序，渲染顺序即 UI 顺序
            'console_url': alert.console_url,    # 可能为 None，模板据此决定是否渲染按钮
            'timestamp': self._to_local(alert.timestamp),
        }

        try:
            rendered = template.render(**context)
        except (TemplateError, TypeError, ValueError) as exc:
            # StrictUndefined 抛 UndefinedError（TemplateError 子类）；
            # Undefined 对象经 | tojson 序列化则抛 TypeError。两者都是模板缺陷：
            # 同一条消息重试多少次都会在同一处失败 → 永久性失败。
            logger.error('Card template rendering failed',
                         extra={'alert_type': alert.type, 'template': template_name,
                                'error': f'{type(exc).__name__}: {exc}'})
            raise PermanentError(f'template render failed for type={alert.type}: {exc}') from exc

        try:
            return json.loads(rendered)
        except json.JSONDecodeError as exc:
            # 走到这里说明某个模板漏了 | tojson。归类为永久性失败：
            # 同一条消息重试多少次都会渲染出同样的非法 JSON。
            logger.error('Rendered card is not valid JSON (missing |tojson?)',
                         extra={'alert_type': alert.type, 'position': exc.pos,
                                'excerpt': rendered[max(0, exc.pos - 80):exc.pos + 80]})
            raise PermanentError(f'invalid card JSON for type={alert.type}') from exc

    @staticmethod
    def _severity_icon(severity: str) -> str:
        return SEVERITY_ICONS[severity]   # 契约保证 severity ∈ SEVERITIES，违约立刻暴露

    @staticmethod
    def _severity_color(severity: str) -> str:
        return SEVERITY_COLORS[severity]

    @staticmethod
    def _to_local(timestamp: str) -> str:
        """ISO-8601 UTC → UTC+8 展示串；无法解析时原样返回（时间戳是选填字段）。"""
        if not timestamp:
            return '—'
        try:
            parsed = datetime.fromisoformat(str(timestamp).replace('Z', '+00:00'))
        except ValueError:
            return str(timestamp)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=UTC)
        return parsed.astimezone(_UTC8).strftime('%Y-%m-%d %H:%M:%S (UTC+8)')
