"""Cloud Monitoring Incident 解析。

消息形如 {"incident": {...}}，由 Pub/Sub 类型的 Notification Channel 投递。
注意：incident.severity 仅在告警策略显式配置时才存在，缺失是常态 —— 走 fail-open。
"""

import re
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

_CONSOLE = 'https://console.cloud.google.com/monitoring/alerting/incidents'

_SUMMARY_LABELS_PREFIX = 'Log match condition with labels {'
_SUMMARY_LABELS_SUFFIX = '} fired for '
_EXTRACTOR_KEYS = frozenset({'principal_email', 'maintenance_status'})
_ANY_KEY_PATTERN = re.compile(r'(?:^|,\s*)([a-zA-Z0-9_]+)=')


def _extract_summary_labels(summary: Any) -> dict[str, str]:
    """从 Cloud Monitoring conditionMatchedLog 的 summary 中提取 labelExtractors 键值。"""
    if not isinstance(summary, str):
        return {}

    if _SUMMARY_LABELS_PREFIX not in summary:
        return {}
    start = summary.find(_SUMMARY_LABELS_PREFIX) + len(_SUMMARY_LABELS_PREFIX)
    end = summary.find(_SUMMARY_LABELS_SUFFIX, start)
    if end <= start:
        return {}
    raw = summary[start:end]

    matches = list(_ANY_KEY_PATTERN.finditer(raw))
    if not matches:
        return {}
    out: dict[str, str] = {}
    for idx, match in enumerate(matches):
        key = match.group(1)
        if key in _EXTRACTOR_KEYS:
            val_start = match.end()
            val_end = matches[idx + 1].start() if idx + 1 < len(matches) else len(raw)
            val = raw[val_start:val_end].strip()
            if val:
                out[key] = val
    return out


class MonitoringParser(BaseParser):
    alert_type = 'monitoring'

    def _parse(self, message: dict[str, Any]) -> ParsedAlert:
        incident = message.get('incident') or {}

        incident_id = str(incident.get('incident_id') or incident.get('incidentId') or 'unknown')
        state = str(incident.get('state') or incident.get('condition_state') or 'UNKNOWN').upper()
        raw_severity = incident.get('severity')
        severity = normalize('monitoring', raw_severity)

        resource = incident.get('resource') or {}
        labels = resource.get('labels') or {}
        project_id = str(
            labels.get('project_id')
            or str(labels.get('resource_container') or '').removeprefix('projects/')
            or incident.get('scoping_project_id')
            or incident.get('project_id')
            or ''
        )

        metric = incident.get('metric') or {}
        metric_labels = metric.get('labels') or {} if isinstance(metric, dict) else {}
        summary_labels = _extract_summary_labels(incident.get('summary'))
        extracted_labels = {**summary_labels, **metric_labels}
        condition = incident.get('condition') or {}

        policy_name = incident.get('policy_name') or condition.get('displayName') or 'Cloud Monitoring 告警'

        fields = stringify_fields({
            '状态': _state_text(state),
            '策略': policy_name,
            '条件': condition.get('displayName') or condition.get('name'),
            '资源': _resource_text(resource, labels),
            '项目': project_id,
            '指标': metric.get('displayName') or metric.get('type'),
            '阈值': incident.get('threshold_value'),
            '观测值': incident.get('observed_value'),
            '操作人': extracted_labels.get('principal_email'),
            '维护状态': extracted_labels.get('maintenance_status'),
            '摘要': incident.get('summary'),
            '说明': (incident.get('documentation') or {}).get('content')
            if isinstance(incident.get('documentation'), dict) else incident.get('documentation'),
        })

        # incident.url 由告警策略侧控制，必须过白名单；被拒时回落到安全的默认控制台链接
        default_url = (
            f'{_CONSOLE}/{incident_id}?project={project_id}' if project_id else f'{_CONSOLE}/{incident_id}'
        )
        console_url = validate_console_url(incident.get('url')) or default_url

        return ParsedAlert(
            type=self.alert_type,
            severity=severity,
            title=truncate_title(policy_name),
            fields=fields,
            # OPEN 与 CLOSED 各发一次，符合预期
            dedup_key=f'monitoring:{incident_id}:{state}',
            console_url=str(console_url),
            timestamp=to_iso8601(incident.get('started_at') or incident.get('ended_at')),
            source_project=project_id,
            raw_severity='' if raw_severity is None else str(raw_severity),
        )


def _state_text(state: str) -> str:
    return {'OPEN': '🔥 触发中 (OPEN)', 'CLOSED': '✅ 已恢复 (CLOSED)'}.get(state, state)


def _resource_text(resource: dict[str, Any], labels: dict[str, Any]) -> str:
    name = (
        labels.get('instance_id')
        or labels.get('service_name')
        or labels.get('database_id')
        or labels.get('cluster_name')
        or resource.get('name')
        or ''
    )
    zone = labels.get('zone') or labels.get('location') or labels.get('region') or ''
    parts = [str(p) for p in (resource.get('type'), name, zone) if p]
    return ' / '.join(parts)
