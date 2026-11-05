"""部署自检事件解析。

类型名必须是 test_event（对应模板 test_event_card.json.j2）：
连字符形式 self-test 既不匹配任何模板，也不在 ALERT_TYPES 中，会直接触发 PermanentError。

自检事件固定 INFO，并由 Router.should_send() 特判绕过 MIN_SEVERITY 过滤 ——
否则默认 MIN_SEVERITY=MEDIUM 下自检永远收不到卡片。
"""

from typing import Any

from parsers.base import BaseParser, ParsedAlert, stringify_fields, to_iso8601


class TestEventParser(BaseParser):
    # 名字以 Test 开头，告诉 pytest 这是解析器而不是测试类
    __test__ = False

    alert_type = 'test_event'

    def _parse(self, message: dict[str, Any]) -> ParsedAlert:
        project_id = str(message.get('project_id') or '')
        deployment_time = str(message.get('deployment_time') or '')

        components = message.get('components') or {}
        fields = stringify_fields({
            '项目': project_id,
            '版本': message.get('version'),
            '部署时间': deployment_time,
            **{f'组件 · {k}': _health_text(v) for k, v in components.items()},
        })

        return ParsedAlert(
            type=self.alert_type,
            severity='INFO',
            title='连通性自检成功',
            fields=fields,
            dedup_key=f'test_event:{deployment_time}',
            console_url=(
                f'https://console.cloud.google.com/functions/list?project={project_id}'
                if project_id else None
            ),
            timestamp=to_iso8601(deployment_time),
            source_project=project_id,
            raw_severity='',
        )


def _health_text(value: Any) -> str:
    text = str(value)
    return f'✅ {text}' if text == 'healthy' else f'⚠️ {text}'
