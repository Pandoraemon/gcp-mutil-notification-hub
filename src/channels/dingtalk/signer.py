"""钉钉自定义机器人的「加签」。

官方算法（https://open.dingtalk.com/document/robots/customize-robot-security-settings）：
把 "{timestamp}\\n{secret}" 当作签名字符串（【消息】），以 secret 为【密钥】做 HmacSHA256，
Base64 编码后再 urlEncode（UTF-8），以 query 参数 timestamp / sign 追加到 webhook。
timestamp 为【毫秒】，与钉钉服务器时间误差不得超过 1 小时。

⚠️ 与飞书正好相反：飞书以 "{ts}\\n{secret}" 为密钥、空串为消息，秒级时间戳，签名放请求体。
写反的表现是 HTTP 200 + errcode=310000 —— 固定向量见 tests/test_dingtalk.py。
"""

import base64
import hashlib
import hmac
from urllib.parse import quote_plus


def sign(timestamp_ms: str | int, secret: str) -> str:
    """返回已 urlencode 的签名，可直接拼进 query（不要再编码一次）。"""
    string_to_sign = f'{timestamp_ms}\n{secret}'
    digest = hmac.new(secret.encode('utf-8'), string_to_sign.encode('utf-8'),
                      digestmod=hashlib.sha256).digest()
    return quote_plus(base64.b64encode(digest).decode('utf-8'))
