"""进程内令牌桶 —— 约束单实例出速率。

为什么不能靠 max_instances：单次发送约 200ms，单实例串行即可达 ~300 次/分钟，
两实例约 600 次/分钟，是飞书 100 次/分钟限额的 6 倍。实例数限制的是并发度，不是速率。

配置须满足：MAX_SENDS_PER_MINUTE × max_instances ≤ 80（限额 100/min，留 20% 余量）。
令牌桶必须是模块级单例，若每次调用新建则每条消息都拿到满桶，限流形同虚设。

多渠道（本模块由 feishu/ 挪到 channels/，三个渠道共用）：企业微信 / 钉钉群机器人限额都是
20 条/分钟，默认速率 8/分钟/实例，须满足 MAX_SENDS_PER_MINUTE × max_instances ≤ 16。
"""

import threading
import time
from collections.abc import Callable


class TokenBucket:
    """单调时钟实现的令牌桶；acquire() 在无令牌时阻塞。

    阻塞受 Cloud Functions 60s 超时保护：超时即 nack → Pub/Sub 重试，消息不丢。
    """

    def __init__(
        self,
        rate_per_minute: float,
        capacity: float | None = None,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        if rate_per_minute <= 0:
            raise ValueError('rate_per_minute 必须为正数')
        self.rate_per_second = rate_per_minute / 60.0
        # 默认突发容量取速率的 1/10：既能吸收小抖动，又不会在告警风暴开头
        # 一次性放行整分钟的配额（那会瞬时超过飞书限额）
        self.capacity = float(capacity) if capacity else max(1.0, rate_per_minute / 10.0)
        self._clock = clock
        self._sleep = sleep
        self._tokens = self.capacity
        self._last = clock()
        self._lock = threading.Lock()

    def _refill(self) -> None:
        now = self._clock()
        elapsed = max(0.0, now - self._last)
        self._last = now
        self._tokens = min(self.capacity, self._tokens + elapsed * self.rate_per_second)

    def acquire(self, tokens: float = 1.0) -> float:
        """取走 tokens 个令牌，不足则阻塞等待。返回实际等待秒数（便于日志与测试）。"""
        if tokens > self.capacity:
            raise ValueError(f'单次请求 {tokens} 个令牌超过桶容量 {self.capacity}')
        waited = 0.0
        while True:
            with self._lock:
                self._refill()
                if self._tokens >= tokens:
                    self._tokens -= tokens
                    return waited
                deficit = tokens - self._tokens
                wait = deficit / self.rate_per_second
            self._sleep(wait)
            waited += wait
