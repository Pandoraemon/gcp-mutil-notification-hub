/**
 * 推荐的默认高级监控告警包（enable_default_alerts = true 时创建）。
 *
 * 与 gcloud 路径的 templates/default-alerts/*.yaml 一一对应，覆盖五大类核心监控：
 *   1. GCE 核心基础设施（CPU 高负载、磁盘空间不足、宿主机故障/维护迁移事件）
 *   2. 配额预警（GCP Quota 超限与高水位预警）
 *   3. 网络与负载均衡（HTTP LB 5xx 错误激增、Cloud NAT 端口分配失败与丢包）
 *   4. GKE 与数据库基础告警（GKE 容器重启与内存 OOM 风险、Cloud SQL CPU/内存/磁盘高水位）
 *   5. 高危安全审计日志告警（高危 IAM 赋权变更、Service Account Key 创建）
 */

# 1a. GCE CPU 高负载 (> 85% 持续 5m)
resource "google_monitoring_alert_policy" "rec_gce_cpu_high" {
  count        = var.enable_default_alerts ? 1 : 0
  project      = var.project_id
  display_name = "Recommended - GCE High CPU Utilization"

  # teardown-gcloud.sh / configure.sh 的 remove_* 以此标签识别 Terraform 托管策略并跳过删除
  user_labels = {
    managed-by = "terraform"
  }
  severity = "WARNING"
  combiner = "OR"
  enabled  = true

  documentation {
    mime_type = "text/markdown"
    content   = "GCE 虚拟机 CPU 平均使用率连续 5 分钟超过 85%。建议检查实例内高 CPU 进程、机器规格是否不足或 MIG 自动扩缩容配置。"
  }

  conditions {
    display_name = "GCE VM CPU Utilization > 85% (5m)"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"compute.googleapis.com/instance/cpu/utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.85
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  alert_strategy {
    auto_close = "86400s"
  }

  notification_channels = [google_monitoring_notification_channel.feishu.id]
  depends_on            = [google_project_service.required]
}

# 1b. GCE 磁盘空间不足 (> 85% 持续 5m)
resource "google_monitoring_alert_policy" "rec_gce_disk_high" {
  count        = var.enable_default_alerts ? 1 : 0
  project      = var.project_id
  display_name = "Recommended - GCE Disk Space High Utilization"

  # teardown-gcloud.sh / configure.sh 的 remove_* 以此标签识别 Terraform 托管策略并跳过删除
  user_labels = {
    managed-by = "terraform"
  }
  severity = "WARNING"
  combiner = "OR"
  enabled  = true

  documentation {
    mime_type = "text/markdown"
    content   = "GCE 虚拟机磁盘已用空间超过 85%（需实例已安装 Ops Agent 上报 agent.googleapis.com/disk/percent_used）。建议及时清理日志或在线扩容磁盘。"
  }

  conditions {
    display_name = "GCE Disk Percent Used > 85% (5m)"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"agent.googleapis.com/disk/percent_used\" AND metric.labels.state = \"used\""
      comparison      = "COMPARISON_GT"
      threshold_value = 85.0
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  alert_strategy {
    auto_close = "86400s"
  }

  notification_channels = [google_monitoring_notification_channel.feishu.id]
  depends_on            = [google_project_service.required]
}

# 1c. GCE 宿主机故障与维护迁移事件
resource "google_monitoring_alert_policy" "rec_gce_host_maintenance" {
  count        = var.enable_default_alerts ? 1 : 0
  project      = var.project_id
  display_name = "Recommended - GCE Host Error & Maintenance Event"

  # teardown-gcloud.sh / configure.sh 的 remove_* 以此标签识别 Terraform 托管策略并跳过删除
  user_labels = {
    managed-by = "terraform"
  }
  severity = "WARNING"
  combiner = "OR"
  enabled  = true

  documentation {
    mime_type = "text/markdown"
    content   = "GCE 虚拟机发生宿主机硬件故障（hostError）、计划维护热迁移/终止（migrateOnHostMaintenance / terminateOnHostMaintenance）或异常重启（automaticRestart）。"
  }

  conditions {
    display_name = "GCE System Event (hostError / maintenance / automaticRestart)"
    condition_matched_log {
      filter = <<-EOT
        LOG_ID("cloudaudit.googleapis.com/system_event")
        AND resource.type="gce_instance"
        AND (protoPayload.methodName="compute.instances.hostError"
             OR protoPayload.methodName="compute.instances.migrateOnHostMaintenance"
             OR protoPayload.methodName="compute.instances.terminateOnHostMaintenance"
             OR protoPayload.methodName="compute.instances.automaticRestart")
      EOT
    }
  }

  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }
    auto_close = "86400s"
  }

  notification_channels = [google_monitoring_notification_channel.feishu.id]
  depends_on            = [google_project_service.required]
}

