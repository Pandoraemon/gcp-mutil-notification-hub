/**
 * 输出摘要。
 *
 * topic_name 被 deploy-terraform.sh 用于自检（terraform output -raw topic_name），
 * 改名会让部署最后一步失败。
 *
 * 这里【不输出任何密文】：只输出 Secret 的名称，值仍只存在于 Secret Manager。
 */

output "topic_name" {
  description = "告警汇聚主题名（自检脚本据此发布测试消息）"
  value       = google_pubsub_topic.main.name
}

output "topic_id" {
  description = "告警汇聚主题完整资源 ID"
  value       = google_pubsub_topic.main.id
}

output "dlq_topic_name" {
  description = "死信主题名"
  value       = google_pubsub_topic.dlq.name
}

output "dlq_subscription_name" {
  description = "死信订阅名（replay-dlq.sh 使用）"
  value       = google_pubsub_subscription.dlq.name
}

output "function_name" {
  description = "Cloud Functions 函数名"
  value       = google_cloudfunctions2_function.alerts.name
}

output "function_uri" {
  description = "函数底层 Cloud Run 服务 URL（仅内部可访问，用于排查）"
  value       = google_cloudfunctions2_function.alerts.service_config[0].uri
}

output "function_service_account" {
  description = "函数运行身份"
  value       = google_service_account.function.email
}

output "notification_channel_id" {
  description = "Monitoring Notification Channel（在告警策略中引用它即可接入本系统）"
  value       = google_monitoring_notification_channel.feishu.id
}

output "alert_policy_name" {
  description = "Service Health 主故障日志告警策略（未启用时为空）"
  value       = var.enable_psh ? google_monitoring_alert_policy.service_health[0].name : ""
}

output "psh_policy_names" {
  description = "PSH 日志告警策略集（两类：已确认故障 / 新兴故障；未启用时为空）"
  value = var.enable_psh ? [
    google_monitoring_alert_policy.service_health[0].name,
    google_monitoring_alert_policy.service_health_emerging[0].name,
  ] : []
}

output "self_monitoring_policy_names" {
  description = "自监控告警策略（永久发送失败 / DLQ 积压；ops_email 为空时不创建）"
  value = var.ops_email != "" ? [
    google_monitoring_alert_policy.self_permanent_send_failure[0].name,
    google_monitoring_alert_policy.self_dlq_backlog[0].name,
  ] : []
}

output "ops_email_channel_id" {
  description = "自监控邮件通知渠道（ops_email 为空时为空）"
  value       = var.ops_email != "" ? google_monitoring_notification_channel.ops_email[0].id : ""
}

output "scc_notification_config" {
  description = "SCC 导出配置（未启用时为空）"
  value       = var.enable_scc ? google_scc_notification_config.feishu[0].name : ""
}

output "billing_budget_name" {
  description = "Billing 预算（未启用时为空）"
  value       = var.enable_billing ? google_billing_budget.feishu[0].name : ""
}

output "notify_channel" {
  description = "本次部署的通知渠道（feishu / wecom / dingtalk）"
  value       = var.notify_channel
}

output "max_sends_per_minute" {
  description = "实际注入函数的单实例速率（max_sends_per_minute 为 null 时按渠道推导 40 / 8 / 8）"
  value       = local.max_sends_per_minute
}

output "secret_names" {
  description = "本渠道凭据所在的 Secret 名称，键为函数环境变量名（值不输出，也不进 tfstate）"
  value       = { for env, d in data.google_secret_manager_secret.channel : env => d.secret_id }
}

# 卸载说明里的 Secret 删除命令：本渠道按 local.channel_secret_list 顺序逐个删除；
# 其它渠道的 Secret 可能因曾切换渠道而残留（与 teardown-gcloud.sh「三套渠道存在才删」口径一致）。
# 用 join 预先拼好再插值：<<-EOT 中写 %{ for } 指令会破坏缩进剥离并留下空行。
locals {
  teardown_secret_cmds = join("\n", concat(
    [for s in local.channel_secret_list : "        gcloud secrets delete ${s.secret} --project=${var.project_id}"],
    length(local.other_channel_secret_names) > 0 ? ["      若曾使用过其它渠道，其 Secret 同样残留（先 describe 确认存在再删）："] : [],
    [for name in local.other_channel_secret_names : "        gcloud secrets describe ${name} --project=${var.project_id} >/dev/null 2>&1 && gcloud secrets delete ${name} --project=${var.project_id}"],
  ))
}

output "next_steps" {
  description = "部署后常用操作"
  value       = <<-EOT
    通知渠道: ${local.channel_label}（notify_channel = ${var.notify_channel}）
    接入新的 Monitoring 告警策略: 在策略的通知渠道中选择 "Feishu Alert Hub"（渠道名为历史兼容保留，实际投递到上面的通知渠道）
    紧急停止:  ./scripts/emergency-disable.sh --region=${var.region}
    DLQ 重放:  ./scripts/replay-dlq.sh

    卸载:  cd terraform && terraform destroy（或直接运行 ./scripts/teardown-terraform.sh --project=${var.project_id}）
      destroy 只清除 Terraform 管理的资源（函数 / Pub/Sub / SA / 通知渠道 / 告警策略 / 源码 bucket）。
      以下【不会】被清除，需要时请手工处理 —— 与 gcloud 路径的
      teardown-gcloud.sh 保持同样的口径，不把"卸载"说成比实际更干净：

        · Secret（含${local.channel_label}机器人 webhook${length(local.channel_secrets) > 1 ? " 与签名密钥" : ""}，属敏感数据）
    ${local.teardown_secret_cmds}
        · Terraform state bucket（自身无法销毁自己）
            gcloud storage rm -r gs://${var.project_id}-gcp-feishu-tfstate
        · Cloud Functions 自建的源码暂存 bucket
            gcloud storage rm -r gs://gcf-v2-sources-<项目编号>-${var.region}
        · 部署时为默认 compute SA 补授的 roles/cloudbuild.builds.builder
        · 已启用的 API（保留以免影响项目内其他服务）
  EOT
}

output "hub_source_projects" {
  description = "已接入的源项目清单"
  value       = var.source_projects
}

output "hub_scope_sink" {
  description = "源项目聚合 sink 范围"
  value       = var.source_scope
}
