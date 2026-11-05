"""Cloud Functions Gen2 入口（CloudEvents / Pub/Sub 触发）。

关键设计：区分永久性失败（消息本身有问题，重试一万次也没用）与瞬时性失败
（对端抖动，值得重试）。对所有异常一律 raise，会让一条畸形消息占满重试配额；
而在未加 --retry 的情况下抛异常又等于全部静默丢弃。

部署必须带 --retry：Gen2 事件函数默认【不重试】，抛异常等于 ack 丢弃，
死信策略也就永远不会触发。
"""

import base64
import dataclasses
import json
import logging
import re
from collections.abc import Mapping
from typing import Any

import functions_framework

from channels import registry
from channels.base import code_fields
from config import Config
from errors import PermanentError, SkipAlert, TransientError
from log_utils import log_ctx, setup_structured_logging
from parsers import get_parser
from parsers.base import ParsedAlert
from router import Router

# 结构化 JSON 日志必须在 Config.load() 之前就位：Config.load() 会输出一条含
# min_severity / kill_switch / self_project_id 的启动快照（INFO），以及探测项目 ID 失败的
# WARNING。root 还没有 handler 时，Python 的 lastResort 只放行 WARNING+ 且不是 JSON，
# 这条排障最常用的启动日志在云上就从不出现。LOG_LEVEL 本身来自 Config，
# 所以先按 INFO 装好 handler，load 之后再把级别调成配置值。
setup_structured_logging(level='INFO')

# 启动期校验：缺失必填环境变量即崩溃，实例起不来 → 消息堆积在订阅中（而非静默丢弃）
Config.load()

# Cloud Logging 自动解析 jsonPayload，并用 logging.googleapis.com/trace 关联同一次调用的所有日志行
logging.getLogger().setLevel(Config.LOG_LEVEL)
logger = logging.getLogger(__name__)

# 模块级单例：CardBuilder 编译模板、Router 读配置、Sender 持有令牌桶与连接池。
# 放在函数内部会让令牌桶每次调用都被重置，速率限制形同虚设。
# builder / sender 按 Config.NOTIFY_CHANNEL（feishu | wecom | dingtalk）从注册表取。
_card_builder, _sender = registry.create(Config.NOTIFY_CHANNEL)
_router = Router()


