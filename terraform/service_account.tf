/**
 * 函数专用 Service Account（替代默认 compute SA）。
 *
 * 最小权限原则：项目级【不授任何角色】。函数日志只走 stdout（src/log_utils.py 的
 * StreamHandler），由 Cloud Run 基础设施采集，运行时 SA 不需要 roles/logging.logWriter
 * （此前多授的一条已删除，与 gcloud 路径同步）。secretAccessor 不在项目级授予，
 * 而是逐个 Secret 绑定（见 secrets.tf）—— 项目级 accessor 意味着这个 SA
 * 能读【项目里所有】的 Secret，一旦函数被攻破影响面远超本项目。
 * 它作为 Eventarc 触发器身份所需的 roles/run.invoker 见 function.tf（run_invoker_scope）。
 */

resource "google_service_account" "function" {
  account_id   = var.service_account_id
  display_name = "GCP Alerts to Feishu Function"
  description  = "Cloud Functions Gen2 运行身份：读取${local.channel_label}凭据 Secret；兼作 Eventarc 触发器身份"

  depends_on = [google_project_service.required]
}
