# gcloud vs Terraform：怎么选

**两条路径功能对等。** 同样的 topic、同样的 DLQ、同样的函数配置、同样的四个数据源、
同样的最小权限模型。差异只在**生命周期管理**。


一句话结论：**一次性验证选 gcloud；需要长期维护、多人协作、可审计变更的选 Terraform。**

### 对等开关 / 身份对照

| 项 | gcloud 路径 | Terraform 路径 | 备注 |
|---|---|---|---|
| 触发器身份（Eventarc → Run） | `--trigger-service-account="${FN_SA}"`（函数 SA） | `event_trigger.service_account_email = 函数 SA` | 两边一致后，`run.invoker` 才授给了真正的调用主体 |
| `run.invoker` 授权层级 | 先查项目级，缺则服务级（`soft_step` 降级） | `run_invoker_scope`：`service`（默认）/ `project` | `service` 需部署者有 `run.services.setIamPolicy`（`roles/run.admin`）；无此权限时设 `project` |
| 自监控（监控的监控） | `OPS_EMAIL` 环境变量 / 交互输入；留空跳过 | `ops_email` 变量；留空 `count = 0` | 邮件渠道 displayName 两边同为 `GCP Alerts Hub Ops Email`；策略 `GCP Alerts Hub - Permanent Send Failure` / `GCP Alerts Hub - DLQ Backlog` |
| 急停 / 暂停 | `emergency-disable.sh` / `emergency-enable.sh` 改底层 Run 服务 | `kill_switch` / `pause_mode` 变量注入 env；`deploy-terraform.sh` 每次按 `KILL_SWITCH` / `PAUSE_MODE` 重写 | 两条路径的下一次 deploy / apply 都会把开关**复位**为 false（未显式提供时；线上为 true 时打印 WARNING）—— 这是「重跑不回退」的唯一例外。要持久：两边都用 `KILL_SWITCH=true ./deploy-*.sh` 或 `configure.sh --section=switches`；只改 tfvars 仅对直接 `terraform apply` 有效 |
| 函数 CPU | 按内存推导 | 按内存推导（不设 `available_cpu`） | 要改必须两边同改 |
| Billing 服务代理成员名 | `billing-budgets-pubsub@system.gserviceaccount.com` | 同左（`pubsub.tf` `local.billing_sa`） | **已验证**：Budget API 在调用者具备 `pubsub.topics.setIamPolicy` 时会自动向其服务代理授予 publisher；gcloud 路径保留 `soft_step` 优雅兼容组织域限制 |
| **通知渠道** | `NOTIFY_CHANNEL`（`feishu` 默认 / `wecom` / `dingtalk`）；交互菜单 1) 飞书/Lark 2) 企业微信 3) 钉钉 | `notify_channel` 变量（同三值，validation 拦截其它值） | 单平台三选一，default/security/billing 三个路由组同走一个平台。两边都注入函数 env `NOTIFY_CHANNEL`；**默认 feishu 时存量部署行为不变** |
| **渠道凭据输入** | feishu：`FEISHU_WEBHOOK` + `FEISHU_SECRET`；wecom：`WECOM_WEBHOOK`；dingtalk：`DINGTALK_WEBHOOK` + `DINGTALK_SECRET` | 同一脚本收集后写入 Secret，tfvars 只记 `notify_channel` 与 Secret **名称** | 企微无签名；钉钉/飞书未开签名时 SECRET 必须显式填 `NONE`（空串会被拒） |
| **渠道 Secret** | 只创建所选渠道的：`feishu-default-webhook` + `feishu-default-secret` / `wecom-default-webhook` / `dingtalk-default-webhook` + `dingtalk-default-secret` | 同名（`feishu_default_webhook_secret`、`feishu_default_sign_secret`、`wecom_default_webhook_secret`、`dingtalk_default_webhook_secret`、`dingtalk_default_sign_secret`），只 `data` 引用本渠道的 | Secret 一律由脚本创建（密文不进 tfstate）；env 映射 `<channel>-default-webhook` → `<CHANNEL>_DEFAULT_WEBHOOK`，`<channel>-default-secret` → `<CHANNEL>_DEFAULT_SECRET` |
| **`secretAccessor`** | 对所选渠道的每个 Secret 逐个授（secret 级） | `google_secret_manager_secret_iam_member.secret_accessor`，`for_each = local.channel_secrets`（键 = env 名，如 `"FEISHU_DEFAULT_WEBHOOK"`） | 切换渠道时 Terraform 会 destroy 旧渠道的 accessor 绑定（最小权限）；旧 Secret 本身仍需手工 / teardown 删除 |
| **速率默认与上限** | `MAX_SENDS_PER_MINUTE` 未设时按渠道：feishu 40 / wecom 8 / dingtalk 8；脚本校验 速率 × max_instances ≤ 上限 | `max_sends_per_minute` 默认 `null` → `local.max_sends_per_minute` 按渠道推导同值；`precondition` 用 `local.rate_cap` | 上限 = 平台限流 × 80%：feishu 80（100/min）/ wecom 16（20/min）/ dingtalk 16（20/min，超限封 10 分钟）。默认 2 实例下 8 × 2 = 16 |
| **卸载 Secret** | `teardown-gcloud.sh` 按精确名删除三套渠道 Secret（存在才删） | `next_steps` 输出按本渠道生成删除命令，并列出其它渠道 Secret 的「存在才删」命令 | `terraform destroy` 不删 Secret（所有权在脚本） |
| **多项目汇聚（Hub 模式）** | 通过 `configure.sh` ⑧ 号菜单交互式添加/移除源项目或设置范围；按项目/范围自动调配 API、Sink 和 IAM，支持绑定客户已有策略 | 通过 `source_projects`（源项目列表）与 `source_scope`（文件夹/组织节点）自动调配资源；客户已有策略不受 TF 托管，需通过 ⑧ 绑定 | 两条路径完全对等。范围内的项目使用聚合 sink，范围外的使用逐项目 sink；部署皆会自动在 Hub 项目侧建立 `gcp-alerts-hub-routed-audit` 回灌 sink |
| **修改配置（`scripts/configure.sh`）** | 调用 `deploy-gcloud.sh --yes`；「开 → 关」的资源由 configure 在部署后按精确 displayName / 资源名删除（带 `managed-by=terraform` 标签的跳过） | 调用 `deploy-terraform.sh --yes`；关闭由 tfvars 的 `enable_*` / `ops_email` 控制、`apply` 删除；交互模式下 plan 后需再次输入 `yes` | 按 topic 的 `managed-by=terraform` 标签自动识别模式；两边同一套分区 / 差异预览 / 退出码（0 / 2 / 1）；不直接改 Run 服务 |
| **重跑部署不回退配置** | 函数已存在时，未显式提供的 `NOTIFY_CHANNEL` / `MIN_SEVERITY` / `SOURCE_MIN_SEVERITY` / `LOG_LEVEL` / `MAX_SENDS_PER_MINUTE`（同渠道）/ `MAX_INSTANCES` / `CONFIG_REVISION` 与 `ENABLE_PSH` / `ENABLE_DEFAULT_ALERTS` / `ENABLE_SCC` / `ENABLE_BILLING` / `BUDGET_AMOUNT` / `OPS_EMAIL` 沿用线上 | 同左，取值写入重新生成的 tfvars | 两边都打印「沿用线上配置：…」；首次部署行为不变。现状读不到时：gcloud **保持不动**（不建不删）；Terraform 先用本机 tfvars 兜底，仍未知则 `--yes` 报错、交互询问（避免 apply 误删） |
| **`CONFIG_REVISION`** | 环境变量，仅在设置时注入函数 env | `config_revision` 变量（默认 `""`，校验 `^[A-Za-z0-9._:-]{1,64}$`），非空时注入 env | configure 每次应用写入 UTC 时间戳以强制拉新 revision；为空时 TF env map 与旧版逐字一致，存量 plan 0 变更 |
| **`KEEP_EXISTING_SECRETS=true`** | 沿用本渠道现有 Secret，不输入、不追加版本 | 同左 | 两边都校验本渠道 Secret 存在且有启用版本，否则报错退出 |
| **`TF_APPLY_CONFIRM`** | — | `auto`（默认）\| `interactive`：`--yes` 下 plan 后仍要求输入 yes，取消退出码 3 | gcloud 路径没有 plan 环节，无对应项 |
| **`BILLING_ACCOUNT_ID`** | — （读不到结算账号仍是登记跳过，只 upsert 不删） | 结算账号来源 `BILLING_ACCOUNT_ID` > gcloud 读取 > 本机 tfvars 原值；仍拿不到且预算沿用线上 / 线上存在或未知时**中止** | 不对称是有意的：Terraform 写 `enable_billing=false` 会删预算，gcloud 路径不会 |


