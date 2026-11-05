/**
 * 通知渠道派生值（NOTIFY_CHANNEL = feishu | wecom | dingtalk，单平台三选一）。
 *
 * 所有「随渠道变化」的东西都只在这里查表，其它文件一律引用 local.*，
 * 避免把渠道分支散落到 secrets.tf / function.tf / outputs.tf 各处后漏改一处。
 *
 * 默认 notify_channel = feishu 时，每个派生值都与引入多渠道之前逐字一致：
 *   · Secret：FEISHU_DEFAULT_WEBHOOK ← feishu-default-webhook，FEISHU_DEFAULT_SECRET ← feishu-default-secret
 *   · 速率：40/分钟/实例，上限 80（= 飞书 100/min × 80%）
 * 存量飞书部署升级后 plan 只应出现函数的 in-place 更新（新增 NOTIFY_CHANNEL env + 新源码），
 * IAM 绑定由 secrets.tf 的 moved 块原地迁移，不应出现 destroy / replace。
 */

locals {
  # 渠道 → 有序的 [{ env, secret }]。
  # 顺序有意义：google_cloudfunctions2_function 的 secret_environment_variables 是 list 语义，
  # 飞书必须保持「WEBHOOK 在前、SECRET 在后」，与存量 state 一致，否则会产生无意义的重排 diff。
  # Secret 名的默认值见契约：feishu-default-{webhook,secret} / wecom-default-webhook /
  # dingtalk-default-{webhook,secret}，由部署脚本创建，Terraform 只引用（见 secrets.tf）。
  channel_secret_specs = {
    feishu = [
      { env = "FEISHU_DEFAULT_WEBHOOK", secret = var.feishu_default_webhook_secret },
      { env = "FEISHU_DEFAULT_SECRET", secret = var.feishu_default_sign_secret },
    ]
    # 企业微信群机器人没有签名机制（凭据就是 URL 里的 key），故只有一个 Secret
    wecom = [
      { env = "WECOM_DEFAULT_WEBHOOK", secret = var.wecom_default_webhook_secret },
    ]
    # 钉钉 SECRET 必填：未开启加签（关键词 / IP 模式）时其值为 NONE
    dingtalk = [
      { env = "DINGTALK_DEFAULT_WEBHOOK", secret = var.dingtalk_default_webhook_secret },
      { env = "DINGTALK_DEFAULT_SECRET", secret = var.dingtalk_default_sign_secret },
    ]
  }

  channel_secret_list = local.channel_secret_specs[var.notify_channel]

  # 本渠道 env 名 → Secret 名。for_each 的键用 env 名（如 "FEISHU_DEFAULT_WEBHOOK"），
  # secrets.tf 的 moved 块依赖这一点把旧的 webhook_accessor / sign_accessor 迁到对应键上。
  channel_secrets = tomap({ for s in local.channel_secret_list : s.env => s.secret })

  # 单实例默认速率（var.max_sends_per_minute = null 时生效）
  channel_default_rate = {
    feishu   = 40
    wecom    = 8
    dingtalk = 8
  }

  # 平台侧单机器人限流（条/分钟）：飞书 100；企微 20（超限 errcode 45009）；钉钉 20（超限 130101，封 10 分钟）
  channel_platform_limit = {
    feishu   = 100
    wecom    = 20
    dingtalk = 20
  }

  # 总出速率上限 = 平台限流 × 80%：速率 × max_instances 不得超过它（function.tf precondition）
  channel_rate_cap = {
    feishu   = 80
    wecom    = 16
    dingtalk = 16
  }

  # 面向人的渠道名，用于 outputs 与告警策略文档文案。飞书取值「飞书」，保证存量部署文案逐字不变。
  channel_label_map = {
    feishu   = "飞书"
    wecom    = "企业微信"
    dingtalk = "钉钉"
  }

  # 订阅最小重试退避间隔（钉钉 130101 封禁 10 分钟，设为 80s 覆盖窗口；飞书/企微保持 10s）
  channel_min_retry_delay = {
    feishu   = "10s"
    wecom    = "10s"
    dingtalk = "80s"
  }

  max_sends_per_minute = coalesce(var.max_sends_per_minute, local.channel_default_rate[var.notify_channel])
  rate_cap             = local.channel_rate_cap[var.notify_channel]
  platform_rate_limit  = local.channel_platform_limit[var.notify_channel]
  channel_label        = local.channel_label_map[var.notify_channel]
  min_retry_delay      = local.channel_min_retry_delay[var.notify_channel]

  # 三个渠道全部可能存在的 Secret 名（outputs 卸载说明用：曾切换过渠道时旧渠道 Secret 同样残留）
  all_channel_secret_names = distinct(flatten([
    for ch, specs in local.channel_secret_specs : [for s in specs : s.secret]
  ]))
  other_channel_secret_names = [
    for name in local.all_channel_secret_names : name if !contains(values(local.channel_secrets), name)
  ]
}
