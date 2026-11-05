/**
 * 输入变量。
 *
 * 这里【不接受任何密文】：webhook 与签名密钥只以 Secret 名称的形式传入，
 * 密文由 deploy-terraform.sh 用 gcloud 写入 Secret Manager，
 * 因此既不进 tfstate 也不进 tfvars（见 secrets.tf 与规格说明书"Secret 所有权约定"）。
 */

variable "project_id" {
  description = "GCP 项目 ID"
  type        = string
}

variable "region" {
  description = "部署区域（Cloud Functions / Eventarc / 源码 bucket）"
  type        = string
  default     = "asia-east1"
}

variable "enable_psh" {
  description = "是否启用 Personalized Service Health (PSH) 日志告警策略集（两类：已确认故障 / 新兴故障。PSH 事件日志的 category 只有 INCIDENT，detailedCategory 区分 CONFIRMED_INCIDENT / EMERGING_INCIDENT）"
  type        = bool
  default     = true
}

variable "enable_default_alerts" {
  description = "是否一键启用推荐默认监控告警包（GCE/配额/LB&NAT/GKE&SQL/高危IAM审计）"
  type        = bool
  default     = false
}

variable "enable_scc" {
  description = "是否启用 Security Command Center Continuous Export（需要组织级权限）"
  type        = bool
  default     = false
}

variable "enable_billing" {
  description = "是否启用 Billing 预算告警（需要 roles/billing.admin）。警告：已启用后改为 false，apply 会【销毁】本配置管理的预算本身，而不只是停止通知；deploy-terraform.sh 读不到结算账号时会拒绝执行以防误删，直接 terraform apply 则没有这道保护"
  type        = bool
  default     = false
}

variable "scc_organization_id" {
  description = "SCC 所属组织 ID，enable_scc = true 时必填"
  type        = string
  default     = ""

  validation {
    condition     = var.scc_organization_id == "" || can(regex("^[0-9]+$", var.scc_organization_id))
    error_message = "scc_organization_id 必须是纯数字的组织 ID（不含 organizations/ 前缀）。"
  }
}

variable "billing_account_id" {
  description = "结算账号 ID（不含 billingAccounts/ 前缀），enable_billing = true 时必填"
  type        = string
  default     = ""

  validation {
    condition     = var.billing_account_id == "" || can(regex("^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$", var.billing_account_id))
    error_message = "billing_account_id 必须形如 01ABCD-2345EF-6789AB（三段大写十六进制，不含 billingAccounts/ 前缀），或留空。"
  }
}

variable "billing_amount" {
  description = "月度预算金额（整数，单位见 billing_currency）"
  type        = string
  default     = "100"
}

variable "billing_currency" {
  description = "预算币种"
  type        = string
  default     = "USD"
}

variable "notify_channel" {
  description = <<-EOT
    通知渠道（单平台三选一，注入函数环境变量 NOTIFY_CHANNEL）：
      feishu（默认，存量部署零变化）/ wecom（企业微信群机器人）/ dingtalk（钉钉自定义机器人）。
    default / security / billing 三个路由组都走同一渠道。只有本渠道的 Secret 会被引用与授权，
    其余渠道的 *_secret 变量被忽略（见 channels.tf 的 local.channel_secrets）。
  EOT
  type        = string
  default     = "feishu"

  validation {
    condition     = contains(["feishu", "wecom", "dingtalk"], var.notify_channel)
    error_message = "notify_channel 必须是 feishu / wecom / dingtalk 之一。"
  }
}

variable "feishu_default_webhook_secret" {
  description = "存放飞书 webhook URL 的 Secret 名称（值由部署脚本写入）"
  type        = string
  default     = "feishu-default-webhook"
}

variable "feishu_default_sign_secret" {
  description = "存放飞书签名密钥的 Secret 名称（未开启签名校验时其值为 NONE）"
  type        = string
  default     = "feishu-default-secret"
}

variable "wecom_default_webhook_secret" {
  description = "notify_channel = wecom 时：存放企业微信群机器人 webhook URL 的 Secret 名称（值由部署脚本写入；企微无签名，故无对应 sign Secret）"
  type        = string
  default     = "wecom-default-webhook"
}