---

## 对照表

| 维度 | gcloud（`deploy-gcloud.sh`） | Terraform（`deploy-terraform.sh`） |
|-----|------------------------------|-----------------------------------|
| 首次部署耗时 | ~10 分钟 | ~15 分钟（多出 state bucket + provider 下载） |
| 前置依赖 | `gcloud`、`zip`、`envsubst` | 以上 + `terraform` ≥ 1.5 |
| 状态追踪 | 无 | GCS backend，带版本控制 + UBLA + 公开访问阻止 |
| 配置漂移检测 | ❌ 无法检测（有人在控制台改了没人知道） | ✅ `terraform plan` 直接列出 |
| 变更预览 | ❌ 部署脚本执行即生效（`configure.sh` 提供配置级「当前值 → 新值」预览与 `--dry-run`） | ✅ 先看变更集再决定是否 apply（`configure.sh` 交互模式下 plan 后需再次输入 yes） |
| 团队协作 | ❌ 靠口头约定谁跑过脚本 | ✅ state 锁 + 代码评审 |
| 回滚 | 手工反向操作 | `git revert` + apply |
| 卸载 | `scripts/teardown-gcloud.sh` | `scripts/teardown-terraform.sh`（执行 `terraform destroy` 并回收 Secret）或 `terraform destroy` |
| 幂等性 | ✅ 每一处 create 都先探测（见下） | ✅ 天然幂等 |
| 密文位置 | Secret Manager | Secret Manager（**不进 tfstate**） |
| 学习成本 | 低，脚本可逐行读懂 | 中，需要理解 state 与 provider |

