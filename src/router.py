"""告警路由、严重性过滤、回环保护与去重。

四条与"能不能收到告警"直接相关的规则：
1. webhook 与 secret 成对解析（Target），杜绝"安全群 webhook + 默认群密钥"的 100% 签名失败；
2. 严重性等级直接用契约中 SEVERITIES 的索引，不维护第二份表；
3. 自检事件绕过所有过滤机制（MIN_SEVERITY / 按来源过滤），否则部署自检永远"失败"；
4. 按来源过滤先于全局 MIN_SEVERITY：允许对特定监控静默（OFF）或只接收 CRITICAL，
   而 generic/未指明来源的告警回退到全局阈值。
"""

import logging
import time
from collections import OrderedDict
from dataclasses import dataclass

from config import Config, Target
from parsers.base import SEVERITIES, ParsedAlert

logger = logging.getLogger(__name__)

DEDUP_TTL_SECONDS = 600
DEDUP_CAPACITY = 1024

__all__ = ['Router', 'Target', 'DEDUP_TTL_SECONDS', 'DEDUP_CAPACITY', 'FilterDecision']


@dataclass(frozen=True)
class FilterDecision:
    send: bool
    reason: str
    threshold: str | None
    rule: str


class Router:
    """告警路由、严重性过滤、回环保护与去重。"""

    def __init__(self) -> None:
        # Config.load() 已校验 MIN_SEVERITY 合法，此处无需 fallback
        self._min_level = SEVERITIES.index(Config.MIN_SEVERITY)
        self._seen: OrderedDict[str, float] = OrderedDict()

    def evaluate(self, alert: ParsedAlert) -> FilterDecision:
        # 1. 自检事件绕过所有过滤
        if alert.type == 'test_event':
            return FilterDecision(send=True, reason='test_event', threshold=None, rule='bypass')

        # 2. 按来源过滤（若配置了该来源）
        source_rules = getattr(Config, 'SOURCE_MIN_SEVERITY_DICT', {})
        if alert.type in source_rules:
            threshold_str = source_rules[alert.type]
            if threshold_str == 'OFF':
                return FilterDecision(send=False, reason='source_disabled', threshold='OFF', rule='source')

            threshold_level = SEVERITIES.index(threshold_str)
            if SEVERITIES.index(alert.severity) >= threshold_level:
                return FilterDecision(
                    send=True, reason='severity_above_source_threshold',
                    threshold=threshold_str, rule='source'
                )
            return FilterDecision(
                send=False, reason='severity_below_threshold',
                threshold=threshold_str, rule='source'
            )

        # 3. 全局默认过滤
        if SEVERITIES.index(alert.severity) >= self._min_level:
            return FilterDecision(
                send=True, reason='severity_above_global_threshold',
                threshold=Config.MIN_SEVERITY, rule='global'
            )
        return FilterDecision(
            send=False, reason='severity_below_threshold',
            threshold=Config.MIN_SEVERITY, rule='global'
        )

    def should_send(self, alert: ParsedAlert) -> bool:
        return self.evaluate(alert).send

    def is_self_referential(self, alert: ParsedAlert) -> bool:
        """拦截本函数自身产生的告警，防止 故障→告警→再故障 的正反馈风暴。

        典型触发路径：给 gcp-alerts-to-feishu 配了错误率告警，且发往同一 topic。
        """
        if not Config.SELF_PROJECT_ID or alert.source_project != Config.SELF_PROJECT_ID:
            return False
        haystack = ' '.join([
            alert.title,
            alert.fields.get('资源', ''),
            alert.fields.get('resource', ''),
        ])
        return Config.FUNCTION_NAME in haystack

    def _evict_expired(self) -> None:
        now = time.time()
        while self._seen and next(iter(self._seen.values())) < now - DEDUP_TTL_SECONDS:
            self._seen.popitem(last=False)

    def is_duplicate(self, alert: ParsedAlert) -> bool:
        """进程内 TTL 去重 —— 【只查不写】。

        登记动作必须留到投递成功之后（见 mark_delivered），原因是一个线上实测到的
        丢告警链路：

            投递#1  key 不在缓存 → 写入 → 发送失败 → 抛 TransientError → nack
            投递#2  key 已在缓存 → 判定为重复 → return（=ack）→ 告警永久丢失

        即：只要发送失败一次，Pub/Sub 的第 2 次重投就会被自己的去重逻辑吃掉，
        消息永远到不了第 3/4/5 次投递，也就永远进不了 DLQ。
        死信策略、replay-dlq.sh、README 承诺的"5 次失败后进 DLQ"
        在【最常见的故障场景】下全都成了死代码。

        代价权衡：检查与登记之间存在一个发送耗时量级（~100ms）的窗口，
        期间的真重复可能漏过去。这是刻意的 —— 与 ADR-004 的 fail-open 同一取向：
        宁可偶尔多发一张卡片，不可因为去重而丢掉告警。
        """
        self._evict_expired()
        return alert.dedup_key in self._seen

    def mark_delivered(self, alert: ParsedAlert) -> None:
        """投递成功后才登记，使后续的真重复被抑制。

        仅覆盖同实例内的重复（max_instances=2 时最坏仍可能重复一次，
        属 v1 已知限制；跨实例强一致去重见 docs/internal/architecture.md 的 v2 规划）。
        """
        self._seen[alert.dedup_key] = time.time()
        while len(self._seen) > DEDUP_CAPACITY:
            self._seen.popitem(last=False)

    def resolve_target(self, alert: ParsedAlert) -> Target:
        """按类型路由到对应飞书群；webhook 与 secret 必须成对返回。"""
        if alert.type == 'scc' and Config.SECURITY_TARGET:
            return Config.SECURITY_TARGET
        if alert.type == 'billing' and Config.BILLING_TARGET:
            return Config.BILLING_TARGET
        return Config.DEFAULT_TARGET   # 启动期已保证非空
