"""严重性归一化 —— 各数据源 severity 取值域互不相同、大小写不一、且可能缺失。

核心规则（ADR-004）：查不到一律返回 HIGH（fail-open），不返回 INFO。
监控系统的失效方向必须是"多报"而非"漏报"：把未知严重性当成最低级，
会在默认 MIN_SEVERITY=MEDIUM 下静默丢弃全部告警 —— 这是最隐蔽的失效模式。
"""

import logging

logger = logging.getLogger(__name__)

FAIL_OPEN_SEVERITY = 'HIGH'

# key 为归一化后的原始值（strip().upper().replace(' ', '_')）
_MAPS: dict[str, dict[str, str]] = {
    'monitoring': {
        'CRITICAL': 'CRITICAL',
        'ERROR': 'HIGH',
        'WARNING': 'MEDIUM',
    },
    'service_health': {
        # 由 category + state 组合而成，见 normalize_service_health()
        # PSH 日志源（servicehealth.googleapis.com/activity）的 category 只有 INCIDENT，
        # detailedCategory 区分 CONFIRMED_INCIDENT / EMERGING_INCIDENT；
        # SCHEDULED_MAINTENANCE / SECURITY_BULLETIN 键仅为向后兼容保留（该日志源不会产出）。
        'INCIDENT_ACTIVE': 'HIGH',
        'INCIDENT_EMERGING': 'HIGH',
        'INCIDENT_CONFIRMED': 'HIGH',
        'INCIDENT_CLOSED': 'MEDIUM',
        'INCIDENT_RESOLVED': 'MEDIUM',
        'EMERGING_INCIDENT_ACTIVE': 'HIGH',
        'EMERGING_INCIDENT_EMERGING': 'HIGH',
        'EMERGING_INCIDENT_CLOSED': 'MEDIUM',
        'EMERGING_INCIDENT': 'HIGH',
        'SECURITY_BULLETIN_ACTIVE': 'HIGH',
        'SECURITY_BULLETIN_CLOSED': 'MEDIUM',
        'SECURITY_BULLETIN': 'HIGH',
        # 活跃/待执行的计划维护映射为 MEDIUM，确保在默认 MIN_SEVERITY=MEDIUM 下不会被过滤；已结束归为 LOW
        'SCHEDULED_MAINTENANCE_ACTIVE': 'MEDIUM',
        'SCHEDULED_MAINTENANCE_CLOSED': 'LOW',
        'SCHEDULED_MAINTENANCE': 'MEDIUM',
    },
    'scc': {
        'CRITICAL': 'CRITICAL',
        'HIGH': 'HIGH',
        'MEDIUM': 'MEDIUM',
        'LOW': 'LOW',
    },
}


def _canonical(raw: str | None) -> str:
    if raw is None:
        return ''
    return str(raw).strip().upper().replace(' ', '_')


def normalize(source: str, raw: str | None) -> str:
    """把某数据源的原始 severity 归一化到 SEVERITIES 之一。

    未知值返回 HIGH 并记 WARNING（带 raw_severity），使映射表缺口在日志中可发现。
    """
    table = _MAPS.get(source, {})
    key = _canonical(raw)
    mapped = table.get(key)
    if mapped:
        return mapped
    logger.warning(
        'Unknown severity, failing open to HIGH',
        extra={'source': source, 'raw_severity': '' if raw is None else str(raw)},
    )
    return FAIL_OPEN_SEVERITY


def normalize_service_health(category: str | None, state: str | None) -> str:
    """Service Health 用 category + state 组合判定严重性。"""
    combined = f'{_canonical(category)}_{_canonical(state)}'.strip('_')
    if combined in _MAPS['service_health']:
        return _MAPS['service_health'][combined]
    return normalize('service_health', _canonical(category))


def from_billing_threshold(threshold: float | None) -> str:
    """Billing 没有 severity 字段，用超出的预算阈值百分比推导。

    None 分支仅为其它调用方保留 fail-open 语义：BillingParser 已在更早处把
    "两阈值皆缺"识别为预算周期状态推送并 SkipAlert，不会再以 None 调用本函数。
    """
    if threshold is None:
        logger.warning('Billing alert without threshold, failing open to HIGH',
                       extra={'raw_severity': ''})
        return FAIL_OPEN_SEVERITY
    try:
        value = float(threshold)
    except (TypeError, ValueError):
        logger.warning('Unparseable billing threshold, failing open to HIGH',
                       extra={'raw_severity': str(threshold)})
        return FAIL_OPEN_SEVERITY
    if value >= 1.0:
        return 'CRITICAL'
    if value >= 0.9:
        return 'HIGH'
    return 'MEDIUM'