---

## 幂等性：两条路径怎么保证

DoD 要求"连跑两次结果一致"。Terraform 天然满足；gcloud 路径需要逐个处理，
因为 GCP 有一批 `create` 命令是**不幂等**的（重复运行会产生重复资源）：

| 资源 | 不幂等的后果 | 脚本的处理 |
|-----|-------------|-----------|
| Secret | `create \|\| true` 会静默沿用旧值 | `upsert_secret`：存在则**追加新版本** |
| Notification Channel | 每跑一次多一个同名渠道 | 按 `displayName` 查，存在则复用 |
| 告警策略 | 每跑一次多一条同名策略，告警发双份 | 按 `displayName` 查，存在则 `update` |
| SCC 导出配置 | 409 冲突导致脚本中断 | `describe` 探测，存在则 `update` |
| **Billing 预算** | **每跑一次多一个同名预算，超支时推两条消息** | 按 `displayName` 查，存在则 `update` |
| Pub/Sub topic / 订阅 | 409 冲突 | `describe` 探测后决定 create |
| Service Account | 409 冲突 | `describe` 探测后决定 create |

> Billing 预算这条最隐蔽：重复的预算不会报错，只会在某天超支时让群里出现两张一模一样的卡片。

---

## 密钥所有权：两条路径共同的约定

| 对象 | 所有者 | 原因 |
|-----|--------|------|
| Secret 资源与版本（**密文**） | 部署脚本 / gcloud | 密文若由 Terraform 管理会**明文落入 tfstate** |
| Secret 的 accessor IAM 绑定 | Terraform | 需要引用 Terraform 创建的 Functions SA |

因此 `terraform/secrets.tf` 里只有 `data` 源和 `google_secret_manager_secret_iam_member`，
没有任何 `google_secret_manager_secret` 资源。多渠道后两者都改为 `for_each = local.channel_secrets`
（`terraform/channels.tf`），只引用 / 授权**本渠道**的 Secret：所选渠道的 Secret 不存在时
`data` 源会在 plan 阶段直接报错，而不是部署出一个读不到凭据的函数。

如果把它写成 `resource`，脚本先用 gcloud 建过一次之后，
`terraform apply` 会以 `409 already exists` 失败 —— 这是最容易踩的一个坑。

`terraform.tfvars` 里也只有 Secret 的**名称**，没有值。

---

## 存量 Terraform 部署升级到多渠道版本（`moved` 块）

多渠道版本把两条单例 accessor 改成了 `for_each`，资源地址随之变化。`terraform/secrets.tf`
用两个 `moved` 块让已有 state 原地跟随，**无需手工 `terraform state mv`**：

