"""IM 投递渠道：飞书 / 企业微信 / 钉钉。

每次部署只启用一个渠道（Config.NOTIFY_CHANNEL），由 channels.registry 返回
(builder, sender) 单例对。各渠道共享 channels.base.WebhookSender 的令牌桶 +
退避重试循环，只各自实现「请求怎么拼」(prepare) 与「响应怎么判」(classify)。
"""
