"""渠道无关的文本安全工具：Unicode 安全截断、URL 去活、按钮 URL 收口、时间展示。

企业微信 / 钉钉渲染器是用 Python 直接构造 dict（不走 Jinja），JSON 转义由 requests
的 json= 负责；本模块只处理【内容层】的风险：

1. 长度：平台对字段有长度上限，超长截断必须按码点切、且不能把 emoji ZWJ 序列 /
   组合附加符 / 国旗区域指示符对切成半个（渲染成乱码或豆腐块）。
2. 外链：告警文本由消息发送方控制（任何有权编辑告警策略、SCC 资源命名的人都能写入），
   裸 URL 在多数 IM 客户端里会被自动识别成可点击链接 —— 钓鱼出口。defang_urls() 把
   协议头改成 `http[:]//` / `https[:]//`，人仍然看得懂，客户端不再识别。
3. 按钮：卡片按钮 URL 只允许已过 parsers.base.validate_console_url 白名单的地址，
   否则回落到 Cloud Console 首页（企业微信 text_notice 的 card_action 是必填项）。
"""

import re
import unicodedata
from datetime import UTC, datetime, timedelta, timezone

from parsers.base import validate_console_url

DEFAULT_CONSOLE_URL = 'https://console.cloud.google.com/'

# 企业微信全局错误码 40039「不合法的url长度：url长度限制1024个字节」；钉钉未公开上限（待确认），
# 两边统一按 1024 字节收口：超长的控制台深链回落到首页，而不是截断成一个打不开的地址
MAX_BUTTON_URL_BYTES = 1024

ELLIPSIS = '…'

SEVERITY_ICONS = {
    'CRITICAL': '🔴', 'HIGH': '🟠', 'MEDIUM': '🟡', 'LOW': '🔵', 'INFO': '⚪',
}

# 与飞书模板标题里的类型标签保持一致（见 channels/feishu/templates/*_card.json.j2）
TYPE_LABELS = {
    'monitoring': 'Monitoring', 'service_health': 'Service Health', 'billing': 'Billing',
    'scc': 'Security', 'test_event': 'GCP 监控告警中心',
}
GENERIC_TYPE_LABEL = 'GCP 告警'
TEST_EVENT_ICON = '🟢'

_UTC8 = timezone(timedelta(hours=8))

_URL_SCHEME_RE = re.compile(r'(?i)\b(https?)://')
# C0/C1 控制字符（保留 \n 交给调用方决定）、以及会让文字方向错乱的 Unicode 双向控制符
_CONTROL_RE = re.compile(r'[\x00-\x09\x0b-\x1f\x7f-\x9f\u200e\u200f\u202a-\u202e\u2066-\u2069]')
_WHITESPACE_RE = re.compile(r'\s+')

_ZWJ = '\u200d'
_VARIATION_SELECTORS = {'\ufe0e', '\ufe0f'}


def _is_regional_indicator(char: str) -> bool:
    return 0x1F1E6 <= ord(char) <= 0x1F1FF


def _is_dangling(char: str) -> bool:
    """截断点上不该成为最后一个字符的码点：它们依附于前一个字符或要与后一个字符组合。"""
    code = ord(char)
    return (
        char == _ZWJ
        or char in _VARIATION_SELECTORS
        or unicodedata.combining(char) != 0
        or 0xD800 <= code <= 0xDFFF            # 孤立代理项（来自畸形 JSON 的 \\ud83d）
        or 0x1F3FB <= code <= 0x1F3FF          # emoji 肤色修饰符
        or 0xE0020 <= code <= 0xE007F          # tag 序列（子区域旗帜）
    )


def safe_truncate(text: str, limit: int, ellipsis: str = ELLIPSIS) -> str:
    """按码点截断到 ≤ limit 个字符（含省略号），且不在字素簇中间下刀。

    Python str 以码点为单位，切片本身不会产生半个 UTF-8 字节序列；这里额外处理的是
    「码点合法、视觉上被切坏」的情况：ZWJ emoji 序列、组合附加符、肤色修饰、区域指示符对。
    """
    text = str(text)
    if limit <= 0:
        return ''
    if len(text) <= limit:
        return text
    if limit <= len(ellipsis):
        ellipsis = ''
    cut = text[:limit - len(ellipsis)]
    # 回退到安全边界：去掉悬空的 ZWJ / 变体选择符 / 组合附加符 / 肤色修饰符
    while cut and _is_dangling(cut[-1]):
        cut = cut[:-1]
    # 区域指示符必须成对（🇨🇳 = U+1F1E8 U+1F1F3）：末尾连续个数为奇数时丢掉落单的那个
    trailing = 0
    for char in reversed(cut):
        if not _is_regional_indicator(char):
            break
        trailing += 1
    if trailing % 2 == 1:
        cut = cut[:-1]
    return cut + ellipsis


def defang_urls(text: str) -> str:
    """把 http:// / https://（大小写不敏感）改成 http[:]// / https[:]//，使客户端不再自动识别为链接。"""
    return _URL_SCHEME_RE.sub(lambda m: f'{m.group(1)}[:]//', str(text))


def strip_controls(text: str) -> str:
    """去掉控制字符与双向控制符（保留换行，由调用方决定如何处理）。"""
    return _CONTROL_RE.sub('', str(text))


def one_line(text: str) -> str:
    """折叠所有空白（含换行）为单个空格：用于标题、键值对等必须单行的位置。"""
    return _WHITESPACE_RE.sub(' ', strip_controls(text)).strip()


def button_url(url: str | None) -> str:
    """卡片按钮的唯一取值来源：白名单校验通过且不超长才用，否则回落 Cloud Console 首页。

    解析器已对 console_url 做过 validate_console_url；这里再过一遍是纵深防御 ——
    渲染层不信任上游，任何漏网之鱼都不会变成可点击的外链按钮。
    """
    validated = validate_console_url(url)
    if not validated or len(validated.encode('utf-8')) > MAX_BUTTON_URL_BYTES:
        return DEFAULT_CONSOLE_URL
    return validated


def to_local(timestamp: str) -> str:
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