| 旧地址（main） | 新地址 |
|---|---|
| `google_secret_manager_secret_iam_member.webhook_accessor` | `google_secret_manager_secret_iam_member.secret_accessor["FEISHU_DEFAULT_WEBHOOK"]` |
| `google_secret_manager_secret_iam_member.sign_accessor` | `google_secret_manager_secret_iam_member.secret_accessor["FEISHU_DEFAULT_SECRET"]` |

新旧资源的 `project` / `secret_id` / `role` / `member` 四个属性逐字相同，资源 ID 不变。
存量飞书部署（`notify_channel` 未设置 = `feishu`）升级后的 `terraform plan` 预期：

- 两条 `# ... has moved to ...secret_accessor["..."]`，IAM 绑定**无** destroy / replace；
- 函数 in-place 更新：新增 env `NOTIFY_CHANNEL = "feishu"` + 新源码包；`MAX_SENDS_PER_MINUTE` 仍为 `"40"`；
  `secret_environment_variables` 仍是 WEBHOOK 在前、SECRET 在后（与存量 state 同序，不产生重排 diff）；
- 告警策略文档、通知渠道 / SA / SCC 描述等文案按渠道名插值，飞书渲染结果与旧版逐字一致 → 无 diff。

已用手工构造的旧地址 state + 真实 google provider 做 `plan -refresh=false` 验证：
feishu 为 `Plan: 0 to add, 0 to change, 0 to destroy`（仅两条 moved）；
切到 wecom 为 1 add / 2 destroy，切到 dingtalk 为 2 add / 2 destroy（撤销飞书 Secret 的读取权限）。

> [!WARNING]
> 若 tfvars 里**显式**写了 `max_sends_per_minute = 40` 又把 `notify_channel` 改成 `wecom` / `dingtalk`，
> `precondition` 会以 40 × 2 = 80 > 16 让 plan 失败（不会静默部署）。删掉该行即按渠道取默认 8。

---

## Terraform 路径里唯一的 `local-exec`

`terraform/pubsub.tf` 用 `terraform_data` + `local-exec` 给 Eventarc 托管订阅挂死信策略。

原因：Gen2 函数的事件触发器由 Eventarc 创建一个**托管订阅**
（名字形如 `eventarc-asia-east1-gcp-alerts-to-feishu-sub-<hash>`，带随机 hash），
google provider 既不能创建也不能声明式管理它，因此无法用
`google_pubsub_subscription` 声明它的 `dead_letter_policy`。

考虑过的三个方案：

| 方案 | 问题 |
|-----|------|
| 放弃 `event_trigger`，自建 push 订阅指向 Cloud Run URL | 需改函数入参格式并自行处理 OIDC 鉴权，偏离 functions-framework 的 CloudEvent 契约 |
| 干脆不挂死信策略 | 失败消息重试到过期后丢失，直接违反"无消息丢失"验收项 |
| **`local-exec` 调用与 gcloud 路径完全相同的命令** | 引入一处命令式操作，但范围仅限一条订阅属性 |

选第三个。它的触发条件绑定在函数的 `update_time` 上 ——
函数每次重新部署都可能重建触发器订阅，因此每次变更后都会重新挂载一遍。

---

## 从 gcloud 迁移到 Terraform

两条路径使用**相同的资源名**，因此可以把 gcloud 创建的资源 import 进 Terraform，
而不是先删后建（后者会丢掉 DLQ 中尚未重放的消息）。