variable "dingtalk_default_webhook_secret" {
  description = "notify_channel = dingtalk 时：存放钉钉自定义机器人 webhook URL 的 Secret 名称（值由部署脚本写入）"
  type        = string
  default     = "dingtalk-default-webhook"
}

variable "dingtalk_default_sign_secret" {
  description = "notify_channel = dingtalk 时：存放钉钉加签密钥的 Secret 名称（未开启加签、改用关键词/IP 安全设置时其值为 NONE）"
  type        = string
  default     = "dingtalk-default-secret"
}

variable "topic_name" {
  description = "告警汇聚主题名（四个数据源统一投递到这里）"
  type        = string
  default     = "gcp-alerts-hub"
}

variable "dlq_topic_name" {
  description = "死信主题名"
  type        = string
  default     = "gcp-alerts-dlq"
}

variable "dlq_subscription_name" {
  description = "死信订阅名（replay-dlq.sh 依赖它读取失败消息，不能省略）"
  type        = string
  default     = "gcp-alerts-dlq-sub"
}

variable "function_name" {
  description = "Cloud Functions 函数名"
  type        = string
  default     = "gcp-alerts-to-feishu"
}

variable "service_account_id" {
  description = "函数使用的自定义 Service Account ID"
  type        = string
  default     = "gcp-alerts-fn"
}

variable "log_level" {
  description = "函数日志级别。默认 INFO：WARNING 会把\"告警被过滤\"\"发送成功\"一并关掉，等于关掉唯一的诊断信号"
  type        = string
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"], var.log_level)
    error_message = "log_level 必须是 DEBUG / INFO / WARNING / ERROR / CRITICAL 之一。"
  }
}

variable "min_severity" {
  description = "最低转发严重性（自检事件绕过此过滤）"
  type        = string
  default     = "MEDIUM"

  validation {
    condition     = contains(["INFO", "LOW", "MEDIUM", "HIGH", "CRITICAL"], var.min_severity)
    error_message = "min_severity 必须是 INFO / LOW / MEDIUM / HIGH / CRITICAL 之一。"
  }
}

variable "max_sends_per_minute" {
  description = <<-EOT
    单实例出口令牌桶速率（条/分钟）。默认 null = 按渠道推导：feishu 40 / wecom 8 / dingtalk 8
    （见 channels.tf 的 local.max_sends_per_minute）。显式设置时须满足
    速率 × max_instances ≤ 渠道上限（feishu 80 / wecom 16 / dingtalk 16），否则 plan 失败。
  EOT
  type        = number
  default     = null

  validation {
    # 用条件表达式而非 ||：Terraform 1.9 的 || 不短路，null > 0 会直接报类型错误
    condition     = var.max_sends_per_minute == null ? true : (var.max_sends_per_minute > 0 && floor(var.max_sends_per_minute) == var.max_sends_per_minute)
    error_message = "max_sends_per_minute 必须为 null（按渠道取默认值）或正整数：0 会让函数部署成功但永远不发任何卡片（静默失效），小数会让函数启动期解析失败。"
  }
}

variable "max_instances" {
  description = "函数最大实例数。实例数不是速率控制手段，但它与令牌桶速率相乘决定总出速率"
  type        = number
  default     = 2

  validation {
    condition     = var.max_instances >= 1
    error_message = "max_instances 至少为 1。"
  }
}

variable "dlq_max_delivery_attempts" {
  description = "投递失败多少次后转入 DLQ（Pub/Sub 硬限制 5–100）"
  type        = number
  default     = 5

  validation {
    # Pub/Sub 死信策略的硬限制；不在这里拦截的话要到 apply 最后一步的 local-exec 才失败，留下半成品 state
    condition     = var.dlq_max_delivery_attempts >= 5 && var.dlq_max_delivery_attempts <= 100
    error_message = "dlq_max_delivery_attempts 必须在 5 到 100 之间（Pub/Sub 死信策略硬限制）。"
  }
}

