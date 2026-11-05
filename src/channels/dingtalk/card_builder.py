"""钉钉 actionCard（整体跳转）渲染。

官方格式（https://open.dingtalk.com/document/orgapp/custom-bot-send-message-type）：
{"msgtype": "actionCard", "actionCard": {"title", "text"(markdown), "singleTitle", "singleURL"}}
四个字段都是必填。text 支持的 markdown 子集：标题、引用、加粗/斜体、链接、图片。

安全不变量（告警数据由消息发送方控制，必须当作不可信输入）：
1. title 固定前缀「GCP告警」：兼容机器人的「自定义关键词」安全设置（关键词填 GCP告警），
   text 首行再出现一次，无论钉钉按 title 还是 text 匹配关键词都能命中；
2. text 里所有告警数据先 escape_markdown() 再 defang_urls()：
   - 链接 / 图片都依赖 `[`，HTML 与引用依赖 `<` `>` —— 这四个字符替换为全角，
     与渲染器是否支持反斜杠转义无关（钉钉文档未列出转义语法，待确认），结构性地不可能拼出链接；
   - 换行折叠为空格：数据不能另起一行伪造标题 / 引用；
   - `*` 替换为全角：数据不能伪造加粗、也不能闭合模板里的 `**key**`；
   - 裸 URL 协议头改成 `http[:]//`，客户端不会识别成可点击链接；
3. singleURL 只取 sanitize.button_url()（白名单校验通过，否则 Cloud Console 首页）；
   singleTitle 为固定文案。整条消息唯一的可点击目标就是这个按钮。

长度：官方未公开 text 上限（待确认）。按保守值截断：单个字段值 ≤ 500 字、整段 text ≤ 4000 字。
"""

import logging
from typing import Any

from channels.sanitize import (
    GENERIC_TYPE_LABEL,
    SEVERITY_ICONS,
    TEST_EVENT_ICON,
    TYPE_LABELS,
    button_url,
    defang_urls,
    one_line,
    safe_truncate,
    to_local,
)
from errors import PermanentError
from parsers.base import ParsedAlert

logger = logging.getLogger(__name__)

TITLE_PREFIX = 'GCP告警'
SINGLE_TITLE = '查看详情'
MAX_TITLE = 100
MAX_FIELD_VALUE = 500
MAX_TEXT = 4000

TEST_EVENT_NOTE = '本条为部署自检消息，收到即表示 Pub/Sub → Cloud Functions → 钉钉 链路已打通。'

# 结构性字符 → 全角：不依赖渲染器的转义支持
_MARKDOWN_TRANSLATION = str.maketrans({
    '[': '［', ']': '］', '<': '＜', '>': '＞', '*': '＊',
})


def escape_markdown(text: Any) -> str:
    """把告警数据变成「在钉钉 markdown 里只能是字面文本」的单行字符串。

    不改 `_` `#` `-` 等：它们在单行、非行首的位置不构成钉钉支持的 markdown 结构，
    而 GCP 资源名里 `_` / `-` 极其常见，改掉会严重影响可读性。
    """
    return one_line(text).translate(_MARKDOWN_TRANSLATION)


def _md(text: Any, limit: int | None = None) -> str:
    """告警数据进入 text 的唯一通道：转义 → 截断 → 去活（去活放最后，保证 `[:]` 不被截掉一半后残留）。"""
    escaped = escape_markdown(text)
    if limit is not None:
        escaped = safe_truncate(escaped, limit)
    return defang_urls(escaped)


class DingtalkCardBuilder:
    """钉钉 actionCard 构造器（纯 Python，无模板）。"""

    def build(self, alert: ParsedAlert) -> dict[str, Any]:
        try:
            return self._build(alert)
        except (KeyError, TypeError, ValueError, AttributeError) as exc:
            logger.error('DingTalk card rendering failed',
                         extra={'alert_type': getattr(alert, 'type', None),
                                'error': f'{type(exc).__name__}: {exc}'})
            raise PermanentError(f'dingtalk card render failed: {exc}') from exc

    def _build(self, alert: ParsedAlert) -> dict[str, Any]:
        is_test = alert.type == 'test_event'
        icon = TEST_EVENT_ICON if is_test else SEVERITY_ICONS[alert.severity]
        label = TYPE_LABELS.get(alert.type, GENERIC_TYPE_LABEL)

        # title 是会话列表里的预览文本：同样转义 + 去活（不确定所有客户端都按纯文本展示），
        # 并把关键词前缀放在最前，截断永远截不到它
        plain_title = defang_urls(escape_markdown(alert.title))
        title = safe_truncate(f'{TITLE_PREFIX} {icon} {alert.severity} {plain_title}', MAX_TITLE)

        lines = [
            f'#### {TITLE_PREFIX} · {icon} {alert.severity} · {label}',
            f'**{_md(alert.title)}**',
        ]
        if is_test:
            lines.append(TEST_EVENT_NOTE)
        for key, value in alert.fields.items():
            key_md, value_md = _md(key, MAX_FIELD_VALUE), _md(value, MAX_FIELD_VALUE)
            if key_md and value_md:
                lines.append(f'**{key_md}**：{value_md}')
        lines.append(f'🕐 {_md(to_local(alert.timestamp))}')

        # 段落之间用空行分隔（钉钉 markdown 对单个 \n 不换行）。
        # 整体截断不会制造链接：所有 `[` `<` 已被替换，截断只可能留下未闭合的 `**`（仅影响样式）
        text = safe_truncate('\n\n'.join(lines), MAX_TEXT)

        return {
            'msgtype': 'actionCard',
            'actionCard': {
                'title': title,
                'text': text,
                'singleTitle': SINGLE_TITLE,
                'singleURL': button_url(alert.console_url),
            },
        }