```bash
# 1. 先跑一次 Terraform 路径的前半段，生成 backend.tf 与 tfvars
#    --project 必须与当初 gcloud 路径部署的目标项目一致，否则 import 会全部找不到资源
./deploy-terraform.sh --project=YOUR_PROJECT_ID --region=asia-east1
#    在 terraform apply 的确认处输入 NO 中止

cd terraform
PROJECT_ID=YOUR_PROJECT_ID

# 2. 逐个 import（资源名两条路径一致）
terraform import google_pubsub_topic.main "projects/${PROJECT_ID}/topics/gcp-alerts-hub"
terraform import google_pubsub_topic.dlq  "projects/${PROJECT_ID}/topics/gcp-alerts-dlq"
terraform import google_pubsub_subscription.dlq \
  "projects/${PROJECT_ID}/subscriptions/gcp-alerts-dlq-sub"
terraform import google_service_account.function \
  "projects/${PROJECT_ID}/serviceAccounts/gcp-alerts-fn@${PROJECT_ID}.iam.gserviceaccount.com"
terraform import google_cloudfunctions2_function.alerts \
  "projects/${PROJECT_ID}/locations/asia-east1/functions/gcp-alerts-to-feishu"
terraform import google_storage_bucket.source "${PROJECT_ID}-gcf-source"

# Notification Channel 与告警策略的 ID 需要先查出来（displayName 用 = 精确匹配，: 是 contains）
policy_id() { gcloud beta monitoring policies list --project="${PROJECT_ID}" \
  --filter="displayName=\"$1\"" --format='value(name)'; }
channel_id() { gcloud beta monitoring channels list --project="${PROJECT_ID}" \
  --filter="displayName=\"$1\"" --format='value(name)'; }

terraform import google_monitoring_notification_channel.feishu "$(channel_id 'Feishu Alert Hub')"

# PSH 两条策略（enable_psh 默认 true；漏掉会在 apply 时建同名重复策略 → 同一事件发两张卡）
terraform import 'google_monitoring_alert_policy.service_health[0]' \
  "$(policy_id 'GCP Service Health Incident')"
terraform import 'google_monitoring_alert_policy.service_health_emerging[0]' \
  "$(policy_id 'GCP Service Health Emerging Incident')"

# 自监控（仅当 gcloud 路径部署时填了 OPS_EMAIL，且 tfvars 里 ops_email 非空）
terraform import 'google_monitoring_notification_channel.ops_email[0]' \
  "$(channel_id 'GCP Alerts Hub Ops Email')"
terraform import 'google_monitoring_alert_policy.self_permanent_send_failure[0]' \
  "$(policy_id 'GCP Alerts Hub - Permanent Send Failure')"
terraform import 'google_monitoring_alert_policy.self_dlq_backlog[0]' \
  "$(policy_id 'GCP Alerts Hub - DLQ Backlog')"

# 推荐默认告警包（仅当 ENABLE_DEFAULT_ALERTS=Y 部署过且 tfvars 里 enable_default_alerts = true）
# 资源名 ↔ displayName 对照见 terraform/default_alerts.tf，逐条：
#   terraform import 'google_monitoring_alert_policy.rec_gce_cpu_high[0]' "$(policy_id 'Recommended - GCE High CPU Utilization')"
#   ……（共 11 条）

# IAM 绑定：*_iam_member 的 import ID 格式为 "<资源> <角色> <成员>"
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')
FN_SA="serviceAccount:gcp-alerts-fn@${PROJECT_ID}.iam.gserviceaccount.com"
# Secret accessor：for_each 资源，键 = 函数 env 名；只 import 当初所选渠道（与 tfvars 的 notify_channel 一致）的那几条
#   feishu（默认）：
terraform import 'google_secret_manager_secret_iam_member.secret_accessor["FEISHU_DEFAULT_WEBHOOK"]' \
  "projects/${PROJECT_ID}/secrets/feishu-default-webhook roles/secretmanager.secretAccessor ${FN_SA}"
terraform import 'google_secret_manager_secret_iam_member.secret_accessor["FEISHU_DEFAULT_SECRET"]' \
  "projects/${PROJECT_ID}/secrets/feishu-default-secret roles/secretmanager.secretAccessor ${FN_SA}"
#   wecom：
#   terraform import 'google_secret_manager_secret_iam_member.secret_accessor["WECOM_DEFAULT_WEBHOOK"]' \
#     "projects/${PROJECT_ID}/secrets/wecom-default-webhook roles/secretmanager.secretAccessor ${FN_SA}"
#   dingtalk：
#   terraform import 'google_secret_manager_secret_iam_member.secret_accessor["DINGTALK_DEFAULT_WEBHOOK"]' \
#     "projects/${PROJECT_ID}/secrets/dingtalk-default-webhook roles/secretmanager.secretAccessor ${FN_SA}"
#   terraform import 'google_secret_manager_secret_iam_member.secret_accessor["DINGTALK_DEFAULT_SECRET"]' \
#     "projects/${PROJECT_ID}/secrets/dingtalk-default-secret roles/secretmanager.secretAccessor ${FN_SA}"
terraform import google_pubsub_topic_iam_member.monitoring_publisher \
  "projects/${PROJECT_ID}/topics/gcp-alerts-hub roles/pubsub.publisher serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-monitoring-notification.iam.gserviceaccount.com"
terraform import google_pubsub_topic_iam_member.dlq_publisher \
  "projects/${PROJECT_ID}/topics/gcp-alerts-dlq roles/pubsub.publisher serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com"
# run.invoker：按 tfvars 的 run_invoker_scope 二选一
#   service（默认）—— gcloud 路径若当初授在服务级：
terraform import 'google_cloud_run_service_iam_member.invoker[0]' \
  "projects/${PROJECT_ID}/locations/asia-east1/services/gcp-alerts-to-feishu roles/run.invoker ${FN_SA}"
#   project —— gcloud 路径若当初复用了项目级绑定：
#   terraform import 'google_project_iam_member.invoker_project[0]' "${PROJECT_ID} roles/run.invoker ${FN_SA}"
# 可选数据源（仅启用时）：
#   terraform import 'google_pubsub_topic_iam_member.scc_publisher[0]'     "projects/${PROJECT_ID}/topics/gcp-alerts-hub roles/pubsub.publisher serviceAccount:service-org-<ORG_ID>@gcp-sa-scc-notification.iam.gserviceaccount.com"
#   terraform import 'google_pubsub_topic_iam_member.billing_publisher[0]' "projects/${PROJECT_ID}/topics/gcp-alerts-hub roles/pubsub.publisher serviceAccount:billing-budgets-pubsub@system.gserviceaccount.com"   # 成员名待确认，见上表

# 3. 确认没有意外的重建
terraform plan     # 期望：只有 in-place 更新，没有 destroy/replace，也没有同名策略的 create
```