@functions_framework.cloud_event
def handle_pubsub(cloud_event: Any) -> None:
    """Cloud Functions Gen2 入口（CloudEvents 格式）。

    返回即 ack；抛异常即 nack 并重试（部署时必须带 --retry），
    达到 max_delivery_attempts=5 后由 Pub/Sub 转入 gcp-alerts-dlq。

    @cloud_event 装饰器不可省略。没有它，functions-framework 会按【旧版事件签名】
    以 function(data, context) 两个参数调用本函数，运行时立刻抛
    "handle_pubsub() takes 1 positional argument but 2 were given" ——
    而单元测试是直接按 CloudEvent 单参数调用的，因此测试全绿、线上每条消息都失败。
    用装饰器而不是部署时的 --signature-type=cloudevent：签名属于源码的性质，
    不该依赖两条部署路径各自记得传同一个 flag。
    """
    # 信封本身也可能畸形（data 不是 dict / 缺 message / message 不是对象）：
    # 同样是重试不可能改变结果的情况，必须 ack 并留 ERROR，而不是让 KeyError 穿透成 nack。
    try:
        msg = cloud_event.data['message']
        if not isinstance(msg, Mapping):
            raise PermanentError(f'message 不是对象: {type(msg).__name__}')
    except (KeyError, TypeError, AttributeError, PermanentError) as exc:
        logger.error(
            'Malformed CloudEvent envelope, dropping (no retry)',
            extra={'reason': 'unparseable', 'error': str(exc)},
            exc_info=True,
        )
        return

    message_id = msg.get('messageId', 'unknown')
    attributes: Mapping[str, str] = msg.get('attributes') or {}

    with log_ctx(message_id=message_id, trace=_trace_from(cloud_event)):
        # 紧急开关：置 KILL_SWITCH=true 后直接 ack 丢弃，秒级生效且可逆，
        # 不需要删除任何基础设施（见 scripts/emergency-disable.sh）
        if Config.KILL_SWITCH:
            logger.warning('KILL_SWITCH enabled, dropping message',
                           extra={'reason': 'kill_switch', 'attributes': dict(attributes)})
            return

        # 暂停模式：全部 nack，让消息堆积在订阅中，IM 侧恢复后自动重投
        if Config.PAUSE_MODE:
            logger.warning('PAUSE_MODE enabled, nacking message for later redelivery',
                           extra={'reason': 'pause_mode'})
            raise TransientError('PAUSE_MODE enabled')

        # 防止 DLQ → 重放 → 再入 DLQ 的无限循环
        replay_count = _replay_count(attributes)
        if replay_count > Config.MAX_REPLAY_COUNT:
            logger.error('Replay limit exceeded, dropping message (no retry)',
                         extra={'reason': 'replay_limit', 'replay_count': replay_count,
                                'max_replay_count': Config.MAX_REPLAY_COUNT})
            return

        payload = ''
        try:
            payload = base64.b64decode(msg['data']).decode('utf-8')
            message_data = json.loads(payload)
            # 合法 JSON 不一定是对象：[1,2] / "hello" / 5 / null 都能通过 json.loads
            if not isinstance(message_data, dict):
                raise PermanentError(f'消息体不是 JSON 对象: {type(message_data).__name__}')
            parser = get_parser(message_data, attributes)
            alert = parser.parse(message_data)   # 契约不变量已在此校验
        except SkipAlert as exc:
            # 消息合法、也不是故障，只是按设计不发卡（如预算周期状态推送）：
            # INFO 即可，不该让值班的人被 ERROR 叫起来
            logger.info('Alert skipped by design, acking without card',
                        extra={'reason': exc.reason, 'detail': str(exc)})
            return
        except (KeyError, ValueError, TypeError, AttributeError,
                UnicodeDecodeError, PermanentError) as exc:
            # 畸形消息：重试无意义，直接 ack 并记 ERROR。
            # 原始 payload 截断后入日志，便于事后补发。
            logger.error(
                'Unparseable message, dropping (no retry)',
                extra={'reason': 'unparseable', 'error': str(exc), 'raw_prefix': payload[:512]},
                exc_info=True,
            )
            return

        # Hub 模式：PSH 等来源给的是项目编号，换成项目 ID 并同步刷新 console_url
        alert = _resolve_hub_project(alert)

        # Hub 模式：日志型策略在多个源项目间复用同一个 open incident
        # （实测 incident_id 不变、resource.labels.project_id 改为新项目）；
        # 不把项目放进去重键，10 分钟内第二个源项目的同类告警会被当成重复丢弃
        hub_mode = bool(Config.HUB_SOURCE_PROJECTS_MAP or Config.HUB_SCOPE)
        if hub_mode and alert.type == 'monitoring' and alert.source_project:
            alert = dataclasses.replace(alert, dedup_key=f'{alert.dedup_key}@{alert.source_project}')

        if alert.source_project:
            alert.fields['项目'] = alert.source_project
        if alert.type == 'service_health' and hub_mode:
            alert.fields['说明'] = '影响范围以 Service Health 控制台为准'

        logger.info(
            'Alert parsed',
            extra={'alert_type': alert.type, 'severity': alert.severity,
                   'raw_severity': alert.raw_severity, 'dedup_key': alert.dedup_key,
                   'source_project': alert.source_project},
        )

        # 回环保护：本函数自身的错误告警若也走这条链路，一次故障会自我放大成风暴
        if _router.is_self_referential(alert):
            logger.warning('Self-referential alert suppressed',
                           extra={'reason': 'self_referential', 'dedup_key': alert.dedup_key})
            return

        # 幂等：Pub/Sub 至少一次语义 + 重试都会造成重复卡片
        if _router.is_duplicate(alert):
            logger.info('Duplicate suppressed',
                        extra={'reason': 'duplicate', 'dedup_key': alert.dedup_key,
                               'source_project': alert.source_project})
            return

        decision = _router.evaluate(alert)
        if not decision.send:
            if decision.reason == 'source_disabled':
                logger.info(
                    'Alert filtered by source rule',
                    extra={'reason': decision.reason, 'source': alert.type, 'dedup_key': alert.dedup_key},
                )
            else:
                # WARNING 而非 INFO：这是"为什么没收到告警"的唯一线索，必须在默认日志级别下可见
                logger.warning(
                    'Alert filtered by severity',
                    extra={'reason': 'severity_filtered', 'severity': alert.severity,
                           'min_severity': Config.MIN_SEVERITY, 'source': alert.type,
                           'threshold': decision.threshold, 'rule': decision.rule},
                )
            return

        target = _router.resolve_target(alert)

        try:
            card = _card_builder.build(alert)
        except PermanentError:
            # 模板漏写 | tojson 之类的渲染缺陷：重试渲染结果不变
            logger.exception('Card rendering failed, dropping (no retry)',
                             extra={'reason': 'render_failed', 'alert_type': alert.type,
                                    'channel': Config.NOTIFY_CHANNEL})
            return

        try:
            _sender.send(target, card)           # 内部校验平台业务码（code / errcode），失败即抛异常
        except TransientError as exc:
            logger.exception('Transient send failure, will retry',
                             extra={'reason': 'transient_send_failure', 'alert_type': alert.type,
                                    **code_fields(Config.NOTIFY_CHANNEL, exc)})
            raise                                # nack → Pub/Sub 重试 → 5 次后进 DLQ
        except PermanentError as exc:
            # 例如签名密钥错误、webhook 已失效：重试只会浪费配额，
            # 但必须留下 ERROR 日志，并由"监控的监控"告警（见 docs/internal/architecture.md）
            logger.exception('Permanent send failure, dropping (no retry)',
                             extra={'reason': 'permanent_send_failure', 'alert_type': alert.type,
                                    **code_fields(Config.NOTIFY_CHANNEL, exc)})
            return

        # 登记去重键【必须】在这里，不能在 is_duplicate 里顺手写：
        # 发送失败时不登记，Pub/Sub 的重投才不会被自己的去重逻辑当成重复消息
        # 吃掉 —— 否则消息到不了第 5 次投递，永远进不了 DLQ（线上实测过）。
        _router.mark_delivered(alert)

        logger.info('Alert delivered', extra={'group': target.group_name,
                                              'alert_type': alert.type,
                                              'severity': alert.severity,
                                              'channel': Config.NOTIFY_CHANNEL})


