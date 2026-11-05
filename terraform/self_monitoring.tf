/**
 * 自监控（「监控的监控」）—— IM 链路（飞书 / 企业微信 / 钉钉）自身故障时的兜底通知。ops_email 为空时全部不创建。
 *
 * 本系统最反对的故障形态是「部署成功、日志无错、群里没卡片」。两种情况会恰好落进这个形态：
 *   (a) webhook 失效 / 签名错误 → 函数按设计 ack + ERROR 日志（reason=permanent_send_failure）
 *       → 没有重试、没有 DLQ、也没有人知道；
 *   (b) IM 平台持续不可达 → nack 5 次后进 DLQ → DLQ 里安静地堆着。
 * 这两条策略分别盯住 (a) 的日志与 (b) 的 DLQ 深度。
 *
 * 通知渠道【只用邮件】：IM 机器人正是这类故障里坏掉的那一环，再经 Feishu Alert Hub 通知等于没通知。
 * 这两条策略的 notification_channels 也刻意【不】挂 feishu 渠道，避免形成「发送失败 → 告警 →
 * 又去 IM 发送 → 又失败」的回环（函数侧有 SELF_PROJECT_ID 回环保护，但不该依赖它）。
 *
 * 与 gcloud 路径的 templates/self-monitoring-permanent-failure.yaml /
 * templates/self-monitoring-dlq-depth.yaml 语义一致。
 */

locals {
  self_monitoring_enabled = var.ops_email != ""
}

resource "google_monitoring_notification_channel" "ops_email" {
  count = local.self_monitoring_enabled ? 1 : 0

  project      = var.project_id
  display_name = "GCP Alerts Hub Ops Email"
  description  = "告警转发链路自身故障（永久发送失败 / DLQ 积压）的兜底邮件渠道"
  type         = "email"
  enabled      = true

  labels = {
    email_address = var.ops_email
  }

  depends_on = [google_project_service.required]
}

# (a) 永久发送失败：webhook 失效 / 签名密钥错误 / IM 平台业务码非 0 等「重试不可能改变结果」的失败。
# 日志由 src/main.py 的 logger.exception(..., extra={'reason': 'permanent_send_failure'}) 产生，
# StructuredFormatter 把 extra 键放在 JSON 顶层 → Cloud Logging 解析为 jsonPayload.reason。
# Gen2 函数的日志挂在底层 Cloud Run 服务上：resource.type = cloud_run_revision，
# resource.labels.service_name = 函数名（lib/common.sh 的自检也用同一组过滤器）。
resource "google_monitoring_alert_policy" "self_permanent_send_failure" {
  count        = local.self_monitoring_enabled ? 1 : 0
  project      = var.project_id
  display_name = "GCP Alerts Hub - Permanent Send Failure"

  # teardown-gcloud.sh / configure.sh 的 remove_* 以此标签识别 Terraform 托管策略并跳过删除
  user_labels = {
    managed-by = "terraform"
  }
  severity = "CRITICAL"
  combiner = "OR"
  enabled  = true

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      告警转发函数 ${var.function_name} 记录了【永久发送失败】：${local.channel_label} webhook 已失效、签名密钥错误，
      或${local.channel_label}返回非 0 业务码。此类消息按设计不会重试、不会进 DLQ —— 在修复前所有告警都在静默丢失。
      排查：
        gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="${var.function_name}" AND jsonPayload.reason="permanent_send_failure"' --project=${var.project_id} --limit=20
      修复 webhook 后需拉新 revision（Secret 以 :latest 挂载，只在实例启动时解析）。详见 docs/troubleshooting.md
    EOT
  }

  conditions {
    display_name = "Function log: permanent_send_failure"

    condition_matched_log {
      filter = <<-EOT
        resource.type="cloud_run_revision"
        AND resource.labels.service_name="${var.function_name}"
        AND jsonPayload.reason="permanent_send_failure"
      EOT
      label_extractors = {
        alert_type = "EXTRACT(jsonPayload.alert_type)"
        message_id = "EXTRACT(jsonPayload.message_id)"
      }
    }
  }

  alert_strategy {
    notification_rate_limit {
      period = "3600s"
    }
    auto_close = "86400s"
  }

  notification_channels = [google_monitoring_notification_channel.ops_email[0].id]
  depends_on            = [google_project_service.required]
}

# (b) DLQ 积压：消息 nack 满 dlq_max_delivery_attempts 次后进入 DLQ 订阅。
# pubsub.googleapis.com/subscription/num_undelivered_messages 是 GAUGE / INT64，
# 对死信订阅而言任何 > 0 持续 10 分钟都意味着有消息没送到 IM 群且无人处理（replay-dlq.sh）。
resource "google_monitoring_alert_policy" "self_dlq_backlog" {
  count        = local.self_monitoring_enabled ? 1 : 0
  project      = var.project_id
  display_name = "GCP Alerts Hub - DLQ Backlog"

  # teardown-gcloud.sh / configure.sh 的 remove_* 以此标签识别 Terraform 托管策略并跳过删除
  user_labels = {
    managed-by = "terraform"
  }
  severity = "ERROR"
  combiner = "OR"
  enabled  = true

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      死信订阅 ${var.dlq_subscription_name} 中有未处理消息持续超过 10 分钟：
      这些告警已重试 ${var.dlq_max_delivery_attempts} 次仍未送达${local.channel_label}。
      处理：先确认${local.channel_label}侧已恢复，再运行 ./scripts/replay-dlq.sh 重放。详见 docs/troubleshooting.md
    EOT
  }

  conditions {
    display_name = "DLQ num_undelivered_messages > 0 (10m)"
    condition_threshold {
      filter          = "resource.type = \"pubsub_subscription\" AND resource.labels.subscription_id = \"${var.dlq_subscription_name}\" AND metric.type = \"pubsub.googleapis.com/subscription/num_undelivered_messages\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "600s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }

  alert_strategy {
    auto_close = "86400s"
  }

  notification_channels = [google_monitoring_notification_channel.ops_email[0].id]
  depends_on = [
    google_project_service.required,
    google_pubsub_subscription.dlq,
  ]
}