> 没被 import 的 `*_iam_member` 在 apply 时通常只是幂等地重复授一次（不报错），
> 但**告警策略不是**：漏 import 一条就多一条同名策略、告警发双份。先看 `plan` 里有没有
> `google_monitoring_alert_policy` 的 `create`。

`terraform plan` 里若出现 `must be replaced`，先搞清楚原因再继续 ——
函数被 replace 会导致触发器订阅重建，期间的告警会丢。

---

## 反向：从 Terraform 退回 gcloud

不建议。若确实需要，`terraform state rm <资源>` 把资源移出管理但保留实体，
再用 gcloud 路径接管 —— 但此后就失去了漂移检测，等于回到起点。

---

## 常见问题

**Q：可以两条路径都跑吗？**
不要。资源名相同，第二条路径会与第一条争夺所有权。
Terraform 会试图接管 gcloud 建的资源并报 409，或反过来被 gcloud 覆盖后产生漂移。

**Q：Terraform 路径能只部署一部分吗？**
可以。开关及默认值：`enable_psh = true`（PSH 两类策略）、`enable_default_alerts = false`（推荐告警包）、
`enable_scc = false`、`enable_billing = false`、`ops_email = ""`（自监控，留空不建）。
无条件创建的只有 Cloud Monitoring 接入面（topic / 通知渠道 / 函数 / DLQ）——
少了它这个系统就没有存在意义；其余都可关。

**Q：state bucket 能换成已有的吗？**
可以，手工改 `terraform/backend.tf`（脚本每次运行会重新生成它，改完就别再跑脚本了，
或者同步修改脚本里的 `BUCKET_NAME`）。

**Q：CI 里怎么跑？**
```bash
# 飞书（默认）
export FEISHU_WEBHOOK='https://open.feishu.cn/open-apis/bot/v2/hook/xxx'
export FEISHU_SECRET='xxx'   # 未开签名校验则填 NONE
./deploy-terraform.sh --yes --region=asia-east1

# 企业微信（无签名）
# export NOTIFY_CHANNEL=wecom
# export WECOM_WEBHOOK='https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxx'

# 钉钉（推荐「加签」；未开加签、用关键词 / IP 模式则 DINGTALK_SECRET=NONE）
# export NOTIFY_CHANNEL=dingtalk
# export DINGTALK_WEBHOOK='https://oapi.dingtalk.com/robot/send?access_token=xxx'
# export DINGTALK_SECRET='SECxxx'
```
`--yes` 会跳过全部交互并对 `terraform apply` 自动批准（设 `TF_APPLY_CONFIRM=interactive` 则 plan 后仍停下等 yes，取消退出码 3）。
重跑时未提供的变量沿用线上（见上表）；若现状读不到（如缺 `billing.viewer`），Terraform 路径的 `--yes` 会报错要求显式提供
`ENABLE_BILLING` 等变量 —— CI 里建议显式列出所有 `ENABLE_*` / `OPS_EMAIL`。
凭据请用 CI 的 secret 机制注入，不要写进流水线定义文件。
