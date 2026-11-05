/**
 * Pub/Sub：主题 + DLQ 主题/订阅 + 死信策略 + 各数据源服务代理的 publisher 授权。
 *
 * "静默无告警"的三大根因都在这个文件里被处理：
 *   1. 某个数据源的服务代理没有 publisher 权限 → 消息投不进来，且没有任何报错；
 *   2. DLQ 没有订阅 → 死信被直接丢弃，replay-dlq.sh 无消息可读；
 *   3. Pub/Sub 服务代理不能写 DLQ / 不能 ack 源订阅 → 死信转发静默失败。
 */

locals {
  project_number = data.google_project.this.number

  # 各数据源使用【不同】的服务代理投递，缺一个授权就少一类告警
  monitoring_sa = "service-${local.project_number}@gcp-sa-monitoring-notification.iam.gserviceaccount.com"
  pubsub_sa     = "service-${local.project_number}@gcp-sa-pubsub.iam.gserviceaccount.com"
  scc_sa        = "service-org-${var.scc_organization_id}@gcp-sa-scc-notification.iam.gserviceaccount.com"
  # 【待确认】Budget 服务代理成员名未在真实 topic 上核实（公开资料也有写
  # billing-budget-alert@system.gserviceaccount.com 的）。Budget API 文档称：设置 pubsubTopic 时
  # 调用者需有 pubsub.topics.setIamPolicy，由 API 自行给其服务代理授 publisher —— 本绑定可能多余；
  # 若成员名无效，enable_billing = true 时 apply 会 400。核实方法：在一个已连通预算的 topic 上
  # `gcloud pubsub topics get-iam-policy`。与 deploy-gcloud.sh 用的是同一个名字，两边要一起改。
  billing_sa = "billing-budgets-pubsub@system.gserviceaccount.com"
}

resource "google_pubsub_topic" "main" {
  name    = var.topic_name
  project = var.project_id

  labels = {
    managed-by = "terraform"
    component  = "alert-hub"
  }

  depends_on = [google_project_service.required]
}

resource "google_pubsub_topic" "dlq" {
  name    = var.dlq_topic_name
  project = var.project_id

  labels = {
    managed-by = "terraform"
    component  = "alert-hub-dlq"
  }

  depends_on = [google_project_service.required]
}

# DLQ 订阅必须显式创建：没有订阅的 DLQ topic 会把死信直接丢弃。
resource "google_pubsub_subscription" "dlq" {
  name    = var.dlq_subscription_name
  project = var.project_id
  topic   = google_pubsub_topic.dlq.id

  message_retention_duration = "604800s" # 7 天，与 gcloud 路径一致
  retain_acked_messages      = false
  ack_deadline_seconds       = 60

  # 空 ttl = 永不过期。默认 31 天无活动即删除订阅，而 DLQ 恰恰是长期没有活动的，
  # 真出事时会发现订阅已被自动清掉。
  expiration_policy {
    ttl = ""
  }
}

# --- 各数据源服务代理的 publisher 授权 -------------------------------------

resource "google_pubsub_topic_iam_member" "monitoring_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.main.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${local.monitoring_sa}"
}

resource "google_pubsub_topic_iam_member" "scc_publisher" {
  count = var.enable_scc ? 1 : 0

  project = var.project_id
  topic   = google_pubsub_topic.main.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${local.scc_sa}"
}

resource "google_pubsub_topic_iam_member" "billing_publisher" {
  count = var.enable_billing ? 1 : 0

  project = var.project_id
  topic   = google_pubsub_topic.main.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${local.billing_sa}"
}

# Pub/Sub 服务代理需要能写 DLQ，否则死信转发静默失败（消息只会被反复重试直到过期）
resource "google_pubsub_topic_iam_member" "dlq_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.dlq.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${local.pubsub_sa}"
}

# --- 死信策略挂载 -----------------------------------------------------------
//
// Eventarc 为 Gen2 函数创建的是【托管订阅】（名字形如
// eventarc-<region>-<function>-sub-<hash>，且带 hash），google provider 既不能创建
// 也不能直接管理它，因此无法用 google_pubsub_subscription 声明其 dead_letter_policy。
//
// 可选方案与取舍：
//   a) 放弃 event_trigger，自建 push 订阅指向 Cloud Run URL —— 需要改函数的入参格式，
//      并自行处理 OIDC 鉴权，偏离 functions-framework 的 CloudEvent 契约；
//   b) 不挂死信策略 —— 失败消息会重试到过期后丢失，直接违反"无消息丢失"验收项；
//   c) 用 local-exec 调用与 gcloud 路径完全相同的命令挂载。
// 选 c：范围仅限一条订阅属性，且保证两条部署路径功能对等。
resource "terraform_data" "dead_letter_policy" {
  # 函数重新部署可能重建触发器订阅；触发器重建时 Eventarc 会换一个带随机后缀的新名字，
  # 因此用触发器全名作为触发条件：触发器（及其订阅）变了才重新挂载死信策略。
  #
  # 【不要】用 update_time：函数原地更新时 provider 在 plan 阶段给出旧值、apply 后变成新值，
  # Terraform 报 "Provider produced inconsistent final plan" 并让整次 apply 以失败告终
  # （2026-10-20 Argolis 实测：策略与函数都已更新，但 deploy-terraform.sh 退出 1）。
  triggers_replace = [
    google_cloudfunctions2_function.alerts.id,
    google_cloudfunctions2_function.alerts.event_trigger[0].trigger,
    var.dlq_max_delivery_attempts,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      # 触发器名【不等于】函数名：Eventarc 会加随机后缀（实测 gcp-alerts-to-feishu-898788）。
      # 早先这里直接用 var.function_name 去 describe，结果是稳定的 NOT_FOUND ——
      # local-exec 以 exit 1 中断，整个 apply 失败并留下半成品 state。
      #
      # 正确来源是函数资源自己导出的 event_trigger[0].trigger（完整资源路径），
      # 取末段即为触发器短名。这比再调一次 gcloud 去查更可靠，也少一次 API 往返。
      TRIGGER="${google_cloudfunctions2_function.alerts.event_trigger[0].trigger}"
      TRIGGER="$${TRIGGER##*/}"
      if [[ -z "$${TRIGGER}" ]]; then
        echo "未能从函数资源取出 Eventarc 触发器名，死信策略未挂载" >&2
        exit 1
      fi
      SUB=$(gcloud eventarc triggers describe "$${TRIGGER}" \
        --project="${var.project_id}" --location="${var.region}" \
        --format="value(transport.pubsub.subscription)")
      SUB="$${SUB##*/}"
      if [[ -z "$${SUB}" ]]; then
        echo "未能查出 Eventarc 托管订阅名，死信策略未挂载" >&2
        exit 1
      fi
      gcloud pubsub subscriptions update "$${SUB}" \
        --project="${var.project_id}" \
        --dead-letter-topic="${google_pubsub_topic.dlq.name}" \
        --max-delivery-attempts=${var.dlq_max_delivery_attempts} \
        --min-retry-delay=${local.min_retry_delay} \
        --max-retry-delay=600s
      # Pub/Sub 服务代理还需要能 ack 源订阅，否则转发死信后无法确认，消息会重复
      gcloud pubsub subscriptions add-iam-policy-binding "$${SUB}" \
        --project="${var.project_id}" \
        --member="serviceAccount:${local.pubsub_sa}" \
        --role="roles/pubsub.subscriber" >/dev/null
      echo "死信策略已挂载到 $${SUB}"
    EOT
  }

  depends_on = [
    google_pubsub_topic_iam_member.dlq_publisher,
    google_pubsub_subscription.dlq,
  ]
}
