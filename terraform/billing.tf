/**
 * Billing 预算告警（可选，需 roles/billing.admin）。
 *
 * 四条阈值规则与 gcloud 路径保持一致：50% / 90% / 100% 实际支出 + 100% 预测支出。
 * 预测支出规则是最有价值的一条 —— 它在月中就能提示"按当前速率会超支"，
 * 而实际支出 100% 触发时钱已经花完了。
 */

resource "google_billing_budget" "feishu" {
  count = var.enable_billing ? 1 : 0

  billing_account = var.billing_account_id
  display_name    = "Feishu Alert Budget - ${var.project_id}"

  budget_filter {
    projects = ["projects/${data.google_project.this.number}"]
  }

  amount {
    specified_amount {
      currency_code = var.billing_currency
      units         = var.billing_amount
    }
  }

  threshold_rules {
    threshold_percent = 0.5
  }

  threshold_rules {
    threshold_percent = 0.9
  }

  threshold_rules {
    threshold_percent = 1.0
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    pubsub_topic   = google_pubsub_topic.main.id
    schema_version = "1.0"
  }

  depends_on = [
    google_project_service.required,
    google_pubsub_topic_iam_member.billing_publisher,
  ]

  lifecycle {
    precondition {
      condition     = !var.enable_billing || var.billing_account_id != ""
      error_message = "enable_billing = true 时必须提供 billing_account_id。"
    }
  }
}
