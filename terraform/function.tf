/**
 * Cloud Functions Gen2（512Mi / 60s / max_instances=2 / concurrency=1 / retry）。
 *
 * retry_policy = RETRY_POLICY_RETRY 对应 gcloud 的 --retry，不可省略：
 * Gen2 事件函数默认【不重试】，抛异常等于 ack 丢弃，死信策略也就永远不会触发。
 */

resource "google_storage_bucket" "source" {
  name                        = "${var.project_id}-gcf-source"
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  depends_on = [google_project_service.required]
}

# 以 src/ 为包根打包：与 tests/conftest.py 注入的 sys.path 完全一致，
# 保证"测试里能 import 的，运行时也能 import"（src layout 约定）。
data "archive_file" "source" {
  type        = "zip"
  source_dir  = "${path.module}/../src"
  output_path = "${path.module}/.terraform-tmp/function-source.zip"
  excludes    = ["__pycache__", "**/__pycache__"]
}

# 文件名带内容哈希：源码变了对象名就变，函数才会真正重新部署。
# 固定名 + 覆盖上传的写法会让 Terraform 认为函数无变化，改了代码却不生效。
resource "google_storage_bucket_object" "source" {
  name   = "function-source-${data.archive_file.source.output_md5}.zip"
  bucket = google_storage_bucket.source.name
  source = data.archive_file.source.output_path
}

# description：飞书保持原文案逐字不变（存量部署无 diff）；其它渠道按渠道名显示
resource "google_cloudfunctions2_function" "alerts" {
  name        = var.function_name
  project     = var.project_id
  location    = var.region
  description = var.notify_channel == "feishu" ? "GCP 告警统一转发到飞书/Lark 机器人" : "GCP 告警统一转发到${local.channel_label}机器人"

  build_config {
    runtime     = "python312"
    entry_point = "handle_pubsub"

    source {
      storage_source {
        bucket = google_storage_bucket.source.name
        object = google_storage_bucket_object.source.name
      }
    }
  }

  service_config {
    available_memory   = "512Mi"
    timeout_seconds    = 60
    max_instance_count = var.max_instances
    min_instance_count = 0
    # concurrency=1：令牌桶是进程内的，单实例并发处理会让出速率超出预期
    max_instance_request_concurrency = 1
    # 【不】显式设置 available_cpu：provider 把它标为 Optional+Computed，省略时由平台按内存推导
    # （512Mi → 0.333 vCPU），与 gcloud 路径（deploy-gcloud.sh 未传 --cpu）完全一致。
    # 此前这里写死 "1" 使两条路径实例规格与计费不同。若要调 CPU，两条路径必须同时改。

    service_account_email = google_service_account.function.email
    ingress_settings      = "ALLOW_INTERNAL_ONLY"

    # 环境变量是【全量管理】语义（与 gcloud --set-env-vars 一样是整体替换）：
    #   · 在控制台 / emergency-*.sh 里改的任何值，下一次 apply 都会按下面这份清单复位；
    #   · 急停要跨 apply 持久，必须改 var.kill_switch / var.pause_mode，不能只跑脚本；
    #   · Terraform 不能对 map 的单个 key 做 ignore_changes，不要试图这么做。
    #   · CONFIG_REVISION 只在 var.config_revision 非空时注入（scripts/configure.sh 每次应用写新值，
    #     强制拉新 revision 以重新解析 Secret :latest）；为空时 map 与旧版逐字一致，存量部署 plan 无变化。
    environment_variables = merge(
      {
        NOTIFY_CHANNEL       = var.notify_channel
        LOG_LEVEL            = var.log_level
        MIN_SEVERITY         = var.min_severity
        MAX_SENDS_PER_MINUTE = tostring(local.max_sends_per_minute)
        KILL_SWITCH          = tostring(var.kill_switch)
        PAUSE_MODE           = tostring(var.pause_mode)
        SELF_PROJECT_ID      = var.project_id
      },
      var.config_revision == "" ? {} : { CONFIG_REVISION = var.config_revision },
      length(var.source_min_severity) == 0 ? {} : {
        SOURCE_MIN_SEVERITY = join(";", [
          for k in ["monitoring", "service_health", "billing", "scc"] :
          "${k}=${upper(var.source_min_severity[k])}"
          if contains(keys(var.source_min_severity), k)
        ])
      },
      length(var.source_projects) == 0 ? {} : {
        HUB_SOURCE_PROJECTS = join(";", [
          for id in sort(var.source_projects) : "${id}=${data.google_project.source[id].number}"
        ])
      },
      var.source_scope == "" ? {} : { HUB_SCOPE = var.source_scope }
    )

    # 密文经 Secret Manager 注入为环境变量，绝不写进 tfstate 或 tfvars。
    # version = "latest" 只在【实例启动时】解析一次：换 webhook 时 deploy-terraform.sh 只追加
    # Secret 新版本，这里没有 diff、不会拉新 revision，老实例会继续用旧值直到缩容为 0 重建。
    # 要立即生效需强制新 revision（改任一 env 值 / 重新部署源码），两条路径同样 ——
    # scripts/configure.sh 通过更新 var.config_revision（env CONFIG_REVISION）做到这一点。
    #
    # 只挂载【本渠道】的 Secret（channels.tf 的 local.channel_secret_list，有序）：
    #   feishu   → FEISHU_DEFAULT_WEBHOOK、FEISHU_DEFAULT_SECRET（顺序与存量 state 一致，避免重排 diff）
    #   wecom    → WECOM_DEFAULT_WEBHOOK（企微无签名）
    #   dingtalk → DINGTALK_DEFAULT_WEBHOOK、DINGTALK_DEFAULT_SECRET
    dynamic "secret_environment_variables" {
      for_each = local.channel_secret_list
      content {
        key        = secret_environment_variables.value.env
        project_id = var.project_id
        secret     = data.google_secret_manager_secret.channel[secret_environment_variables.value.env].secret_id
        version    = "latest"
      }
    }
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = google_pubsub_topic.main.id
    service_account_email = google_service_account.function.email
    # 等价于 gcloud 的 --retry
    retry_policy = "RETRY_POLICY_RETRY"
  }

  lifecycle {
    precondition {
      # 机器人限流：飞书 100/min、企业微信 20/min（超限 45009）、钉钉 20/min（超限 130101 且封 10 分钟）；
      # 各留 20% 余量 → 上限 80 / 16 / 16（local.rate_cap）。实例数不是速率控制手段，
      # 但总出速率 = 单实例速率 × 实例数，配错会在告警风暴时批量限流丢消息。
      condition     = local.max_sends_per_minute * var.max_instances <= local.rate_cap
      error_message = "notify_channel = ${var.notify_channel}（${local.channel_label}）：max_sends_per_minute(${local.max_sends_per_minute}) × max_instances(${var.max_instances}) = ${local.max_sends_per_minute * var.max_instances}，必须 ≤ ${local.rate_cap}（${local.channel_label}机器人限流 ${local.platform_rate_limit}/min，预留 20% 余量）。上限：feishu 80 / wecom 16 / dingtalk 16；max_sends_per_minute 留空（null）则按渠道取默认 40 / 8 / 8。"
    }
  }

  depends_on = [
    google_project_service.required,
    google_secret_manager_secret_iam_member.secret_accessor,
  ]
}