# 1d. GCE & GPU 计划维护提前预警
resource "google_monitoring_alert_policy" "rec_gce_upcoming_maintenance" {
  count        = var.enable_default_alerts ? 1 : 0
  project      = var.project_id
  display_name = "Recommended - GCE & GPU Upcoming Host Maintenance"

  # teardown-gcloud.sh / configure.sh 的 remove_* 以此标签识别 Terraform 托管策略并跳过删除
  user_labels = {
    managed-by = "terraform"
  }
  severity = "ERROR"
  combiner = "OR"
  enabled  = true

  documentation {
    mime_type = "text/markdown"
    content   = "检测到 GCE / GPU 实例（如 A3 / A4 / A4X / G2 等不支持热迁移的机型；注意 G2 / A2 等通用 GPU 机型维护终止会清空临时 Local SSD）排入计划宿主机维护窗口（compute.instances.upcomingMaintenance，通常提前 1 小时至 7–90 天通知）。建议及时持久化 Checkpoint，并在业务低峰期执行 gcloud compute instances perform-maintenance 或 gcloud compute reservations perform-maintenance 主动维护。"
  }

  conditions {
    display_name = "GCE Upcoming Maintenance Audit Log"
    condition_matched_log {
      filter = <<-EOT
        LOG_ID("cloudaudit.googleapis.com/system_event")
        AND resource.type="gce_instance"
        AND protoPayload.methodName="compute.instances.upcomingMaintenance"
        AND NOT protoPayload.status.message=~"completed"
      EOT
      label_extractors = {
        maintenance_status = "EXTRACT(protoPayload.status.message)"
      }
    }
  }

  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }
    auto_close = "86400s"
  }

  notification_channels = [google_monitoring_notification_channel.feishu.id]
  depends_on            = [google_project_service.required]
}

# 2. GCP 配额耗尽与超限预警
resource "google_monitoring_alert_policy" "rec_quota_exceeded" {
  count        = var.enable_default_alerts ? 1 : 0
  project      = var.project_id
  display_name = "Recommended - GCP Quota Exceeded & Allocation Warning"

  # teardown-gcloud.sh / configure.sh 的 remove_* 以此标签识别 Terraform 托管策略并跳过删除
  user_labels = {
    managed-by = "terraform"
  }
  severity = "ERROR"
  combiner = "OR"
  enabled  = true

  documentation {
    mime_type = "text/markdown"
    content   = "GCP 服务配额触发超限错误（serviceruntime.googleapis.com/quota/exceeded > 0）。如需按 80% 静态水位提前预警，可在控制台切换为 PromQL：`(serviceruntime_googleapis_com:quota_allocation_usage / serviceruntime_googleapis_com:quota_limit) > 0.8`"
  }

  conditions {
    display_name = "GCP Consumer Quota Exceeded > 0"
    condition_threshold {
      filter          = "resource.type = \"consumer_quota\" AND metric.type = \"serviceruntime.googleapis.com/quota/exceeded\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "60s"
      aggregations {
        # quota/exceeded 是 GAUGE / BOOL 指标（见 cloud.google.com/monitoring/api/metrics_gcp_p_z
        # #gcp-serviceruntime）：BOOL 不能用 ALIGN_SUM（API 直接 400），
        # 要用 ALIGN_COUNT_TRUE 把 true 的采样点计数后再与 0 比较。
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_COUNT_TRUE"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["metric.label.quota_metric", "metric.label.limit_name"]
      }
    }
  }

  alert_strategy {
    auto_close = "86400s"
  }

  notification_channels = [google_monitoring_notification_channel.feishu.id]
  depends_on            = [google_project_service.required]
}

