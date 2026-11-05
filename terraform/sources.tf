locals {
  # 唯一真相源：templates/hub-sink-filter.txt（lib/common.sh 的 HUB_SINK_FILTER 读同一文件）
  hub_sink_filter = trimspace(file("${path.module}/../templates/hub-sink-filter.txt"))
}

# S1: Enable APIs on source projects
resource "google_project_service" "source_apis" {
  for_each           = toset(var.source_projects)
  project            = each.key
  service            = "monitoring.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "source_logging" {
  for_each           = toset(var.source_projects)
  project            = each.key
  service            = "logging.googleapis.com"
  disable_on_destroy = false
}

# 源项目的 Monitoring 往 Hub topic 发 Pub/Sub 通知时，要求源项目自身也启用 Pub/Sub API
# （未启用时 notification_channel_events 报 PERMISSION_DENIED，即使 topic IAM 正确；2026-10-26 Argolis A/B 实测）
resource "google_project_service" "source_pubsub" {
  for_each           = toset(var.source_projects)
  project            = each.key
  service            = "pubsub.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "source_servicehealth" {
  for_each           = toset(var.source_projects)
  project            = each.key
  service            = "servicehealth.googleapis.com"
  disable_on_destroy = false
}

# S2: Monitoring Service Agent
resource "google_project_service_identity" "source_monitoring_sa" {
  provider = google-beta
  for_each = toset(var.source_projects)
  project  = each.key
  service  = "monitoring.googleapis.com"

  depends_on = [google_project_service.source_apis]
}

# S3: Notification Channel on source projects
resource "google_monitoring_notification_channel" "source_hub_channel" {
  for_each     = toset(var.source_projects)
  project      = each.key
  display_name = "GCP Alerts Hub → ${var.project_id}"
  type         = "pubsub"
  # 移除源项目时客户策略（⑧ b 绑定）仍引用本渠道 → 不 force 会 400 "still being referenced"；
  # force 删除会顺带把本渠道从客户策略里摘掉（策略保留、仍启用；与 gcloud 路径 channels delete --force 对等，2026-10-26 实测）
  force_delete = true

  labels = {
    topic = "projects/${var.project_id}/topics/${google_pubsub_topic.main.name}"
  }

  user_labels = {
    gcp-alerts-hub = var.project_id
    managed-by     = "terraform"
  }

  depends_on = [google_project_service.source_apis, google_project_service.source_pubsub]
}

# S4: Topic IAM
resource "google_pubsub_topic_iam_member" "source_hub_publisher" {
  for_each = toset(var.source_projects)
  project  = var.project_id
  topic    = google_pubsub_topic.main.name
  role     = "roles/pubsub.publisher"
  member   = "serviceAccount:${google_project_service_identity.source_monitoring_sa[each.key].email}"
}

# S5: Log sink (only if HUB_SCOPE is empty)
# 只给「不在汇聚范围内」的源项目建项目级 sink：范围内的由聚合 sink 覆盖（避免重复），
# 范围外的若也删掉，其日志会静默断流（2026-10-26 实测 plan 发现）。范围归属由部署脚本按祖先链算出写入 tfvars
resource "google_logging_project_sink" "source_hub_sink" {
  for_each = toset([for p in var.source_projects : p if !contains(var.source_projects_in_scope, p)])
  project  = each.key
  name     = substr("gcp-alerts-hub-to-${var.project_id}", 0, 100)

  destination = "logging.googleapis.com/projects/${var.project_id}"
  filter      = local.hub_sink_filter

  unique_writer_identity = true

  depends_on = [google_project_service.source_logging]
}

# S6: Writer IAM for S5
resource "google_project_iam_member" "source_hub_sink_writer" {
  for_each = toset([for p in var.source_projects : p if !contains(var.source_projects_in_scope, p)])
  project  = var.project_id
  role     = "roles/logging.logWriter"
  member   = google_logging_project_sink.source_hub_sink[each.key].writer_identity
}

# S7: Metrics Scope
resource "google_monitoring_monitored_project" "source_metrics_scope" {
  for_each      = toset(var.source_projects)
  metrics_scope = var.project_id
  name          = each.key
}

# G0: Hub 侧回灌。路由进 Hub 的源项目审计日志（activity / system_event）会被 Hub 的 _Default sink
# 按 LOG_ID 排除、_Required 也只收本项目审计日志 → 直接丢弃，Hub 的日志型告警永远看不到。
# 日志型告警只评估 _Default 桶里的日志（写进用户自建桶也不触发；2026-10-26 Argolis 三组对照实测），
# 所以在 Hub 建一个 sink 把「非本项目」的审计日志写回 _Default 桶。
resource "google_logging_project_sink" "hub_routed_audit" {
  count       = (length(var.source_projects) > 0 || var.source_scope != "") ? 1 : 0
  project     = var.project_id
  name        = "gcp-alerts-hub-routed-audit"
  destination = "logging.googleapis.com/projects/${var.project_id}/locations/global/buckets/_Default"
  filter      = "(LOG_ID(\"cloudaudit.googleapis.com/activity\") OR LOG_ID(\"cloudaudit.googleapis.com/system_event\")) AND NOT logName:\"projects/${var.project_id}/\""

  unique_writer_identity = true
}

# G1/G2: Aggregated sink if HUB_SCOPE is set
resource "google_logging_folder_sink" "hub_folder_sink" {
  count            = can(regex("^folders/", var.source_scope)) ? 1 : 0
  folder           = split("/", var.source_scope)[1]
  name             = substr("gcp-alerts-hub-to-${var.project_id}", 0, 100)
  destination      = "logging.googleapis.com/projects/${var.project_id}"
  filter           = local.hub_sink_filter
  include_children = true
}

resource "google_project_iam_member" "hub_folder_sink_writer" {
  count   = can(regex("^folders/", var.source_scope)) ? 1 : 0
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = google_logging_folder_sink.hub_folder_sink[0].writer_identity
}

resource "google_logging_organization_sink" "hub_org_sink" {
  count            = can(regex("^organizations/", var.source_scope)) ? 1 : 0
  org_id           = split("/", var.source_scope)[1]
  name             = substr("gcp-alerts-hub-to-${var.project_id}", 0, 100)
  destination      = "logging.googleapis.com/projects/${var.project_id}"
  filter           = local.hub_sink_filter
  include_children = true
}

resource "google_project_iam_member" "hub_org_sink_writer" {
  count   = can(regex("^organizations/", var.source_scope)) ? 1 : 0
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = google_logging_organization_sink.hub_org_sink[0].writer_identity
}

# Data source to fetch project numbers
data "google_project" "source" {
  for_each   = toset(var.source_projects)
  project_id = each.key
}
