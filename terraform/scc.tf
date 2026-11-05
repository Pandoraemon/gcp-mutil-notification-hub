/**
 * Security Command Center Continuous Export（可选，需组织级权限）。
 *
 * 前置条件由 deploy-terraform.sh 探测：项目不在组织下、或当前身份缺少
 * roles/securitycenter.notificationConfigEditor 时，脚本会把 enable_scc 置为 false，
 * 而不是让 terraform apply 在中途报 403 —— 部署失败一半比"跳过可选模块"更难收拾。
 */

resource "google_scc_notification_config" "feishu" {
  count    = var.enable_scc ? 1 : 0
  provider = google-beta

  config_id    = "feishu-scc-export"
  organization = var.scc_organization_id
  description  = "高危及以上安全发现推送到${local.channel_label}安全群"
  pubsub_topic = google_pubsub_topic.main.id

  streaming_config {
    # 只导出 HIGH / CRITICAL：SCC 的低危发现量极大，全量推送会淹没告警群，
    # 且函数侧的 MIN_SEVERITY 过滤只能减少卡片，减不了 Pub/Sub 与函数调用成本。
    filter = "severity=\"HIGH\" OR severity=\"CRITICAL\""
  }

  depends_on = [
    google_project_service.required,
    google_pubsub_topic_iam_member.scc_publisher,
  ]

  lifecycle {
    precondition {
      condition     = !var.enable_scc || var.scc_organization_id != ""
      error_message = "enable_scc = true 时必须提供 scc_organization_id。"
    }
  }
}