def _replace_project_in_url(url: str, old_proj: str, new_proj: str) -> str:
    """替换 Google Cloud 控制台 URL 中的 project 参数。"""
    if not url.startswith('https://console.cloud.google.com/'):
        return url
    return re.sub(rf'([?&]project=){re.escape(old_proj)}(?=&|#|$)', rf'\g<1>{new_proj}', url)


def _resolve_hub_project(alert: ParsedAlert) -> ParsedAlert:
    """Hub 模式：PSH 等来源给的是项目编号（resource_container），按 HUB_SOURCE_PROJECTS 换成项目 ID。"""
    if not (alert.source_project and alert.source_project.isdigit()):
        return alert

    target_id: str | None = None
    mapped_id = Config.HUB_SOURCE_PROJECTS_MAP.get(alert.source_project)
    if mapped_id:
        target_id = mapped_id
    elif not (Config.HUB_SOURCE_PROJECTS_MAP or Config.HUB_SCOPE) and Config.SELF_PROJECT_ID:
        target_id = Config.SELF_PROJECT_ID

    if not target_id:
        return alert

    console_url = (
        _replace_project_in_url(alert.console_url, alert.source_project, target_id)
        if alert.console_url
        else alert.console_url
    )
    return dataclasses.replace(alert, source_project=target_id, console_url=console_url)


def _replay_count(attributes: Mapping[str, str]) -> int:
    """读取 replay-dlq.sh 累加的重放计数（非数字视为 0，不因此丢弃消息）。"""
    try:
        return int(attributes.get('replay_count', '0'))
    except (TypeError, ValueError):
        return 0


def _trace_from(cloud_event: Any) -> str | None:
    """从 CloudEvent 的 traceparent 提取 trace，拼成 Cloud Logging 需要的资源名。"""
    try:
        traceparent = cloud_event.get('traceparent')      # type: ignore[union-attr]
    except (AttributeError, TypeError, KeyError):
        traceparent = None
    if not traceparent:
        return None
    parts = str(traceparent).split('-')
    if len(parts) < 2 or not parts[1]:
        return None
    project = Config.SELF_PROJECT_ID or 'unknown'
    return f'projects/{project}/traces/{parts[1]}'
