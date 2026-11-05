/**
 * Monitoring Notification Channel（pubsub 类型）。
 *
 * 这是 Cloud Monitoring 告警策略进入本系统的唯一入口：策略把 incident JSON
 * 投递到这个渠道，渠道再写入 topic。渠道本身不需要密钥，靠 IAM 授权
 * （见 pubsub.tf 中 monitoring 服务代理的 publisher 绑定）。
 */

resource "google_monitoring_notification_channel" "feishu" {
  provider = google-beta

  project      = var.project_id
  display_name = "Feishu Alert Hub"
  description  = "GCP 告警 → Pub/Sub → Cloud Functions → ${local.channel_label}群"
  type         = "pubsub"
  enabled      = true

  labels = {
    topic = google_pubsub_topic.main.id
  }

  depends_on = [
    google_project_service.required,
    # 渠道创建时 Monitoring 会校验自己能否向该 topic 投递，
    # 授权晚于渠道创建会导致创建失败或渠道处于不可用状态。
    google_pubsub_topic_iam_member.monitoring_publisher,
  ]
}
