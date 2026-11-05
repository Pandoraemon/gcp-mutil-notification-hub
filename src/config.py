"""环境变量契约与启动期校验（fail fast，不静默降级）。

设计要点：
1. Target 定义在此（而非 router.py）—— router 需要 Config，config 需要 Target，
   把 Target 放在 config 侧可避免循环导入；router 会再导出一次以保持契约中的引用路径。
2. 校验由 Config.load() 显式执行，main.py 在模块导入时调用：
   缺失必填项 → 实例启动失败 → 消息堆积在订阅中（而非被静默丢弃）。
3. 密钥值只从 --set-secrets 注入的环境变量读取，不做任何"降级到明文"的兜底。
"""

import logging
import os
import re
from dataclasses import dataclass, field

from parsers.base import SEVERITIES

logger = logging.getLogger(__name__)

DEFAULT_FUNCTION_NAME = 'gcp-alerts-to-feishu'
DEFAULT_MIN_SEVERITY = 'MEDIUM'
DEFAULT_MAX_SENDS_PER_MINUTE = 40
# 重放消息带 replay_count 属性；超过此值说明修不好，直接 ack 避免 DLQ → 重放 → DLQ 死循环
MAX_REPLAY_COUNT = 2

# 投递渠道：每次部署三选一，未设置时为 feishu（存量部署零变化）
CHANNELS = ('feishu', 'wecom', 'dingtalk')
DEFAULT_CHANNEL = 'feishu'

# 飞书 / Lark 自定义机器人 webhook 的合法前缀。填错域名或漏掉 https:// 时 requests 会抛
# MissingSchema / 连接失败 —— 都会被归为瞬时错误反复重试直到进 DLQ，而真正原因是配置错误。
# 必须在启动期拦下。
WEBHOOK_PREFIXES = ('https://open.feishu.cn/', 'https://open.larksuite.com/')

# 各渠道 webhook 前缀白名单（同一理由：配置错误必须在启动期暴露，而不是在 DLQ 里）
CHANNEL_WEBHOOK_PREFIXES: dict[str, tuple[str, ...]] = {
    'feishu': WEBHOOK_PREFIXES,
    'wecom': ('https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=',),
    'dingtalk': ('https://oapi.dingtalk.com/robot/send?access_token=',),
}

# 有签名密钥的渠道：SECRET 与 WEBHOOK 必须成对配置，未开签名显式填 NONE。
# 企业微信群机器人没有签名机制（凭据就是 URL 里的 key），不读 SECRET。
_CHANNELS_WITH_SECRET = {'feishu', 'dingtalk'}

# MAX_SENDS_PER_MINUTE 未设置时的按渠道默认值（每实例）。平台限额：飞书 100/min，
# 企业微信 / 钉钉 20/min；须满足 速率 × max_instances ≤ 80 / 16 / 16（留 20% 余量）
CHANNEL_DEFAULT_MAX_SENDS: dict[str, int] = {'feishu': 40, 'wecom': 8, 'dingtalk': 8}
# 单个机器人的平台限额（次/分钟）：单实例速率就超过它，限流错误是必然的
CHANNEL_PLATFORM_LIMITS: dict[str, int] = {'feishu': 100, 'wecom': 20, 'dingtalk': 20}

_TRUE_VALUES = {'1', 'true', 'yes', 'y', 'on'}
_VALID_LOG_LEVELS = {'DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL'}


@dataclass(frozen=True)
class Target:
    """一个 IM 群的投递目标。webhook 与 secret 必须成对，避免张冠李戴。

    webhook（含 token）与 secret 都是凭据：repr=False 保证任何 `%r` / 异常信息 /
    extra={'target': ...} 都不会把它们打进日志（webhook 另有 log_utils 的正则打码兜底）。
    channel 不是凭据，保留在 repr 中便于排障；默认 feishu 以兼容迁移前的构造方式。
    """

    webhook: str = field(repr=False)
    secret: str = field(repr=False)
    group_name: str
    channel: str = DEFAULT_CHANNEL