# 3a. HTTP(S) 负载均衡 5xx 错误率升高
resource "google_monitoring_alert_policy" "rec_network_lb_5xx" {
  count        = var.enable_default_alerts ? 1 : 0
  project      = var.project_id
  display_name = "Recommended - HTTP Load Balancer 5xx Error Spike"

  # teardown-gcloud.sh / configure.sh 的 remove_* 以此标签识别 Terraform 托管策略并跳过删除
  user_labels = {
    managed-by = "terraform"
  }
  severity = "ERROR"
  combiner = "OR"
  enabled  = true

  documentation {
    mime_type = "text/markdown"
    content   = "Cloud HTTP(S) Load Balancer 返回 5xx 响应的速率持续 3 分钟超过 1 req/s。请检查后端服务健康状态及 statusDetails 日志。"
  }

  conditions {
    display_name = "HTTPS LB 5xx Request Rate > 1 req/s (3m)"
    condition_threshold {
      filter          = "resource.type = \"https_lb_rule\" AND metric.type = \"loadbalancing.googleapis.com/https/request_count\" AND metric.labels.response_code_class = \"500\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1.0
      duration        = "180s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  alert_strategy {
    auto_close = "86400s"
  }

  notification_channels = [google_monitoring_notification_channel.feishu.id]
  depends_on            = [google_project_service.required]
}

# 3b. Cloud NAT 端口耗尽与丢包告警
resource "google_monitoring_alert_policy" "rec_network_cloud_nat" {
  count        = var.enable_default_alerts ? 1 : 0
  project      = var.project_id
  display_name = "Recommended - Cloud NAT Port Exhaustion & Packet Drops"

  # teardown-gcloud.sh / configure.sh 的 remove_* 以此标签识别 Terraform 托管策略并跳过删除
  user_labels = {
    managed-by = "terraform"
  }
  severity = "ERROR"
  combiner = "OR"
  enabled  = true

  documentation {
    mime_type = "text/markdown"
    content   = "Cloud NAT 网关发生端口/IP 分配失败（nat_allocation_failed）或丢包（dropped_sent_packets_count / dropped_received_packets_count）。建议开启动态端口分配、调高最大端口数或增加 NAT IP。"
  }

  # 指标 kind/valueType 依据 cloud.google.com/monitoring/api/metrics_gcp_p_z#gcp-router：
  #   nat/nat_allocation_failed          GAUGE, BOOL   → 只能用 ALIGN_COUNT_TRUE / ALIGN_FRACTION_TRUE
  #   nat/dropped_sent_packets_count     DELTA, INT64  → ALIGN_RATE
  #   nat/dropped_received_packets_count DELTA, INT64  → ALIGN_RATE
  # 不存在 nat/dropped_packets_count；Monitoring 过滤器的 metric.type 也不支持 one_of()，
  # 因此丢包拆成两条 condition（combiner = OR）。
  conditions {
    display_name = "Cloud NAT Port Allocation Failed > 0"
    condition_threshold {
      filter          = "resource.type = \"nat_gateway\" AND metric.type = \"router.googleapis.com/nat/nat_allocation_failed\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "60s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_COUNT_TRUE"
      }
    }
  }

  conditions {
    display_name = "Cloud NAT Dropped Sent Packets > 0"
    condition_threshold {
      filter          = "resource.type = \"nat_gateway\" AND metric.type = \"router.googleapis.com/nat/dropped_sent_packets_count\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "60s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  conditions {
    display_name = "Cloud NAT Dropped Received Packets > 0"
    condition_threshold {
      filter          = "resource.type = \"nat_gateway\" AND metric.type = \"router.googleapis.com/nat/dropped_received_packets_count\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "60s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  alert_strategy {
    auto_close = "86400s"
  }

  notification_channels = [google_monitoring_notification_channel.feishu.id]
  depends_on            = [google_project_service.required]
}

# 4a. GKE 容器重启与内存 OOM 风险
resource "google_monitoring_alert_policy" "rec_gke_container_health" {
  count        = var.enable_default_alerts ? 1 : 0
  project      = var.project_id
  display_name = "Recommended - GKE Container Restart & Memory High"

  # teardown-gcloud.sh / configure.sh 的 remove_* 以此标签识别 Terraform 托管策略并跳过删除
  user_labels = {
    managed-by = "terraform"
  }
  severity = "WARNING"
  combiner = "OR"
  enabled  = true

  documentation {
    mime_type = "text/markdown"
    content   = "GKE 容器在 5 分钟内重启超过 3 次（CrashLoopBackOff / OOMKilled），或内存使用率超过 Limit 的 90%。"
  }

  conditions {
    display_name = "GKE Container Restart Count > 3 (5m)"
    condition_threshold {
      filter          = "resource.type = \"k8s_container\" AND metric.type = \"kubernetes.io/container/restart_count\""
      comparison      = "COMPARISON_GT"
      threshold_value = 3
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_DELTA"
      }
    }
  }

  conditions {
    display_name = "GKE Container Memory Limit Utilization > 90% (5m)"
    condition_threshold {
      filter          = "resource.type = \"k8s_container\" AND metric.type = \"kubernetes.io/container/memory/limit_utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.90
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  alert_strategy {
    auto_close = "86400s"
  }

  notification_channels = [google_monitoring_notification_channel.feishu.id]
  depends_on            = [google_project_service.required]
}

# 4b. Cloud SQL 实例 CPU / 内存 / 磁盘高水位
resource "google_monitoring_alert_policy" "rec_cloudsql_resource_high" {
  count        = var.enable_default_alerts ? 1 : 0
  project      = var.project_id
  display_name = "Recommended - Cloud SQL CPU / Memory / Disk High"

  # teardown-gcloud.sh / configure.sh 的 remove_* 以此标签识别 Terraform 托管策略并跳过删除
  user_labels = {
    managed-by = "terraform"
  }
  severity = "WARNING"
  combiner = "OR"
  enabled  = true

  documentation {
    mime_type = "text/markdown"
    content   = "Cloud SQL 数据库实例 CPU、内存或磁盘空间使用率连续 5 分钟超过 85%。"
  }

  conditions {
    display_name = "Cloud SQL CPU Utilization > 85% (5m)"
    condition_threshold {
      filter          = "resource.type = \"cloudsql_database\" AND metric.type = \"cloudsql.googleapis.com/database/cpu/utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.85
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  conditions {
    display_name = "Cloud SQL Memory Utilization > 85% (5m)"
    condition_threshold {
      filter          = "resource.type = \"cloudsql_database\" AND metric.type = \"cloudsql.googleapis.com/database/memory/utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.85
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  conditions {
    display_name = "Cloud SQL Disk Utilization > 85% (5m)"
    condition_threshold {
      filter          = "resource.type = \"cloudsql_database\" AND metric.type = \"cloudsql.googleapis.com/database/disk/utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.85
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  alert_strategy {
    auto_close = "86400s"
  }

  notification_channels = [google_monitoring_notification_channel.feishu.id]
  depends_on            = [google_project_service.required]
}

# 5a. 高危 IAM 权限变更审计告警
resource "google_monitoring_alert_policy" "rec_audit_high_risk_iam" {
  count        = var.enable_default_alerts ? 1 : 0
  project      = var.project_id
  display_name = "Recommended - High-Risk IAM Policy Change"

  # teardown-gcloud.sh / configure.sh 的 remove_* 以此标签识别 Terraform 托管策略并跳过删除
  user_labels = {
    managed-by = "terraform"
  }
  severity = "ERROR"
  combiner = "OR"
  enabled  = true

  documentation {
    mime_type = "text/markdown"
    content   = "检测到项目级高危 IAM 策略变更（授予 roles/owner、roles/editor、roles/iam.securityAdmin，或向 allUsers / allAuthenticatedUsers 开放权限）。"
  }

  conditions {
    display_name = "High-Risk SetIamPolicy Audit Log"
    condition_matched_log {
      filter = <<-EOT
        LOG_ID("cloudaudit.googleapis.com/activity")
        AND protoPayload.methodName="SetIamPolicy"
        AND (NOT protoPayload.status.code:* OR protoPayload.status.code=0)
        AND protoPayload.serviceData.policyDelta.bindingDeltas.action="ADD"
        AND (protoPayload.serviceData.policyDelta.bindingDeltas.role="roles/owner"
             OR protoPayload.serviceData.policyDelta.bindingDeltas.role="roles/editor"
             OR protoPayload.serviceData.policyDelta.bindingDeltas.role="roles/iam.securityAdmin"
             OR protoPayload.serviceData.policyDelta.bindingDeltas.member:"allUsers"
             OR protoPayload.serviceData.policyDelta.bindingDeltas.member:"allAuthenticatedUsers")
      EOT
      label_extractors = {
        principal_email = "EXTRACT(protoPayload.authenticationInfo.principalEmail)"
      }
    }
  }

  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }
    auto_close = "86400s"
  }

  notification_channels = [google_monitoring_notification_channel.feishu.id]
  depends_on            = [google_project_service.required]
}

# 5b. Service Account 密钥创建审计告警
resource "google_monitoring_alert_policy" "rec_audit_sa_key_created" {
  count        = var.enable_default_alerts ? 1 : 0
  project      = var.project_id
  display_name = "Recommended - Service Account Key Created"

  # teardown-gcloud.sh / configure.sh 的 remove_* 以此标签识别 Terraform 托管策略并跳过删除
  user_labels = {
    managed-by = "terraform"
  }
  severity = "ERROR"
  combiner = "OR"
  enabled  = true

  documentation {
    mime_type = "text/markdown"
    content   = "检测到创建了新的 Service Account 持久化密钥（CreateServiceAccountKey）。建议改用 Workload Identity Federation 或短效凭据。"
  }

  conditions {
    display_name = "CreateServiceAccountKey Audit Log"
    condition_matched_log {
      filter = <<-EOT
        LOG_ID("cloudaudit.googleapis.com/activity")
        AND protoPayload.methodName="google.iam.admin.v1.CreateServiceAccountKey"
        AND (NOT protoPayload.status.code:* OR protoPayload.status.code=0)
      EOT
      label_extractors = {
        principal_email = "EXTRACT(protoPayload.authenticationInfo.principalEmail)"
      }
    }
  }

  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }
    auto_close = "86400s"
  }

  notification_channels = [google_monitoring_notification_channel.feishu.id]
  depends_on            = [google_project_service.required]
}
