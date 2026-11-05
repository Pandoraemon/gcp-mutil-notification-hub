"""Personalized Service Health 解析。

消息是 Cloud Logging 的 LogEntry（logName 含 servicehealth.googleapis.com），
由 Log-based Alert Policy 经 Notification Channel 投递到 topic。
严重性由 category 与 state（ACTIVE / CLOSED）组合判定。PSH 日志源的 category 只有 INCIDENT，
detailedCategory / detailedState 区分 CONFIRMED_INCIDENT / EMERGING_INCIDENT；
SCHEDULED_MAINTENANCE / SECURITY_BULLETIN 分支仅为向后兼容保留。
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
from parsers.severity import normalize_service_health

_CONSOLE = 'https://console.cloud.google.com/servicehealth/incidents'


class ServiceHealthParser(BaseParser):
    alert_type = 'service_health'

    def _parse(self, message: dict[str, Any]) -> ParsedAlert:
        incident = message.get('incident') or {}
        if incident:
            return self._parse_incident(incident)

        payload = message.get('jsonPayload') or {}
        resource_labels = (message.get('resource') or {}).get('labels') or {}

        event_id = str(
            payload.get('eventId')
            or payload.get('event_id')
            or resource_labels.get('event_id')   # 真实日志：事件 ID 只在监控资源标签上
            or payload.get('name')
            or message.get('insertId')
            or 'unknown'
        )
        category = str(payload.get('category') or '')
        detailed_category = str(payload.get('detailedCategory') or '').upper()
        detailed_state = str(payload.get('detailedState') or '')
        if detailed_category == 'EMERGING_INCIDENT' or (
            category == 'INCIDENT' and detailed_state.upper() == 'EMERGING'
        ):
            effective_category = 'EMERGING_INCIDENT'
        else:
            effective_category = category
        state = str(payload.get('state') or detailed_state or '')
        update_time = str(payload.get('updateTime') or message.get('timestamp') or '')

        project_id = str(
            resource_labels.get('project_id')
            or str(resource_labels.get('resource_container') or '').removeprefix('projects/')
            or payload.get('parentPath')
            or ''
        )

        fields = stringify_fields({
            '类别': effective_category or category,
            '状态': f'{state} ({detailed_state})' if detailed_state and detailed_state != state else state,
            '受影响产品': _join(payload.get('impactedProducts'), 'product'),
            '受影响区域': (
                _join(payload.get('impactedLocations'), 'location')
                or resource_labels.get('location')
            ),
            '项目': project_id,
            '描述': payload.get('description') or payload.get('detailedDescription'),
            '相关性': payload.get('relevance'),
            '开始时间': payload.get('startTime'),
            '更新时间': update_time,
        })

        title = payload.get('title') or payload.get('description') or 'Google Cloud 服务健康事件'

        return ParsedAlert(
            type=self.alert_type,
            severity=normalize_service_health(effective_category, state),
            title=truncate_title(title),
            fields=fields,
            dedup_key=f'service_health:{event_id}:{update_time}',
            console_url=f'{_CONSOLE}?project={project_id}' if project_id else _CONSOLE,
            timestamp=to_iso8601(update_time or message.get('timestamp')),
            source_project=project_id,
            raw_severity=f'{effective_category}/{state}',
        )

    def _parse_incident(self, incident: dict[str, Any]) -> ParsedAlert:
        """解析经 Cloud Monitoring conditionMatchedLog 告警策略投递的 PSH 事件。

        实测 Cloud Monitoring v1.2 对 conditionMatchedLog 策略投递的 incident 中，
        metric.labels 为空对象 `{}`，labelExtractors 提取出的键值写入在
        incident.summary（形如 `Log match condition with labels {k=v,...} fired for ...`），
        而 event_id / location / resource_container 同时出现在 incident.resource.labels。
        """
        resource_labels = (incident.get('resource') or {}).get('labels') or {}
        metric_labels = (incident.get('metric') or {}).get('labels') or {}
        summary_labels = _extract_summary_labels(incident.get('summary'))
        labels = {**summary_labels, **metric_labels}

        incident_id = str(incident.get('incident_id') or incident.get('incidentId') or 'unknown')
        event_id = str(
            labels.get('event_id')
            or resource_labels.get('event_id')
            or incident_id
        )
        category = str(labels.get('category') or _infer_category(incident.get('policy_name')))
        detailed_category = str(labels.get('detailed_category') or '').upper()
        detailed_state = str(labels.get('detailed_state') or '')
        if (
            detailed_category == 'EMERGING_INCIDENT'
            or _infer_category(incident.get('policy_name')) == 'EMERGING_INCIDENT'
            or (category == 'INCIDENT' and detailed_state.upper() == 'EMERGING')
        ):
            effective_category = 'EMERGING_INCIDENT'
        else:
            effective_category = category
        inc_state = str(incident.get('state') or 'OPEN').upper()
        state = str(labels.get('state') or ('CLOSED' if inc_state == 'CLOSED' else 'ACTIVE'))
        # 事件所属项目以 resource_container 为准：Hub 模式下日志型策略建在 Hub 项目里，
        # scoping_project_id 恒为 Hub，而 resource_container 才是源项目（真实日志里是项目编号，
        # 由 main.py 按 HUB_SOURCE_PROJECTS 换成项目 ID）
        project_id = str(
            resource_labels.get('project_id')
            or str(resource_labels.get('resource_container') or '').removeprefix('projects/')
            or incident.get('scoping_project_id')
            or ''
        )
        title = (
            labels.get('title')
            or incident.get('policy_name')
            or 'Google Cloud 服务健康事件'
        )
        fields = stringify_fields({
            '类别': effective_category or category,
            '状态': f'{state} ({detailed_state})' if detailed_state and detailed_state != state else state,
            '受影响产品': labels.get('impacted_products') or '',
            '受影响区域': labels.get('impacted_locations') or resource_labels.get('location') or '',
            '项目': project_id,
            '相关性': labels.get('relevance') or '',
            '摘要': incident.get('summary') or '',
        })
        default_url = f'{_CONSOLE}?project={project_id}' if project_id else _CONSOLE
        return ParsedAlert(
            type=self.alert_type,
            severity=normalize_service_health(effective_category, state),
            title=truncate_title(str(title)),
            fields=fields,
            dedup_key=f'service_health:{event_id}:{inc_state}',
            console_url=validate_console_url(incident.get('url')) or default_url,
            timestamp=to_iso8601(incident.get('started_at') or incident.get('ended_at')),
            source_project=project_id,
            raw_severity=f'{effective_category}/{state}',
        )


_SUMMARY_LABELS_PREFIX = 'Log match condition with labels {'
_SUMMARY_LABELS_SUFFIX = '} fired for '
_KNOWN_EXTRACTOR_KEYS = frozenset({
    'category',
    'detailed_category',
    'detailed_state',
    'event_id',
    'impacted_locations',
    'impacted_products',
    'relevance',
    'state',
    'title',
})
_KEY_PATTERN = re.compile(
    r'(?:^|,\s*)(' + '|'.join(sorted(_KNOWN_EXTRACTOR_KEYS)) + r')='
)


def _extract_summary_labels(summary: Any) -> dict[str, str]:
    """从 Cloud Monitoring conditionMatchedLog 的 summary 中提取 labelExtractors 键值。"""
    if not isinstance(summary, str):
        return {}
    start = summary.find(_SUMMARY_LABELS_PREFIX)
    if start < 0:
        return {}
    body_start = start + len(_SUMMARY_LABELS_PREFIX)
    end = summary.find(_SUMMARY_LABELS_SUFFIX, body_start)
    if end < 0:
        return {}
    raw = summary[body_start:end]
    if not raw:
        return {}

    matches = list(_KEY_PATTERN.finditer(raw))
    if not matches:
        return {}
    out: dict[str, str] = {}
    for idx, match in enumerate(matches):
        key = match.group(1)
        val_start = match.end()
        val_end = matches[idx + 1].start() if idx + 1 < len(matches) else len(raw)
        val = raw[val_start:val_end].strip()
        if val:
            out[key] = val
    return out


def _infer_category(policy_name: Any) -> str:
    name = str(policy_name or '').upper()
    if 'EMERGING' in name:
        return 'EMERGING_INCIDENT'
    if 'MAINTENANCE' in name:
        return 'SCHEDULED_MAINTENANCE'
    if 'SECURITY' in name or 'BULLETIN' in name:
        return 'SECURITY_BULLETIN'
    return 'INCIDENT'


def _join(items: Any, key: str) -> str:
    """impactedProducts 形如 [{"product": "Compute Engine"}]，也可能直接是字符串列表。

    真实 PSH 日志（servicehealth.googleapis.com/activity，2026-10 Argolis 实测）里
    impactedProducts / impactedLocations 是【Python 列表的字符串化】，如
    "['AlloyDB for PostgreSQL', 'Apigee']"、"['', 'europe-west2']"。原样展示会把方括号与
    引号带进卡片，这里拆成「、」分隔并丢弃空项。
    """
    if not items:
        return ''
    if isinstance(items, str):
        text = items.strip()
        if text.startswith('[') and text.endswith(']'):
            parts = [p.strip().strip('\'"').strip() for p in text[1:-1].split(',')]
            return '、'.join(p for p in parts if p)
        return items
    out: list[str] = []
    for item in items:
        if isinstance(item, dict):
            value = item.get(key) or next(iter(item.values()), '')
        else:
            value = item
        if value:
            out.append(str(value))
    return '、'.join(out)
