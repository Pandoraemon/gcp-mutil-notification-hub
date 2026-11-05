"""企业微信 template_card（text_notice 文本通知型）渲染。

官方字段约束（https://developer.work.weixin.qq.com/document/path/91770 「模版卡片类型 → 文本通知模版卡片」）：

| 字段 | 官方说明 | 本实现 |
|---|---|---|
| main_title.title | 建议不超过 26 个字；与 sub_title_text 二者必填其一 | 图标 + 标题，截断到 26 |
| main_title.desc | 建议不超过 30 个字 | 告警时间（UTC+8），截断到 30 |
| emphasis_content.title / desc | 建议不超过 10 / 15 个字 | 严重性枚举 / 告警类型标签 |
| source.desc | 建议不超过 13 个字 | 固定文案「GCP告警」 |
| sub_title_text | 建议不超过 112 个字 | 放不进横向列表的字段，截断到 112 |
| horizontal_content_list | 长度 ≤ 6（超出报 42035）；keyname ≤ 5 字、value ≤ 26 字 | 不超长的前 6 个字段 |
| jump_list.title | 建议不超过 13 个字 | 固定文案「查看详情」 |
| card_action | text_notice 必填；type=1 时 url 必填 | 白名单 URL，缺省回落 Cloud Console 首页 |

官方只给出「建议」字数，超出时客户端行为未公开（待确认）—— 按最保守方式一律截断到建议值以内。

安全不变量：
- 告警数据只进上表中的纯文本字段，不使用 markdown 消息类型；横向列表项永不设置 type=1（url）；
- 所有告警文本经 defang_urls()：企业微信客户端是否会把纯文本里的裸 URL 识别成可点击链接
  未见官方说明（待确认），按会识别处理；
- 唯一的可点击目标是 card_action / jump_list，二者都只取 sanitize.button_url() 的结果。
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

MAX_MAIN_TITLE = 26
MAX_MAIN_DESC = 30
MAX_EMPHASIS_TITLE = 10
MAX_EMPHASIS_DESC = 15
MAX_SUB_TITLE = 112
MAX_HORIZONTAL_ITEMS = 6
MAX_KEYNAME = 5
MAX_VALUE = 26
# sub_title_text 里单个字段行的上限：防止一个超长字段（如 SCC 说明）独占全部 112 字
MAX_SUB_LINE = MAX_SUB_TITLE // 2

SOURCE_DESC = 'GCP告警'
JUMP_TITLE = '查看详情'

# source.desc_color：0 灰 / 1 黑 / 2 红 / 3 绿
_SOURCE_COLORS = {'CRITICAL': 2, 'HIGH': 2, 'MEDIUM': 1, 'LOW': 0, 'INFO': 0}

TEST_EVENT_NOTE = '本条为部署自检消息，收到即表示 Pub/Sub → Cloud Functions → 企业微信 链路已打通。'


def _text(value: Any) -> str:
    """告警数据进入任何字段前的统一清洗：单行化 + 去控制字符 + 裸 URL 去活。"""
    return defang_urls(one_line(value))


class WecomCardBuilder:
    """企业微信 template_card(text_notice) 构造器（纯 Python，无模板）。"""

    def build(self, alert: ParsedAlert) -> dict[str, Any]:
        try:
            return self._build(alert)
        except (KeyError, TypeError, ValueError, AttributeError) as exc:
            # 契约违约（如未知 severity）或渲染缺陷：同一条消息重试结果不变 → 永久性失败
            logger.error('WeCom card rendering failed',
                         extra={'alert_type': getattr(alert, 'type', None),
                                'error': f'{type(exc).__name__}: {exc}'})
            raise PermanentError(f'wecom card render failed: {exc}') from exc

    def _build(self, alert: ParsedAlert) -> dict[str, Any]:
        is_test = alert.type == 'test_event'
        icon = TEST_EVENT_ICON if is_test else SEVERITY_ICONS[alert.severity]
        label = TYPE_LABELS.get(alert.type, GENERIC_TYPE_LABEL)
        title = _text(alert.title)

        full_title = f'{icon} {title}'
        main_title = safe_truncate(full_title, MAX_MAIN_TITLE)

        horizontal: list[dict[str, str]] = []
        overflow: list[str] = []
        if main_title != full_title:
            # 标题被截断时，完整标题作为副标题第一行，不丢信息
            overflow.append(safe_truncate(title, MAX_SUB_LINE))
        if is_test:
            overflow.append(TEST_EVENT_NOTE)

        for raw_key, raw_value in alert.fields.items():
            key, value = _text(raw_key), _text(raw_value)
            if not key or not value:
                continue
            if (len(horizontal) < MAX_HORIZONTAL_ITEMS
                    and len(key) <= MAX_KEYNAME and len(value) <= MAX_VALUE):
                horizontal.append({'keyname': key, 'value': value})
            else:
                # 超出条数、或 key/value 超过建议长度：整行拼进 sub_title_text，
                # 而不是把资源名之类的关键信息硬截成 26 个字
                overflow.append(safe_truncate(f'{key}：{value}', MAX_SUB_LINE))

        card: dict[str, Any] = {
            'card_type': 'text_notice',
            'source': {'desc': SOURCE_DESC, 'desc_color': _SOURCE_COLORS[alert.severity]},
            'main_title': {
                'title': main_title,
                'desc': safe_truncate(_text(to_local(alert.timestamp)), MAX_MAIN_DESC),
            },
            'emphasis_content': {
                'title': safe_truncate(alert.severity, MAX_EMPHASIS_TITLE),
                'desc': safe_truncate(label, MAX_EMPHASIS_DESC),
            },
        }
        sub_title = safe_truncate('\n'.join(overflow), MAX_SUB_TITLE)
        if sub_title:
            card['sub_title_text'] = sub_title
        if horizontal:
            card['horizontal_content_list'] = horizontal

        url = button_url(alert.console_url)
        card['jump_list'] = [{'type': 1, 'title': JUMP_TITLE, 'url': url}]
        card['card_action'] = {'type': 1, 'url': url}

        return {'msgtype': 'template_card', 'template_card': card}