class ConfigError(RuntimeError):
    """配置非法：启动期即抛出，不进入消息处理流程。"""


def _bool_env(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None or raw == '':
        return default
    return raw.strip().lower() in _TRUE_VALUES


def _parse_hub_source_projects(raw: str, self_project_id: str) -> tuple[dict[str, str], set[str]]:
    if not raw:
        return {}, set()
    parts = raw.split(';')
    number_to_id = {}
    id_set = set()
    project_id_pattern = re.compile(r'^[a-z][a-z0-9-]{4,28}[a-z0-9]$')
    invalid_fragments = []

    for part in parts:
        part = part.strip()
        if not part:
            continue
        if '=' not in part:
            invalid_fragments.append(part)
            continue
        project_id, project_number = part.split('=', 1)
        project_id = project_id.strip()
        project_number = project_number.strip()

        if not project_id_pattern.match(project_id) or not project_number.isdigit():
            invalid_fragments.append(part)
            continue

        if self_project_id and project_id == self_project_id:
            logger.warning(f'HUB_SOURCE_PROJECTS 包含 Hub 自身项目 ({project_id})，已剔除')
            continue

        number_to_id[project_number] = project_id
        id_set.add(project_id)

    if invalid_fragments:
        raise ConfigError(f'HUB_SOURCE_PROJECTS 包含非法片段: {", ".join(invalid_fragments)}')

    return number_to_id, id_set


def _parse_hub_scope(raw: str) -> str:
    raw = raw.strip()
    if not raw:
        return ''
    if not re.match(r'^(folders|organizations)/[0-9]+$', raw):
        raise ConfigError(f'HUB_SCOPE 格式非法: {raw!r}')
    return raw


def _int_env(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None or raw.strip() == '':
        return default
    try:
        value = int(raw)
    except ValueError as exc:
        raise ConfigError(f'{name} 必须是整数，当前值: {raw!r}') from exc
    if value <= 0:
        raise ConfigError(f'{name} 必须为正整数，当前值: {value}')
    return value


def parse_source_min_severity(raw: str) -> dict[str, str]:
    if not raw:
        return {}
    parts = raw.split(';')
    result = {}
    valid_sources = {'monitoring', 'service_health', 'billing', 'scc'}
    invalid_fragments = []

    for part in parts:
        part = part.strip()
        if not part:
            continue
        if '=' not in part:
            invalid_fragments.append(part)
            continue
        k, v = part.split('=', 1)
        k = k.strip().lower()
        v = v.strip().upper()

        if k not in valid_sources or (v not in SEVERITIES and v != 'OFF'):
            invalid_fragments.append(part)
            continue

        result[k] = v

    if invalid_fragments:
        raise ConfigError(
            f'SOURCE_MIN_SEVERITY 包含非法片段: {invalid_fragments}。'
            f'合法 key 为 {valid_sources}，合法值为 OFF 或 {list(SEVERITIES)}，格式为 key=VALUE;...'
        )
    return result

def format_source_min_severity(d: dict[str, str]) -> str:
    if not d:
        return ''
    order = ['monitoring', 'service_health', 'billing', 'scc']
    parts = []
    for k in order:
        if k in d:
            parts.append(f'{k}={d[k]}')
    return ';'.join(parts)

def _load_channel() -> str:
    """读取 NOTIFY_CHANNEL：未设置/空串 → feishu；非法值启动即失败（不静默回落到飞书）。"""
    raw = os.getenv('NOTIFY_CHANNEL')
    channel = (raw or '').strip().lower() or DEFAULT_CHANNEL
    if channel not in CHANNELS:
        raise ConfigError(f'NOTIFY_CHANNEL 非法: {raw!r}，可选 {list(CHANNELS)}')
    return channel


def _load_target(prefix: str, group_name: str, required: bool = False,
                 channel: str = DEFAULT_CHANNEL) -> Target | None:
    """成对读取 webhook / secret。缺一即启动失败，不静默回落。

    只读取所选渠道的变量（{FEISHU|WECOM|DINGTALK}_{prefix}_WEBHOOK / _SECRET），
    其他渠道的变量即使存在也被忽略 —— 一次部署只有一个渠道。
    """
    env = channel.upper()
    webhook_var, secret_var = f'{env}_{prefix}_WEBHOOK', f'{env}_{prefix}_SECRET'
    webhook = os.getenv(webhook_var)
    has_secret = channel in _CHANNELS_WITH_SECRET
    secret = os.getenv(secret_var) if has_secret else ''

    if not webhook and not secret:
        if required:
            if has_secret:
                raise ConfigError(
                    f'{webhook_var} 与 {secret_var} 为必填项，'
                    '请检查 --set-secrets 是否正确挂载'
                )
            raise ConfigError(f'{webhook_var} 为必填项，请检查 --set-secrets 是否正确挂载')
        return None

    if has_secret and bool(webhook) != bool(secret):
        raise ConfigError(f'{webhook_var} 与 {secret_var} 必须成对配置')

    webhook = webhook.strip()
    prefixes = CHANNEL_WEBHOOK_PREFIXES[channel]
    if not webhook.startswith(prefixes):
        # 不回显完整 URL：它含 token。只给前 40 个字符足够定位是哪个变量填错了
        raise ConfigError(
            f'{webhook_var} 必须以 {" 或 ".join(prefixes)} 开头，'
            f'当前值前缀: {webhook[:40]!r}'
        )

    # 空串会导致不签名，而飞书对开启了签名校验的机器人返回 HTTP 200 + code=19021，
    # 表现为"日志显示成功、群里收不到" —— 因此强制显式 NONE（钉钉同理：310000）
    return Target(
        webhook=webhook,
        secret='' if secret.strip() == 'NONE' else secret.strip(),
        group_name=group_name,
        channel=channel,
    )


def _detect_project_id() -> str:
    """回环保护需要知道"自己在哪个项目"；探测失败不致命，仅让回环保护失效。"""
    for name in ('SELF_PROJECT_ID', 'GOOGLE_CLOUD_PROJECT', 'GCP_PROJECT', 'GCLOUD_PROJECT'):
        value = os.getenv(name)
        if value:
            return value.strip()
    try:  # pragma: no cover - 依赖 GCP metadata server，仅在云上可达
        import requests  # 延迟导入：本地测试无需网络栈
        resp = requests.get(
            'http://metadata.google.internal/computeMetadata/v1/project/project-id',
            headers={'Metadata-Flavor': 'Google'},
            timeout=1,
        )
        if resp.status_code == 200:
            return resp.text.strip()
    except Exception:  # pylint: disable=broad-except
        logger.warning('Unable to detect project id, self-referential protection degraded')
    return ''


class Config:
    """进程级配置快照。由 Config.load() 在启动期填充并校验。"""

    LOG_LEVEL: str = 'INFO'
    MIN_SEVERITY: str = DEFAULT_MIN_SEVERITY
    KILL_SWITCH: bool = False
    PAUSE_MODE: bool = False
    MAX_SENDS_PER_MINUTE: int = DEFAULT_MAX_SENDS_PER_MINUTE
    SELF_PROJECT_ID: str = ''
    FUNCTION_NAME: str = DEFAULT_FUNCTION_NAME
    MAX_REPLAY_COUNT: int = MAX_REPLAY_COUNT
    NOTIFY_CHANNEL: str = DEFAULT_CHANNEL
    SOURCE_MIN_SEVERITY_DICT: dict[str, str] = {}
    SOURCE_MIN_SEVERITY: str = ''

    HUB_SOURCE_PROJECTS_MAP: dict[str, str] = {}
    HUB_SOURCE_PROJECTS_SET: set[str] = set()
    HUB_SCOPE: str = ''

    DEFAULT_TARGET: Target | None = None
    SECURITY_TARGET: Target | None = None
    BILLING_TARGET: Target | None = None

    loaded: bool = False

    @classmethod
    def load(cls) -> None:
        """读取并校验全部环境变量。任何非法配置直接抛 ConfigError。"""
        log_level = (os.getenv('LOG_LEVEL') or 'INFO').strip().upper()
        if log_level not in _VALID_LOG_LEVELS:
            raise ConfigError(f'LOG_LEVEL 非法: {log_level!r}，可选 {sorted(_VALID_LOG_LEVELS)}')
        cls.LOG_LEVEL = log_level

        min_severity = (os.getenv('MIN_SEVERITY') or DEFAULT_MIN_SEVERITY).strip().upper()
        if min_severity not in SEVERITIES:
            raise ConfigError(f'MIN_SEVERITY 非法: {min_severity!r}，可选 {SEVERITIES}')
        cls.MIN_SEVERITY = min_severity

        raw_source = os.getenv('SOURCE_MIN_SEVERITY') or ''
        cls.SOURCE_MIN_SEVERITY_DICT = parse_source_min_severity(raw_source)
        cls.SOURCE_MIN_SEVERITY = format_source_min_severity(cls.SOURCE_MIN_SEVERITY_DICT)

        channel = _load_channel()
        cls.NOTIFY_CHANNEL = channel

        cls.KILL_SWITCH = _bool_env('KILL_SWITCH', False)
        cls.PAUSE_MODE = _bool_env('PAUSE_MODE', False)
        cls.MAX_SENDS_PER_MINUTE = _int_env('MAX_SENDS_PER_MINUTE', CHANNEL_DEFAULT_MAX_SENDS[channel])
        cls.MAX_REPLAY_COUNT = _int_env('MAX_REPLAY_COUNT', MAX_REPLAY_COUNT)
        if cls.MAX_SENDS_PER_MINUTE > CHANNEL_PLATFORM_LIMITS[channel]:
            # 不拒绝启动（运维可能有意为之），但单实例就超过平台限额 = 限流错误必然发生，
            # 必须在默认日志级别下留痕，否则排障时只会看到一串 45009 / 130101
            logger.warning(
                'MAX_SENDS_PER_MINUTE exceeds the IM platform per-bot limit',
                extra={'reason': 'rate_exceeds_platform_limit', 'channel': channel,
                       'max_sends_per_minute': cls.MAX_SENDS_PER_MINUTE,
                       'platform_limit_per_minute': CHANNEL_PLATFORM_LIMITS[channel]},
            )

        cls.DEFAULT_TARGET = _load_target('DEFAULT', 'default', required=True, channel=channel)
        cls.SECURITY_TARGET = _load_target('SECURITY', 'security', channel=channel)
        cls.BILLING_TARGET = _load_target('BILLING', 'billing', channel=channel)

        cls.FUNCTION_NAME = (
            os.getenv('K_SERVICE') or os.getenv('FUNCTION_NAME') or DEFAULT_FUNCTION_NAME
        )
        cls.SELF_PROJECT_ID = _detect_project_id()

        cls.HUB_SOURCE_PROJECTS_MAP, cls.HUB_SOURCE_PROJECTS_SET = _parse_hub_source_projects(
            os.getenv('HUB_SOURCE_PROJECTS') or '', cls.SELF_PROJECT_ID
        )
        cls.HUB_SCOPE = _parse_hub_scope(os.getenv('HUB_SCOPE') or '')

        cls.loaded = True
        logger.info(
            'Config loaded',
            extra={
                'channel': cls.NOTIFY_CHANNEL,
                'min_severity': cls.MIN_SEVERITY,
                'source_min_severity': cls.SOURCE_MIN_SEVERITY,
                'max_sends_per_minute': cls.MAX_SENDS_PER_MINUTE,
                'kill_switch': cls.KILL_SWITCH,
                'pause_mode': cls.PAUSE_MODE,
                'security_group_configured': cls.SECURITY_TARGET is not None,
                'billing_group_configured': cls.BILLING_TARGET is not None,
                'self_project_id': cls.SELF_PROJECT_ID,
                'hub_source_projects': sorted(cls.HUB_SOURCE_PROJECTS_SET),
                'hub_scope': cls.HUB_SCOPE,
            },
        )
