/**
 * Secret Manager —— 只读引用，不声明 resource。
 *
 * 所有权划分（规格说明书"Secret 所有权约定"）：
 *   Secret 资源与版本（密文） → 部署脚本 / gcloud（密文若由 Terraform 管理会明文落入 tfstate）
 *   Secret 的 accessor IAM   → Terraform（需要引用 Terraform 创建的 Functions SA）
 *
 * 若这里写成 resource，脚本先建过一次后 terraform apply 会以 409 already exists 失败。
 *
 * 多渠道：只引用 / 授权【本渠道】的 Secret（local.channel_secrets，见 channels.tf），
 * 键为函数环境变量名（如 "FEISHU_DEFAULT_WEBHOOK"）。切换渠道时旧渠道的 accessor 绑定会被
 * destroy（最小权限），旧渠道 Secret 本身仍由脚本拥有、不会被 Terraform 删除。
 */

data "google_secret_manager_secret" "channel" {
  for_each = local.channel_secrets

  project   = var.project_id
  secret_id = each.value

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_iam_member" "secret_accessor" {
  for_each = local.channel_secrets

  project   = var.project_id
  secret_id = data.google_secret_manager_secret.channel[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.function.email}"
}

# 存量飞书部署的 state 迁移：两条单例 accessor 改为 for_each 后地址变化，
# moved 块让已有 state 原地跟随（project / secret_id / role / member 四个属性与旧资源逐字相同，
# 资源 ID 不变 → plan 无 destroy / replace），用户无需手工 terraform state mv。
# notify_channel ≠ feishu 时这两个目标键不存在，Terraform 会把迁移后的实例按「已不在配置中」destroy
# —— 这正是切换渠道时应有的行为（撤销对旧渠道 Secret 的读取权限）。
moved {
  from = google_secret_manager_secret_iam_member.webhook_accessor
  to   = google_secret_manager_secret_iam_member.secret_accessor["FEISHU_DEFAULT_WEBHOOK"]
}

moved {
  from = google_secret_manager_secret_iam_member.sign_accessor
  to   = google_secret_manager_secret_iam_member.secret_accessor["FEISHU_DEFAULT_SECRET"]
}
