"""结构化 JSON 日志 —— Cloud Logging 会自动解析为 jsonPayload。

两个必须做到的点：
1. 同一次调用的所有日志行可关联：通过 logging.googleapis.com/trace 与 message_id；
2. 日志中不得出现完整的 webhook URL（飞书 token / 企业微信 key / 钉钉 access_token 等同于凭据），统一脱敏。
"""

import contextvars
import json
import logging
import re
import sys
from collections.abc import Iterator
from contextlib import contextmanager
from typing import Any

# default 用 None 而非 {}：ContextVar 的默认值是所有上下文共享的同一个对象
_ctx: contextvars.ContextVar[dict[str, Any] | None] = contextvars.ContextVar('log_ctx', default=None)

# 飞书/Lark webhook 的 token 段一律打码
_WEBHOOK_TOKEN_RE = re.compile(r'(/open-apis/bot/v2/hook/)[A-Za-z0-9\-]+')
# 企业微信 webhook 的 key=、钉钉 webhook 的 access_token= 与加签 sign= 同样等同于凭据。
# 要求前面是 ? 或 &（URL query 参数），避免误伤 dedup_key=... 这类普通日志文本；
# 值一直打到下一个 & / 空白 / 引号 / 反斜杠为止（JSON 序列化后的字符串里引号前会有 \）
_QUERY_SECRET_RE = re.compile(r'([?&](?:key|access_token|sign)=)[^&\s"\'\\]+')


def _mask(text: str) -> str:
    return _QUERY_SECRET_RE.sub(r'\1****', _WEBHOOK_TOKEN_RE.sub(r'\1****', text))

# LogRecord 的内建字段：其余键都是调用方通过 extra= 传入的业务上下文
_RESERVED = {
    'name', 'msg', 'args', 'levelname', 'levelno', 'pathname', 'filename', 'module',
    'exc_info', 'exc_text', 'stack_info', 'lineno', 'funcName', 'created', 'msecs',
    'relativeCreated', 'thread', 'threadName', 'processName', 'process', 'taskName',
    'message', 'asctime',
}

# Cloud Logging 的 severity 取值与 Python 日志级别的映射
_SEVERITY_MAP = {
    'DEBUG': 'DEBUG', 'INFO': 'INFO', 'WARNING': 'WARNING',
    'ERROR': 'ERROR', 'CRITICAL': 'CRITICAL',
}

# 输出侧的保留键：extra / log_ctx 里的同名字段【绝不能】覆盖它们。
#
# 'severity' 是其中最危险的一个，因为本项目的告警严重性恰好也叫 severity：
#   - 'HIGH' / 'MEDIUM' 不是合法的 Cloud Logging 级别 → 整条日志掉到 DEFAULT，
#     于是 `severity>=WARNING` 之类的过滤器再也筛不出东西；
#   - 'CRITICAL' / 'ERROR' 恰好【是】合法级别 → 一条"投递成功"的 INFO 日志
#     被记成 CRITICAL 级，任何"函数日志出现 ERROR+ 就告警"的监控都会被
#     自己刷屏 —— 而本项目专门写了回环保护就是为了防这种自我触发；
#   - 更隐蔽的是：被提升为日志级别后，severity 会从 jsonPayload 里【消失】，
#     排查时反而看不到告警的真实严重性，且偏偏只在 CRITICAL 这档丢失。
# 实测确认（Cloud Logging 原始 LogEntry）：CRITICAL 告警产生 CRITICAL 日志，
# HIGH 告警产生 DEFAULT 日志。
_OUTPUT_RESERVED = {'severity', 'message', 'logger', 'logging.googleapis.com/trace'}

# 与保留键冲突时的改名规则；未列出的键统一加后缀下划线，保证数据不丢
_COLLISION_RENAME = {'severity': 'alert_severity'}


def _safe_key(key: str) -> str:
    if key not in _OUTPUT_RESERVED:
        return key
    return _COLLISION_RENAME.get(key, f'{key}_')


def mask_webhook(url: str | None) -> str:
    """把 webhook URL 中的凭据打码（飞书 token / 企业微信 key / 钉钉 access_token 与 sign），用于日志输出。"""
    if not url:
        return ''
    return _mask(str(url))


class StructuredFormatter(logging.Formatter):
    """输出单行 JSON，字段名对齐 Cloud Logging 的特殊键。"""

    def format(self, record: logging.LogRecord) -> str:
        entry: dict[str, Any] = {
            'severity': _SEVERITY_MAP.get(record.levelname, record.levelname),
            'message': record.getMessage(),
            'logger': record.name,
        }

        for key, value in (_ctx.get() or {}).items():
            if value:
                if key == 'trace':
                    entry['logging.googleapis.com/trace'] = value
                else:
                    entry[_safe_key(key)] = value

        for key, value in record.__dict__.items():
            if key not in _RESERVED and not key.startswith('_'):
                entry[_safe_key(key)] = value

        if record.exc_info:
            entry['exception'] = self.formatException(record.exc_info)

        return _mask(json.dumps(entry, ensure_ascii=False, default=str))


def setup_structured_logging(level: str = 'INFO') -> None:
    """配置根 logger 输出结构化 JSON 到 stdout（幂等，可重复调用）。"""
    handler = logging.StreamHandler(stream=sys.stdout)
    handler.setFormatter(StructuredFormatter())

    root = logging.getLogger()
    for existing in list(root.handlers):
        root.removeHandler(existing)
    root.addHandler(handler)
    root.setLevel(getattr(logging, str(level).upper(), logging.INFO))


@contextmanager
def log_ctx(**kwargs: Any) -> Iterator[None]:
    """把 message_id / trace 等上下文附加到本次调用产生的所有日志行。"""
    merged = {**(_ctx.get() or {}), **{k: v for k, v in kwargs.items() if v}}
    token = _ctx.set(merged)
    try:
        yield
    finally:
        _ctx.reset(token)