# Pub/Sub 直连触发器【不需要】roles/eventarc.eventReceiver。
# 该角色是给其他事件提供方（如 Audit Log 触发器）用的；Pub/Sub 直连只要求触发器身份
# 在目标 Run 服务上有 run.invoker（见下）。此前这里授了一条【项目级】eventReceiver，
# 既属多余授权，也与 gcloud 路径不一致（gcloud 路径从未授过它，线上实测投递正常）。
#
# run.invoker 的授权层级由 var.run_invoker_scope 决定（两者互斥，count 只会有一个为 1）：
#   service（默认）：绑定在函数底层 Run 服务上，最小权限；但部署者需要 run.services.setIamPolicy
#                    （roles/run.admin 含；roles/editor / projectIamAdmin 不含），否则这里 403 硬失败。
#   project        ：绑定在项目级，与 gcloud 路径「优先检查项目级 run.invoker」的做法对齐，
#                    部署者只需项目级 setIamPolicy，代价是该 SA 能调用项目内所有 Run 服务。

resource "google_cloud_run_service_iam_member" "invoker" {
  count    = var.run_invoker_scope == "service" ? 1 : 0
  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.alerts.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.function.email}"
}

# 该资源从无 count 改为 count 后地址变为 invoker[0]；moved 块让已有 state 自动跟随，
# 用户无需手工 terraform state mv（run_invoker_scope 默认 service，count 为 1）。
moved {
  from = google_cloud_run_service_iam_member.invoker
  to   = google_cloud_run_service_iam_member.invoker[0]
}

resource "google_project_iam_member" "invoker_project" {
  count   = var.run_invoker_scope == "project" ? 1 : 0
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.function.email}"
}
