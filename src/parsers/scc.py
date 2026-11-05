"""Security Command Center Finding 解析（Continuous Export → Pub/Sub）。

消息形如 {"notificationConfigName": ..., "finding": {...}, "resource": {...}}。
finding.severity 与统一枚举同名直通；缺失或未知走 fail-open（HIGH）。
"""

from typing import Any

from parsers.base import (
    BaseParser,
    ParsedAlert,
    stringify_fields,
    to_iso8601,
    truncate_title,
    validate_console_url,
)
from parsers.severity import normalize

_CONSOLE = 'https://console.cloud.google.com/security/command-center/findings'


class SccParser(BaseParser):
    alert_type = 'scc'

    def _parse(self, message: dict[str, Any]) -> ParsedAlert:
        finding = message.get('finding') or {}
        resource = message.get('resource') or {}

        name = str(finding.get('name') or 'unknown')
        event_time = str(finding.get('eventTime') or finding.get('createTime') or '')
        raw_severity = finding.get('severity')

        category = str(finding.get('category') or 'SCC Finding')
        resource_name = str(finding.get('resourceName') or resource.get('name') or '')
        project = str(
            resource.get('projectDisplayName')
            or resource.get('project')
            or ''
        ).rsplit('/', maxsplit=1)[-1]

        source_properties = finding.get('sourceProperties') or {}
        description = (
            finding.get('description')
            or source_properties.get('Explanation')
            or source_properties.get('description')
        )

        fields = stringify_fields({
            '类别': category,
            '状态': finding.get('state'),
            '严重性(原始)': raw_severity,
            '资源': resource_name,
            '项目': project or resource.get('projectDisplayName'),
            '发现时间': event_time,
            '说明': description,
            '建议': source_properties.get('Recommendation'),
            '合规标准': _compliance(finding.get('compliances')),
        })

        # externalUri 由 finding 来源控制（第三方 source 可写任意值），必须过白名单
        default_url = f'{_CONSOLE}?project={project}' if project else _CONSOLE
        console_url = validate_console_url(finding.get('externalUri')) or default_url

        return ParsedAlert(
            type=self.alert_type,
            severity=normalize('scc', raw_severity),
            title=truncate_title(category.replace('_', ' ')),
            fields=fields,
            dedup_key=f'scc:{name}:{event_time}',
            console_url=str(console_url),
            timestamp=to_iso8601(event_time),
            source_project=project,
            raw_severity='' if raw_severity is None else str(raw_severity),
        )


def _compliance(compliances: Any) -> str:
    if not compliances:
        return ''
    out = []
    for item in compliances:
        if isinstance(item, dict):
            standard = item.get('standard', '')
            ids = ','.join(str(i) for i in (item.get('ids') or []))
            out.append(f'{standard}({ids})' if ids else str(standard))
    return '、'.join(x for x in out if x)
