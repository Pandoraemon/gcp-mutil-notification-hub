"""飞书自定义机器人的 HMAC-SHA256 签名。

算法（官方定义）：以 "{timestamp}\\n{secret}" 作为【密钥】、空字符串作为【消息】
做 HMAC-SHA256，再 base64 编码。注意密钥与消息的位置和直觉相反，写反的表现是
HTTP 200 + code=19021（sign match fail）—— 日志"成功"、群里收不到。
"""

import base64
import hashlib
import hmac


def sign(timestamp: str, secret: str) -> str:
    """计算签名。timestamp 必须与请求体中的 timestamp 完全一致（秒级）。"""
    string_to_sign = f'{timestamp}\n{secret}'
    digest = hmac.new(string_to_sign.encode('utf-8'), b'', digestmod=hashlib.sha256).digest()
    return base64.b64encode(digest).decode('utf-8')
