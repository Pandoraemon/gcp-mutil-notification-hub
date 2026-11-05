"""Cloud Billing Budget 通知解析。

Billing 通知没有 severity 字段，严重性由超出的阈值百分比推导；
budgetId / billingAccountId 只存在于 Pub/Sub 消息【属性】中，不在消息体里 ——
因此 BaseParser 会把 attributes 一并注入。

⚠️ 预算的 Pub/Sub 通知不只在"突破阈值"时发：GCP 每天多次向 topic 推送当前预算状态，
`alertThresholdExceeded` / `forecastThresholdExceeded` 只在相应阈值被突破时才出现。
两者都缺失 = 周期性状态推送，不是告警，必须跳过（SkipAlert → ack + INFO），
否则每个预算每 ~30 分钟就会收到一张"已超过 None%"的假 HIGH 卡。
"""

from typing import Any

from errors import SkipAlert
from parsers.base import (
    BaseParser,
    ParsedAlert,
    stringify_fields,
    to_iso8601,
    truncate_title,
    validate_console_url,
)
from parsers.severity import from_billing_threshold

_CONSOLE = 'https://console.cloud.google.com/billing'

SKIP_REASON_NO_THRESHOLD = 'budget_status_no_threshold'


class BillingParser(BaseParser):
    alert_type = 'billing'

    def _parse(self, message: dict[str, Any]) -> ParsedAlert:
        budget_id = str(self.attributes.get('budgetId') or message.get('budgetId') or 'unknown')
        billing_account = str(self.attributes.get('billingAccountId') or '')

        threshold = message.get('alertThresholdExceeded')
        forecast_threshold = message.get('forecastThresholdExceeded')
        effective_threshold = threshold if threshold is not None else forecast_threshold

        if effective_threshold is None:
            # 周期性状态推送：不是故障也不是畸形消息，不发卡、不记 ERROR
            raise SkipAlert(
                SKIP_REASON_NO_THRESHOLD,
                f'budget {budget_id} status push without alert/forecast threshold',
            )

        currency = str(message.get('currencyCode') or '')
        cost = message.get('costAmount')
        budget_amount = message.get('budgetAmount')
        interval_start = str(message.get('costIntervalStart') or '')

        fields = stringify_fields({
            '预算名称': message.get('budgetDisplayName'),
            '触发阈值': _percent(threshold) if threshold is not None else '',
            '预测阈值': _percent(forecast_threshold) if forecast_threshold is not None else '',
            '当前花费': _money(cost, currency),
            '预算金额': _money(budget_amount, currency),
            '使用率': _ratio(cost, budget_amount),
            '结算账号': billing_account,
            '统计区间': interval_start,
        })

        title = message.get('budgetDisplayName') or '预算告警'
        console_url = validate_console_url(
            f'{_CONSOLE}/{billing_account}/budgets' if billing_account else f'{_CONSOLE}'
        )

        return ParsedAlert(
            type=self.alert_type,
            severity=from_billing_threshold(effective_threshold),
            title=truncate_title(f'{title} 已超过 {_percent(effective_threshold)}'),
            fields=fields,
            # 带上 costIntervalStart：同一阈值在下个预算周期再次突破是新事件，不能被跨月去重
            dedup_key=f'billing:{budget_id}:{effective_threshold}:{interval_start}',
            console_url=console_url,
            timestamp=to_iso8601(message.get('costIntervalStart')),
            source_project='',
            raw_severity=str(effective_threshold),
        )


def _percent(value: Any) -> str:
    try:
        return f'{float(value) * 100:g}%'
    except (TypeError, ValueError):
        return str(value or '')


def _money(value: Any, currency: str) -> str:
    if value in (None, ''):
        return ''
    try:
        return f'{float(value):,.2f} {currency}'.strip()
    except (TypeError, ValueError):
        return f'{value} {currency}'.strip()


def _ratio(cost: Any, budget: Any) -> str:
    try:
        budget_value = float(budget)
        if budget_value <= 0:
            return ''
        return f'{float(cost) / budget_value * 100:.1f}%'
    except (TypeError, ValueError, ZeroDivisionError):
        return ''
