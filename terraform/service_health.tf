/**
 * Personalized Service Health (PSH) 日志告警策略集 —— 两类。
 *
 * 覆盖：
 *   1. GCP Service Health Incident           —— 已确认故障（detailedCategory = CONFIRMED_INCIDENT）
 *   2. GCP Service Health Emerging Incident  —— 新兴故障早期预警（detailedCategory = EMERGING_INCIDENT）
 *
 * 为什么只有两类：PSH 写入 Cloud Logging 的 payload 是
 * google.cloud.servicehealth.logging.v1.EventLog，其 category 枚举只有 INCIDENT，
 * detailedCategory 只有 CONFIRMED_INCIDENT / EMERGING_INCIDENT
 * （REST 参考：cloud.google.com/service-health/docs/reference/rest/v1/projects.locations.events#EventCategory
 *  与 #DetailedCategory）。此前的「计划维护」「安全公告」两条策略过滤的
 * category 值在该日志源里不存在，永远不会触发，已删除以免造成「以为有覆盖、实际没有」。
 *
 * 与 gcloud 路径的 templates/service-health-alert-policy.yaml 及
 * templates/psh-emerging-incident-policy.yaml 语义完全一致。
 */

locals {
  psh_label_extractors = {
    # 事件 ID 不在 jsonPayload 里（EventLog 没有 eventId 字段），
    # 而在监控资源 servicehealth.googleapis.com/Event 的 event_id 标签上。
    event_id          = "EXTRACT(resource.labels.event_id)"
    category          = "EXTRACT(jsonPayload.category)"
    detailed_category = "EXTRACT(jsonPayload.detailedCategory)"
    state             = "EXTRACT(jsonPayload.state)"
    detailed_state    = "EXTRACT(jsonPayload.detailedState)"
    relevance         = "EXTRACT(jsonPayload.relevance)"
    title             = "EXTRACT(jsonPayload.title)"
  }
}

resource "google_monitoring_alert_policy" "service_health" {
  count        = var.enable_psh ? 1 : 0
  project      = var.project_id
  display_name = "GCP Service Health Incident"

  # teardown-gcloud.sh / configure.sh 的 remove_* 以此标签识别 Terraform 托管策略并跳过删除
  user_labels = {
    managed-by = "terraform"
  }
  combiner = "OR"
  enabled  = true

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      Google Cloud 服务健康事件 —— 已确认故障（Personalized Service Health - Confirmed Incident）。
      事件日志经本策略 → Pub/Sub topic ${var.topic_name} → Cloud Functions → ${local.channel_label}群。
      排查：docs/troubleshooting.md
    EOT
  }

  conditions {
    display_name = "Service Health 已确认故障事件日志"

    condition_matched_log {
      filter           = <<-EOT
        resource.type="servicehealth.googleapis.com/Event"
        AND jsonPayload.category="INCIDENT"
        AND jsonPayload.detailedCategory="CONFIRMED_INCIDENT"
      EOT
      label_extractors = local.psh_label_extractors
    }
  }

  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }
    auto_close = "604800s"
  }

  notification_channels = [google_monitoring_notification_channel.feishu.id]
  depends_on            = [google_project_service.required]
}

resource "google_monitoring_alert_policy" "service_health_emerging" {
  count        = var.enable_psh ? 1 : 0
  project      = var.project_id
  display_name = "GCP Service Health Emerging Incident"

  # teardown-gcloud.sh / configure.sh 的 remove_* 以此标签识别 Terraform 托管策略并跳过删除
  user_labels = {
    managed-by = "terraform"
  }
  combiner = "OR"
  enabled  = true

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      Google Cloud 服务健康事件 —— 新兴故障早期预警（Personalized Service Health - Emerging Incident）。
      当 Google SRE 初步探测到潜在服务异常（尚未完全确认影响面）时立即触发预警。
    EOT
  }

  conditions {
    display_name = "Service Health 新兴故障事件日志"

    condition_matched_log {
      filter           = <<-EOT
        resource.type="servicehealth.googleapis.com/Event"
        AND jsonPayload.category="INCIDENT"
        AND jsonPayload.detailedCategory="EMERGING_INCIDENT"
      EOT
      label_extractors = local.psh_label_extractors
    }
  }

  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }
    auto_close = "604800s"
  }

  notification_channels = [google_monitoring_notification_channel.feishu.id]
  depends_on            = [google_project_service.required]
}