variable "run_invoker_scope" {
  description = <<-EOT
    Eventarc 触发器身份（函数 SA）的 roles/run.invoker 授权层级：
      service（默认）—— 只授在函数底层的 Cloud Run 服务上（最小权限）。部署者需要
                         run.services.setIamPolicy（含于 roles/run.admin；roles/editor 与
                         roles/resourcemanager.projectIamAdmin 都【不】含）。
      project          —— 授在项目级（与 gcloud 路径「优先检查项目级绑定」的做法对齐）。
                         部署者只需 resourcemanager.projects.setIamPolicy，但该 SA 可调用项目内所有 Run 服务。
  EOT
  type        = string
  default     = "service"

  validation {
    condition     = contains(["service", "project"], var.run_invoker_scope)
    error_message = "run_invoker_scope 必须是 service 或 project。"
  }
}

variable "ops_email" {
  description = <<-EOT
    自监控告警（IM 链路自身故障：永久发送失败 / DLQ 积压）的邮件收件人。
    留空则不创建自监控资源（self_monitoring.tf 全部 count = 0）。
    通知渠道刻意只用邮件：IM 机器人（飞书 / 企业微信 / 钉钉）正是这类故障里坏掉的那一环，不能再经它通知。
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.ops_email == "" || can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.ops_email))
    error_message = "ops_email 必须是邮箱地址或留空。"
  }
}

variable "kill_switch" {
  description = "注入函数环境变量 KILL_SWITCH：true 时函数对所有消息直接 ack 丢弃（急停）。注意 emergency-disable.sh 改的是底层 Run 服务，下一次 apply 会按本变量复位，要让急停持久必须改这里"
  type        = bool
  default     = false
}

variable "pause_mode" {
  description = "注入函数环境变量 PAUSE_MODE：true 时函数对所有消息 nack（暂停投递，消息按重试/死信策略处理）。同样会被下一次 apply 按本变量复位"
  type        = bool
  default     = false
}

variable "config_revision" {
  description = <<-EOT
    配置修订号（注入函数环境变量 CONFIG_REVISION）。scripts/configure.sh 每次应用都会写入新的 UTC 时间戳，
    使函数【必定】拉起新 revision —— 即使只换了 Secret 值（version = "latest" 只在实例启动时解析）。
    空字符串（默认）表示不注入该环境变量，存量部署 plan 无变化。
  EOT
  type        = string
  default     = ""

  validation {
    # 与 shell 侧（lib/common.sh resolve_runtime_config）同口径
    condition     = var.config_revision == "" || can(regex("^[A-Za-z0-9._:-]{1,64}$", var.config_revision))
    error_message = "config_revision 只允许字母、数字与 . _ : -（最长 64），或留空。"
  }
}

variable "source_min_severity" {
  description = "按告警来源设置最低严重性阈值（字典），覆盖全局 min_severity。合法 key 为 monitoring, service_health, billing, scc。合法 value 为 OFF, CRITICAL, HIGH, MEDIUM, LOW, INFO（大小写不敏感）。"
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for k, v in var.source_min_severity :
      contains(["monitoring", "service_health", "billing", "scc"], k) &&
      contains(["OFF", "CRITICAL", "HIGH", "MEDIUM", "LOW", "INFO"], upper(v))
    ])
    error_message = "source_min_severity 的 key 必须是 monitoring, service_health, billing, scc 之一；value 必须是 OFF 或有效的严重性级别。"
  }
}

variable "source_projects" {
  description = "List of source project IDs to connect to the Hub."
  type        = list(string)
  default     = []
  validation {
    condition = alltrue([
      for p in var.source_projects : can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", p))
    ])
    error_message = "Each source project ID must be 6-30 lowercase letters, digits, or hyphens, starting with a letter and ending with a letter or digit."
  }
  validation {
    condition     = !contains(var.source_projects, var.project_id)
    error_message = "The Hub project itself cannot be in source_projects."
  }
}

variable "source_scope" {
  description = "Scope for aggregated log sink (folders/123 or organizations/456). If empty, project-level sinks are used."
  type        = string
  default     = ""
  validation {
    condition     = var.source_scope == "" || can(regex("^(folders|organizations)/[0-9]+$", var.source_scope))
    error_message = "source_scope must be empty, or in the format 'folders/123' or 'organizations/456'."
  }
}

variable "source_projects_in_scope" {
  description = "source_projects 中位于 source_scope（文件夹 / 组织）之内的项目 ID；由部署脚本按祖先链计算。这些项目不建项目级 sink（由聚合 sink 覆盖），其余仍建。"
  type        = list(string)
  default     = []
}
