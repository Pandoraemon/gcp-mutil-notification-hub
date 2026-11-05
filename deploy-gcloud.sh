#!/bin/bash
# gcloud 快速体验路径：约 10 分钟在现有项目中拉起整条链路。
#
# 幂等性是硬要求（Definition of Done：连跑两次结果一致）。凡是"create 不幂等"的资源
# （Notification Channel、告警策略、SCC 导出、Billing 预算）一律先 list/describe 探测，
# 存在则 update，不存在才 create。
set -euo pipefail

cd "$(dirname "$0")"          # 允许从任意目录调用
source lib/common.sh

REGION="asia-east1"
ASSUME_YES=false
PROJECT_FLAG=""

usage() {
  cat <<'USAGE'
用法: ./deploy-gcloud.sh [选项]
  --project=ID      部署到指定项目（不传则交互式选择，见下）
  --region=REGION   部署区域（默认 asia-east1）
  --yes             跳过所有确认提示（CI 用；仍需通过环境变量提供凭据）
  --help, -h        显示此帮助

项目选择:
  优先级 --project 参数 > PROJECT_ID 环境变量 > 交互式选择 > gcloud 默认项目。
  交互模式下会列出当前账号可见的项目供选择；--yes 模式下必须显式指定项目。
  选定的项目只在本次运行内生效，不会改写你的 gcloud 默认配置。

环境变量:
  PROJECT_ID                       目标项目（等价于 --project）
  NOTIFY_CHANNEL                   通知渠道：feishu | wecom | dingtalk（默认 feishu；交互模式下菜单选择）
  FEISHU_WEBHOOK / FEISHU_SECRET   NOTIFY_CHANNEL=feishu 时的飞书/Lark 凭据（密钥未开启签名校验时填 NONE）
  WECOM_WEBHOOK                    NOTIFY_CHANNEL=wecom 时的企业微信群机器人 Webhook（无签名）
  DINGTALK_WEBHOOK / DINGTALK_SECRET
                                   NOTIFY_CHANNEL=dingtalk 时的钉钉凭据（推荐加签，填 SEC 开头的密钥；
                                   未开启加签填 NONE，此时若用自定义关键词，关键词须为「GCP告警」）
  MAX_SENDS_PER_MINUTE             每实例每分钟发送上限（默认：飞书 40 / 企业微信 8 / 钉钉 8）；
                                   须满足 速率 × MAX_INSTANCES ≤ 飞书 80 / 企业微信 16 / 钉钉 16
  MAX_INSTANCES                    函数最大实例数（默认 2）
  MIN_SEVERITY                     最低转发级别：CRITICAL | HIGH | MEDIUM | LOW | INFO（默认 MEDIUM）
  SOURCE_MIN_SEVERITY              按来源最低转发级别，格式 key=VALUE;...（如 monitoring=HIGH;billing=OFF）
  LOG_LEVEL                        函数日志级别：DEBUG | INFO | WARNING | ERROR（默认 INFO）
  KILL_SWITCH / PAUSE_MODE         急停 / 暂停开关 true | false（未提供时一律复位为 false）
  CONFIG_REVISION                  配置修订号（scripts/configure.sh 每次应用时更新，用于强制拉新 revision）
  KEEP_EXISTING_SECRETS=true       沿用 Secret Manager 中本渠道的现有凭据（不输入、不追加新版本；
                                   会校验 Secret 存在且有启用版本）
  SECRET_WEBHOOK_NAME / SECRET_SIGN_NAME
                                   飞书 Secret 名（默认 feishu-default-webhook / feishu-default-secret）
  SECRET_WECOM_WEBHOOK_NAME        企业微信 Secret 名（默认 wecom-default-webhook）
  SECRET_DINGTALK_WEBHOOK_NAME / SECRET_DINGTALK_SIGN_NAME
                                   钉钉 Secret 名（默认 dingtalk-default-webhook / dingtalk-default-secret）
  ENABLE_PSH                       是否部署默认 PSH 官方两类告警策略集（Y/n，默认 Y）
  ENABLE_DEFAULT_ALERTS            是否部署推荐默认监控告警包（GCE/配额/LB&NAT/GKE&SQL/IAM审计，y/N，默认 N）
  ENABLE_SCC / ENABLE_BILLING      非交互模式下的可选数据源开关（y/N，默认 N）
  BUDGET_AMOUNT                    非交互模式下的月度预算金额（如 100USD）
  OPS_EMAIL                        自监控告警（永久发送失败 / DLQ 积压）的邮件收件人；空则跳过并登记
  DEPLOYER_MEMBER                  覆盖补救提示中的 --member（默认按 gcloud 当前账号自动解析为 user:/serviceAccount:）

重跑不回退线上配置:
  函数已存在时，未显式提供的 NOTIFY_CHANNEL / MIN_SEVERITY / LOG_LEVEL / MAX_SENDS_PER_MINUTE（同渠道）/
  MAX_INSTANCES / CONFIG_REVISION / ENABLE_PSH / ENABLE_DEFAULT_ALERTS / ENABLE_SCC / ENABLE_BILLING /
  BUDGET_AMOUNT / OPS_EMAIL 沿用线上现值（读不到现状的开关本次保持不动：不创建也不删除）；
  KILL_SWITCH / PAUSE_MODE 例外 —— 未提供时复位为 false，线上为 true 时会打印醒目 WARNING。
  交互式修改全部配置请用 ./scripts/configure.sh。

说明:
  本脚本适合快速体验与个人项目。生产环境请使用 ./deploy-terraform.sh
  （生命周期管理对比见 docs/deployment-comparison.md）。
USAGE
}

for arg in "$@"; do
  case "${arg}" in
    --project=*) PROJECT_FLAG="${arg#*=}" ;;
    --region=*) REGION="${arg#*=}" ;;
    --yes)      ASSUME_YES=true ;;
    --help|-h)  usage; exit 0 ;;
    *)          echo "未知参数: ${arg}" >&2; usage; exit 1 ;;
  esac
done
export ASSUME_YES

require_commands gcloud zip envsubst

# 必须在任何 gcloud 操作之前确定项目：之后所有 gcloud 子命令都通过
# CLOUDSDK_CORE_PROJECT 落到这里选定的项目上。
select_project "${PROJECT_FLAG}"
# 全新项目里 cloudresourcemanager API 可能尚未启用（_use_project 对此已容忍），
# 这里不能硬失败；启用 API 之后再补查一次（见下方第 2 步）。
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)" 2>/dev/null || true)
FN_SA="${SERVICE_ACCOUNT_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
# 补救提示里的 --member 一律用运行时解析出的部署者身份（个人 / SA / WIF 均可，可用
# DEPLOYER_MEMBER 环境变量覆盖），补救命令可直接粘贴执行，不再含裸尖括号占位符。
resolve_deployer_member

echo "==== GCP 告警转发（飞书 / 企业微信 / 钉钉）- gcloud 快速部署 ===="
echo "项目 ID: ${PROJECT_ID} / 区域: ${REGION} / 部署者: ${DEPLOYER_MEMBER}"
echo ""

# 0.5 运行时配置：未显式提供的项沿用线上现值（重跑部署不再把 MIN_SEVERITY 等静默回退成默认值），
#     KILL_SWITCH / PAUSE_MODE 未提供时复位为 false 并在线上为 true 时告警。实现在 lib/common.sh，
#     与 Terraform 路径共用。
resolve_runtime_config "${REGION}" gcloud

# 1. 交互式输入（先问，避免启用一堆 API 后才发现用户想取消）
#    渠道三选一；之后所有 Secret / 环境变量 / 授权都只针对所选渠道。
#    KEEP_EXISTING_SECRETS=true 时不输入凭据，只校验现有 Secret（见 prompt_channel_credentials）。
prompt_channel_credentials
# 同渠道且未显式设置速率时沿用线上值；随后按渠道取默认值并校验上限（与 Terraform precondition 同口径）
inherit_live_send_rate
validate_channel_rate_limit
prompt_optional_sources

# 1.5 部署者权限预检（只读，不建任何资源）：缺权限在这里一次性列出，而不是跑到第 13 步才发现
preflight_deployer_permissions
preflight_hub_scope_permissions || die "汇聚范围权限不足，未做任何修改。补齐权限后重跑"

# 1.6 Hub 源项目权限预检：只检查【本次新增】的源项目；缺权限的从目标清单剔除（=本次不接入）并登记跳过。
# 已接入的项目不在这里剔除 —— 一次临时的权限/网络问题不能导致把它断开。
if [[ -n "${HUB_SOURCE_PROJECTS:-}" ]]; then
  _hub_kept=""
  IFS=';' read -ra _hub_items <<< "${HUB_SOURCE_PROJECTS}"
  for _hub_item in "${_hub_items[@]}"; do
    _hub_src="${_hub_item%%=*}"
    if [[ ";${LIVE_HUB_SOURCE_PROJECTS:-};" == *";${_hub_src}="* ]] || preflight_source_project "${_hub_src}"; then
      _hub_kept+="${_hub_kept:+;}${_hub_item}"
    else
      record_skip "接入源项目 ${_hub_src}" "该项目的告警与通知不会汇聚到本 Hub" \
        "补齐上方列出的权限后重跑：HUB_SOURCE_PROJECTS='${HUB_SOURCE_PROJECTS}' ./deploy-gcloud.sh"
    fi
  done
  HUB_SOURCE_PROJECTS="${_hub_kept}"
fi

# 2. 启用 API + 创建服务代理
check_and_enable_apis
ensure_service_agents
# API 已启用，此时 describe 一定可用；仍拿不到编号说明项目 ID 或权限有问题，不能继续
# （服务代理邮箱、预算过滤器都要用它）。
if [[ -z "${PROJECT_NUMBER}" ]]; then
  PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
fi

# 2.5 构建身份：必须在 functions deploy 之前完成，否则客户在全新项目里第一次部署必然踩坑。
# 实现放在 lib/common.sh，与 Terraform 路径共用同一份 —— 避免两条路径各修各的。
# 放在 API 启用之后、打包上传之前：默认 compute SA 随 API 首次启用才创建，
# 而放前面能让 IAM 传播轮询与后续打包/上传的时间重叠消化。
ensure_build_sa_role "${PROJECT_ID}" "${PROJECT_NUMBER}"

# 3. Secret Manager（幂等：已存在则追加新版本）
#    只写所选渠道的 Secret（飞书 2 个 / 企业微信 1 个 / 钉钉 2 个），映射见 lib/common.sh 的
#    set_channel_secret_mapping。其它渠道的 Secret 即使存在也不动。
echo "配置 Secret Manager（${CHANNEL_LABEL}）..."
upsert_channel_secrets

# 4. 自定义 Service Account（最小权限，替代默认 compute SA）
echo "配置 Service Account..."
if ! gcloud iam service-accounts describe "${FN_SA}" >/dev/null 2>&1; then
  if ! gcloud iam service-accounts create "${SERVICE_ACCOUNT_ID}" \
       --display-name="GCP Alerts to Feishu Function" >/dev/null 2>&1; then
    record_skip "创建自定义 Service Account ${SERVICE_ACCOUNT_ID}" \
      "函数将回落到默认 compute SA 运行 —— 权限面远大于本项目的最小权限设计；且该 SA 同时成为触发器身份" \
      "gcloud projects add-iam-policy-binding ${PROJECT_ID} --member=\"${DEPLOYER_MEMBER}\" --role=roles/iam.serviceAccountAdmin"
    FN_SA=""
  fi
fi
# 函数【实际】以哪个身份运行：自定义 SA，或创建失败时回落的默认 compute SA。
# 下面的 secretAccessor 必须授给这个真实身份 —— 回落分支若不授，--set-secrets 会让
# 新 revision 启动即崩（读不到 Secret），"能跑"是不成立的。
RUNTIME_SA="${FN_SA:-${PROJECT_NUMBER}-compute@developer.gserviceaccount.com}"
# 不授 roles/logging.logWriter：函数只写 stdout，由 Cloud Run 平台采集进 Cloud Logging，
# 运行身份不需要任何 Logging 权限（与 Terraform 路径一致）。

# secretAccessor 必须授在【具体 secret】上，不能授在项目级。
# 授在项目级会让这个只需要读两个 webhook 的函数，获得项目内【全部】Secret 的读权限，
# 并且影响面随客户日后新增 Secret 自动扩大，没有任何提示 ——
# 一旦函数被攻破，泄露范围就从"一个飞书群"变成"整个项目的凭据"。
# 与 Terraform 路径的 google_secret_manager_secret_iam_member 保持一致。
# 只授所选渠道的 Secret（RUNTIME_SA 已涵盖 FN_SA 回落默认 compute SA 的分支）：
# 授给未挂载的其它渠道 Secret 只会白白扩大读权限面。
for secret in "${CHANNEL_SECRET_NAMES[@]}"; do
  # 带重试：自定义 SA 可能是几秒前才创建的，IAM 侧尚不可见（见 soft_step_retry 说明）
  soft_step_retry 12 5 "给 ${RUNTIME_SA} 授 ${secret} 的 secretAccessor" \
    "函数运行时读不到该 Secret —— 表现为实例启动即崩溃、消息堆积在订阅中" \
    "gcloud secrets add-iam-policy-binding ${secret} --member=serviceAccount:${RUNTIME_SA} --role=roles/secretmanager.secretAccessor --project=${PROJECT_ID}" \
    -- gcloud secrets add-iam-policy-binding "${secret}" \
         --member="serviceAccount:${RUNTIME_SA}" \
         --role="roles/secretmanager.secretAccessor" --condition=None
done

# 5. Pub/Sub：主 topic + DLQ topic + DLQ 订阅
echo "创建 Pub/Sub 资源..."
gcloud pubsub topics describe "${TOPIC_NAME}" >/dev/null 2>&1 || \
  gcloud pubsub topics create "${TOPIC_NAME}"
gcloud pubsub topics describe "${DLQ_TOPIC_NAME}" >/dev/null 2>&1 || \
  gcloud pubsub topics create "${DLQ_TOPIC_NAME}"
# DLQ 订阅必须显式创建：没有订阅的 DLQ topic 会把死信直接丢弃，
# 而 replay-dlq.sh 依赖此订阅读取失败消息。
gcloud pubsub subscriptions describe "${DLQ_SUBSCRIPTION}" >/dev/null 2>&1 || \
  gcloud pubsub subscriptions create "${DLQ_SUBSCRIPTION}" \
    --topic="${DLQ_TOPIC_NAME}" \
    --message-retention-duration=7d \
    --expiration-period=never

# 6. 各服务代理的 publisher 授权
#    每个数据源用不同的服务代理向 topic 投递，漏授权的表现都是"静默无告警"。
echo "授权服务代理..."
MON_SA="service-${PROJECT_NUMBER}@gcp-sa-monitoring-notification.iam.gserviceaccount.com"
PUBSUB_SA="service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com"
soft_step "给 Monitoring 服务代理授 ${TOPIC_NAME} 的 publisher" \
  "Cloud Monitoring 指标告警将【静默】进不来 —— 部署看起来成功、日志也没有错误，群里就是收不到卡片" \
  "gcloud pubsub topics add-iam-policy-binding ${TOPIC_NAME} --member=serviceAccount:${MON_SA} --role=roles/pubsub.publisher --project=${PROJECT_ID}" \
  -- gcloud pubsub topics add-iam-policy-binding "${TOPIC_NAME}" \
       --member="serviceAccount:${MON_SA}" --role="roles/pubsub.publisher"

# Pub/Sub 服务代理需要能写 DLQ、并能 ack 源订阅，否则死信转发静默失败
soft_step "给 Pub/Sub 服务代理授 ${DLQ_TOPIC_NAME} 的 publisher" \
  "死信转发会静默失败：投递失败 5 次的消息既不会进 DLQ 也无法找回" \
  "gcloud pubsub topics add-iam-policy-binding ${DLQ_TOPIC_NAME} --member=serviceAccount:${PUBSUB_SA} --role=roles/pubsub.publisher --project=${PROJECT_ID}" \
  -- gcloud pubsub topics add-iam-policy-binding "${DLQ_TOPIC_NAME}" \
       --member="serviceAccount:${PUBSUB_SA}" --role="roles/pubsub.publisher"

# 7. 源码打包上传（gsutil 已弃用，统一使用 gcloud storage）
echo "打包并上传源码..."
BUCKET_NAME="${PROJECT_ID}-gcf-source"
gcloud storage buckets describe "gs://${BUCKET_NAME}" >/dev/null 2>&1 || \
  gcloud storage buckets create "gs://${BUCKET_NAME}" \
    --project="${PROJECT_ID}" --location="${REGION}" --uniform-bucket-level-access
rm -f function-source.zip
# 以 src/ 为包根打包：与 tests/conftest.py 注入的 sys.path 完全一致，
# 保证"测试里能 import 的，运行时也能 import"。
( cd src && zip -qr ../function-source.zip . -x '**/__pycache__/*' )
gcloud storage cp function-source.zip "gs://${BUCKET_NAME}/"

# （构建身份检查已前移到第 2.5 步，紧随 API 启用之后，与 Terraform 路径对齐。）

# 8. 部署 Cloud Functions Gen2
#    --retry 不可省略：Gen2 事件函数默认【不重试】，抛异常等于 ack 丢弃，
#    死信策略也就永远不会触发。
echo "部署 Cloud Functions（首次约需 3-5 分钟）..."

# 自定义 SA 创建失败时 FN_SA 为空：省掉 --service-account 让 Gen2 回落到默认 compute SA，
# 而不是传一个空值（gcloud 会把它当成非法参数直接报错）。
#
# --trigger-service-account 不能省：不传时 Eventarc 触发器用的是【默认 compute SA】，
# 而不是 --service-account 指定的运行 SA。那样触发器身份与 Terraform 路径
# （event_trigger.service_account_email = 函数 SA）不一致，8.5 步授的 run.invoker
# 也就授给了错误主体 —— 重建场景下 Eventarc 403、函数从未执行、日志只有 WARNING。
FN_SA_FLAGS=()
if [[ -n "${FN_SA}" ]]; then
  FN_SA_FLAGS=(--service-account="${FN_SA}" --trigger-service-account="${FN_SA}")
fi
# --set-env-vars 与 --set-secrets 都是【整体替换】语义：本次未列出的旧条目会被移除。
# 因此切换渠道（如 feishu → wecom）重跑时，旧渠道的 FEISHU_DEFAULT_* Secret 挂载会自然消失，
# 新 revision 只挂本渠道的 Secret；旧渠道的 Secret 本身及其 accessor 绑定保留，
# 需要时用 ./scripts/teardown-gcloud.sh --delete-secrets 回收。
# 也意味着部署后在控制台手工加的环境变量 / Secret 挂载会在重跑时被回滚。
# 运行时取值来自 resolve_runtime_config（环境变量 > 线上现值 > 默认值；KILL_SWITCH / PAUSE_MODE 默认 false）。
# CONFIG_REVISION 为空时不写：存量部署重跑时环境变量清单与旧版逐字一致。
FN_ENV_VARS="LOG_LEVEL=${LOG_LEVEL},MIN_SEVERITY=${MIN_SEVERITY},NOTIFY_CHANNEL=${NOTIFY_CHANNEL},MAX_SENDS_PER_MINUTE=${MAX_SENDS_PER_MINUTE},KILL_SWITCH=${KILL_SWITCH},PAUSE_MODE=${PAUSE_MODE},SELF_PROJECT_ID=${PROJECT_ID}"
if [[ -n "${SOURCE_MIN_SEVERITY:-}" ]]; then
  FN_ENV_VARS+=",SOURCE_MIN_SEVERITY=${SOURCE_MIN_SEVERITY}"
fi
if [[ -n "${CONFIG_REVISION}" ]]; then
  FN_ENV_VARS+=",CONFIG_REVISION=${CONFIG_REVISION}"
fi
if [[ -n "${HUB_SOURCE_PROJECTS:-}" ]]; then
  FN_ENV_VARS+=",HUB_SOURCE_PROJECTS=${HUB_SOURCE_PROJECTS}"
fi
if [[ -n "${HUB_SCOPE:-}" ]]; then
  FN_ENV_VARS+=",HUB_SCOPE=${HUB_SCOPE}"
fi

gcloud functions deploy "${FUNCTION_NAME}" \
  --gen2 \
  --region="${REGION}" \
  --runtime=python312 \
  --source="gs://${BUCKET_NAME}/function-source.zip" \
  --entry-point=handle_pubsub \
  --trigger-topic="${TOPIC_NAME}" \
  --retry \
  --memory=512Mi \
  --timeout=60s \
  --max-instances="${MAX_INSTANCES}" \
  --concurrency=1 \
  --ingress-settings=internal-only \
  --set-env-vars="${FN_ENV_VARS}" \
  --set-secrets="${CHANNEL_SET_SECRETS}" \
  "${FN_SA_FLAGS[@]}"

# 8.5 确保触发器身份能调用 Cloud Run
# Eventarc 用触发器身份去 invoke 函数背后的 Run 服务。gcloud functions deploy 通常会
# 自动补这条绑定，但实测在"函数记录已存在、Run 服务缺失"的重建场景下会漏掉。
# 漏掉的表现是最难察觉的一种：消息投递被 403 拒绝、函数从未执行、日志里只有 WARNING 级的
# "lacks {run.routes.invoke}"，部署与控制台看起来一切正常。
# 显式补一次（幂等），与 Terraform 路径的 google_cloud_run_service_iam_member 对齐。
# INVOKER_SA 与上面 --trigger-service-account 的取值严格一致（FN_SA 为空时两者都回落到
# 默认 compute SA）；导出给 run_self_test 的 403 诊断用，保证查的是同一个主体。
INVOKER_SA="${FN_SA:-${PROJECT_NUMBER}-compute@developer.gserviceaccount.com}"
export INVOKER_SA
# 先看项目级是否已授 run.invoker：它与服务级等效，而服务级绑定需要
# run.services.setIamPolicy（属 roles/run.admin），很多部署身份并没有 ——
# 不先查就直接尝试，会在权限已经配好的环境里报出一条假的"不完整"。
if gcloud projects get-iam-policy "${PROJECT_ID}" --flatten="bindings[].members" \
     --filter="bindings.role=roles/run.invoker AND bindings.members:${INVOKER_SA}" \
     --format="value(bindings.role)" 2>/dev/null | grep -q .; then
  log_ok "触发器身份已有项目级 run.invoker，无需服务级绑定"
else
  soft_step "给触发器身份授 Cloud Run invoker" \
    "Eventarc 无法调用函数：投递被 403 拒绝、函数从未执行，而日志里只有 WARNING —— 部署看起来完全正常，告警一条也进不来" \
    "gcloud projects add-iam-policy-binding ${PROJECT_ID} --member=serviceAccount:${INVOKER_SA} --role=roles/run.invoker（服务级绑定需调用方有 roles/run.admin，项目级只需 projectIamAdmin）" \
    -- gcloud run services add-iam-policy-binding "${FUNCTION_NAME}" \
         --region="${REGION}" \
         --member="serviceAccount:${INVOKER_SA}" \
         --role="roles/run.invoker"
fi

# 9. 给 Eventarc 生成的订阅挂上死信策略
#    订阅名由 Eventarc 自动生成（形如 eventarc-<region>-<trigger>-sub-<hash>），
#    必须动态查出来，不能硬编码。
echo "挂载死信策略..."
DLQ_IMPACT="失去死信兜底：连续失败 5 次的消息会被直接丢弃而非转入 ${DLQ_TOPIC_NAME}，replay-dlq.sh 也就无消息可重放"
# 触发器名【不等于】函数名：gcloud 会加随机后缀（实测形如 gcp-alerts-to-feishu-107219）。
# 直接 describe "${FUNCTION_NAME}" 会稳定 NOT_FOUND，死信策略于是永远挂不上 ——
# 而这是一个不报错的缺失。真名只能从函数自身的 eventTrigger.trigger 里取。
TRIGGER_NAME=$(gcloud functions describe "${FUNCTION_NAME}" --region="${REGION}" \
  --format="value(eventTrigger.trigger)" 2>/dev/null || true)
TRIGGER_NAME="${TRIGGER_NAME##*/}"
TRIGGER_SUB=""
if [[ -n "${TRIGGER_NAME}" ]]; then
  TRIGGER_SUB=$(gcloud eventarc triggers describe "${TRIGGER_NAME}" \
    --location="${REGION}" --format="value(transport.pubsub.subscription)" 2>/dev/null || true)
  TRIGGER_SUB="${TRIGGER_SUB##*/}"
fi
if [[ -z "${TRIGGER_SUB}" ]]; then
  record_skip "挂载死信策略" "${DLQ_IMPACT}" \
    "确认已有 roles/eventarc.viewer（或 cloudfunctions.developer）后重跑本脚本"
else
  DLQ_OK=true
  soft_step "配置死信策略" "${DLQ_IMPACT}" \
    "gcloud projects add-iam-policy-binding ${PROJECT_ID} --member=\"${DEPLOYER_MEMBER}\" --role=roles/pubsub.admin" \
    -- gcloud pubsub subscriptions update "${TRIGGER_SUB}" \
         --dead-letter-topic="${DLQ_TOPIC_NAME}" \
         --max-delivery-attempts=5 \
         --min-retry-delay="$(channel_min_retry_delay "${NOTIFY_CHANNEL}")" \
         --max-retry-delay=600s
  [[ "${LAST_STEP_OK}" == "true" ]] || DLQ_OK=false
  soft_step "给 Pub/Sub 服务代理授 ${TRIGGER_SUB} 的 subscriber" \
    "死信转发缺少 ack 源订阅的权限，死信策略配了也不会生效" \
    "gcloud pubsub subscriptions add-iam-policy-binding ${TRIGGER_SUB} --member=serviceAccount:${PUBSUB_SA} --role=roles/pubsub.subscriber --project=${PROJECT_ID}" \
    -- gcloud pubsub subscriptions add-iam-policy-binding "${TRIGGER_SUB}" \
         --member="serviceAccount:${PUBSUB_SA}" --role="roles/pubsub.subscriber"
  [[ "${LAST_STEP_OK}" == "true" ]] || DLQ_OK=false
  # 任一子步骤被跳过就不打印 ✅ —— 上面刚登记了"已跳过"，紧接着一条"已挂载"是自相矛盾的
  if [[ "${DLQ_OK}" == "true" ]]; then
    log_ok "死信策略已挂载到 ${TRIGGER_SUB}（5 次失败后转入 ${DLQ_TOPIC_NAME}）"
    echo "   注意：重新部署函数可能重建触发器订阅，本脚本每次运行都会重新挂载"
  fi
fi

# 10. Monitoring Notification Channel（不幂等 → 先按 displayName 查）
#     CHANNEL_DISPLAY_NAME 定义在 lib/common.sh（teardown 按同一个名字精确删除）
# 过滤器里的字符串字面量必须用【双引号】：notificationChannels 的 filter 语法不接受
# 单引号，会直接返回 INVALID_ARGUMENT。而这个错误一旦被 2>/dev/null 吞掉，就会被当成
# "渠道不存在" —— 于是每次重跑都新建一个同名渠道，幂等性静默失效
# （实测连跑 5 次产出 5 个 "Feishu Alert Hub"）。alertPolicies 的过滤器语法更宽松，
# 单引号可用，所以下方 Service Health 那段没有同样的问题。
CHANNEL_QUERY_OK=true
CHANNEL_ID=$(gcloud beta monitoring channels list \
  --filter="displayName=\"${CHANNEL_DISPLAY_NAME}\" AND type=\"pubsub\"" \
  --format="value(name)" 2>/dev/null | head -1) || CHANNEL_QUERY_OK=false
if [[ "${CHANNEL_QUERY_OK}" != "true" ]]; then
  # 查询失败 ≠ 渠道不存在。此时【不能】创建：那正是产生重复渠道的路径。
  record_skip "创建 / 复用 Notification Channel" \
    "无法确认渠道是否已存在，为避免产生重复渠道本次不创建；Monitoring 指标告警这一路暂不通" \
    "确认已有 roles/monitoring.notificationChannelEditor 后重跑本脚本（幂等）"
  CHANNEL_ID=""
elif [[ -z "${CHANNEL_ID}" ]]; then
  CHANNEL_JSON=$(cat <<EOF
{
  "type": "pubsub",
  "displayName": "${CHANNEL_DISPLAY_NAME}",
  "labels": { "topic": "projects/${PROJECT_ID}/topics/${TOPIC_NAME}" }
}
EOF
)
  CHANNEL_ID=$(gcloud beta monitoring channels create \
    --channel-content="${CHANNEL_JSON}" --format="value(name)" 2>/dev/null || true)
  if [[ -n "${CHANNEL_ID}" ]]; then
    log_ok "Notification Channel 已创建"
  else
    record_skip "创建 Notification Channel「${CHANNEL_DISPLAY_NAME}」" \
      "Cloud Monitoring 告警策略无处可选此渠道 —— 指标告警这一路数据源不通" \
      "gcloud projects add-iam-policy-binding ${PROJECT_ID} --member=\"${DEPLOYER_MEMBER}\" --role=roles/monitoring.notificationChannelEditor"
  fi
else
  log_ok "Notification Channel 已存在，复用"
fi
# export 是必须的：envsubst 只替换已导出的变量，
# 否则 Service Health 策略会生成一个【没有通知渠道】的告警策略 —— 创建成功但永远不发通知。
export CHANNEL_ID
echo "Notification Channel ID: ${CHANNEL_ID}"

# 11. 默认 Personalized Service Health (PSH) 两类官方策略集 + 推荐默认高级监控告警包（可选）
export PROJECT_ID
deploy_psh_alert_policies
deploy_recommended_default_alerts

# 11.5 自监控告警（永久发送失败 / DLQ 积压 → 邮件）。
#      IM 链路坏掉时不能再靠 IM 群报警，这两条走 OPS_EMAIL；未填邮箱会登记为跳过项。
#      Terraform 路径由 .tf 实现（变量 ops_email），此处只在 gcloud 路径调用。
deploy_self_monitoring_alerts

# 12. SCC（可选）
if [[ "${ENABLE_SCC}" =~ ^[Yy]$ ]]; then
  echo "检查 SCC 权限..."
  # gcloud projects get-ancestors 【不支持 --filter】（传了会报 unrecognized arguments）。
  # 而这里是命令替换赋值，一旦报错 set -e 会就地终止整个脚本 —— 位置恰好在
  # 核心链路全部建成之后、自检之前，用户拿不到任何结论。
  # 正确做法：拿 csv 再挑出 type=organization 那一行；项目可能挂在文件夹下，
  # 所以不能简单取 parent，必须沿祖先链往上找。|| true 兜住无组织的情况。
  ORG_ID=$(gcloud projects get-ancestors "${PROJECT_ID}" \
    --format="csv[no-heading](id,type)" 2>/dev/null \
    | awk -F, '$2=="organization"{print $1}' | head -1) || true

  if [[ -z "${ORG_ID}" ]]; then
    record_skip "配置 SCC 导出" "项目不隶属于任何组织，SCC 本就不可用" \
      "无需处理 —— 该项目无法使用 SCC"
  # 用 list 探测【权限】；用 describe 探测的是【资源是否已存在】，
  # 首次部署必然失败并误报为"无权限"，导致 SCC 永远配不上。
  elif ! gcloud scc notifications list --organization="${ORG_ID}" >/dev/null 2>&1; then
    record_skip "配置 SCC 导出（org ${ORG_ID}）" "安全发现不会转发到${CHANNEL_LABEL}" \
      "gcloud organizations add-iam-policy-binding ${ORG_ID} --member=\"${DEPLOYER_MEMBER}\" --role=roles/securitycenter.notificationConfigEditor（需组织管理员执行）"
  else
    # SCC 服务代理需要 publisher 权限，否则导出配置创建成功但没有消息进来。
    # 走 soft_step 的原因与 Billing 那处相同：该服务代理往往要到组织首次使用
    # SCC 通知后才存在，首次部署时绑定失败是常态 —— 裸命令会让 set -e
    # 在这里终止整个脚本，连自检都跑不到。
    SCC_SA="service-org-${ORG_ID}@gcp-sa-scc-notification.iam.gserviceaccount.com"
    soft_step "给 SCC 服务代理授 ${TOPIC_NAME} 的 publisher" \
      "安全发现【静默】进不来 —— 导出配置会创建成功，但 SCC 推不出消息" \
      "gcloud pubsub topics add-iam-policy-binding ${TOPIC_NAME} --member=serviceAccount:${SCC_SA} --role=roles/pubsub.publisher --project=${PROJECT_ID}（服务代理不存在时，先在组织内创建一次 SCC 通知配置使其生成）" \
      -- gcloud pubsub topics add-iam-policy-binding "${TOPIC_NAME}" \
           --member="serviceAccount:${SCC_SA}" --role="roles/pubsub.publisher"

    SCC_REMEDY="gcloud organizations add-iam-policy-binding ${ORG_ID} --member=\"${DEPLOYER_MEMBER}\" --role=roles/securitycenter.notificationConfigEditor（需组织管理员执行）"
    if gcloud scc notifications describe feishu-scc-export --organization="${ORG_ID}" >/dev/null 2>&1; then
      if gcloud scc notifications update feishu-scc-export --organization="${ORG_ID}" \
           --pubsub-topic="projects/${PROJECT_ID}/topics/${TOPIC_NAME}" \
           --filter='severity="HIGH" OR severity="CRITICAL"' >/dev/null 2>&1; then
        log_ok "SCC 导出配置已更新"
      else
        record_skip "更新 SCC 导出配置" "安全发现仍沿用旧的导出配置" "${SCC_REMEDY}"
      fi
    else
      if gcloud scc notifications create feishu-scc-export --organization="${ORG_ID}" \
           --pubsub-topic="projects/${PROJECT_ID}/topics/${TOPIC_NAME}" \
           --filter='severity="HIGH" OR severity="CRITICAL"' >/dev/null 2>&1; then
        log_ok "SCC 导出配置已创建"
      else
        record_skip "创建 SCC 导出配置" "安全发现不会转发到${CHANNEL_LABEL}" "${SCC_REMEDY}"
      fi
    fi
  fi
fi

# 13. Billing Budgets（可选）
#     gcloud billing budgets 是 GA 命令，门槛是权限而非 CLI 能力（见 ADR-003）
if [[ "${ENABLE_BILLING}" =~ ^[Yy]$ ]]; then
  echo "检查 Billing 权限..."
  # `|| true` 不可省：pipefail 在 $() 内同样生效，无 billing.viewer 时 gcloud 失败会让
  # 整条赋值非 0 → set -e 无声退出（stderr 已被吞），下面那条 record_skip 永远到不了。
  BILLING_ACCOUNT=$(gcloud billing projects describe "${PROJECT_ID}" \
    --format="value(billingAccountName)" 2>/dev/null | sed 's|billingAccounts/||' || true)

  if [[ -z "${BILLING_ACCOUNT}" ]]; then
    record_skip "配置 Billing 预算" "预算超支不会转发到${CHANNEL_LABEL}" \
      "gcloud projects add-iam-policy-binding ${PROJECT_ID} --member=\"${DEPLOYER_MEMBER}\" --role=roles/billing.viewer（先要能读出项目的结算账号）"
  elif ! gcloud billing budgets list --billing-account="${BILLING_ACCOUNT}" >/dev/null 2>&1; then
    record_skip "配置 Billing 预算（账号 ${BILLING_ACCOUNT}）" "预算超支不会转发到${CHANNEL_LABEL}" \
      "gcloud billing accounts add-iam-policy-binding ${BILLING_ACCOUNT} --member=\"${DEPLOYER_MEMBER}\" --role=roles/billing.costsManager（需结算账号管理员执行；billing.admin 是其超集）"
  else
    if [[ "${ASSUME_YES}" == "true" ]]; then
      BUDGET_AMOUNT="${BUDGET_AMOUNT:-100USD}"
    elif _optional_is_inherited BUDGET_AMOUNT; then
      read -rp "请输入月度预算金额（如 100USD，回车沿用线上：${BUDGET_AMOUNT}）: " _budget_in
      BUDGET_AMOUNT="${_budget_in:-${BUDGET_AMOUNT}}"
    else
      read -rp "请输入月度预算金额（如 100USD）: " BUDGET_AMOUNT
    fi
    # Billing 预算的推送服务代理是固定账号，同样需要 publisher 权限。
    # 必须走 soft_step：这个 system SA 并非在所有组织里都解析得出来
    # （实测某些组织返回 "Service account ... does not exist"，另一些则被
    # iam.allowedPolicyMemberDomains 域限制策略拒绝）。此处若用裸命令，
    # set -e 会在【所有资源都已建好、自检尚未运行】的位置把脚本整个杀掉 ——
    # 用户看到的是一条与 Billing 无关的 IAM 报错，且永远等不到自检结论。
    soft_step "给 Billing 预算推送代理授 ${TOPIC_NAME} 的 publisher" \
      "Billing 预算超支【不会】转发到${CHANNEL_LABEL} —— 预算本身会创建成功，Pub/Sub 推送却发不出来，控制台看不出异常" \
      "确认 billing-budgets-pubsub@system.gserviceaccount.com 在本组织可解析；若受 iam.allowedPolicyMemberDomains 限制，需组织管理员把该 SA 所属 customer ID 加入白名单" \
      -- gcloud pubsub topics add-iam-policy-binding "${TOPIC_NAME}" \
           --member="serviceAccount:billing-budgets-pubsub@system.gserviceaccount.com" \
           --role="roles/pubsub.publisher"

    # `budgets create` 不幂等：重复运行会创建同名的第二个预算，于是同一次超支
    # 会推两条消息。必须先按 displayName 查，存在则 update。
    BUDGET_DISPLAY_NAME="Feishu Alert Budget - ${PROJECT_ID}"
    EXISTING_BUDGET=$(gcloud billing budgets list \
      --billing-account="${BILLING_ACCOUNT}" \
      --filter="displayName='${BUDGET_DISPLAY_NAME}'" \
      --format="value(name)" 2>/dev/null | head -1 || true)
    # create 与 update 共用的部分
    BUDGET_COMMON_FLAGS=(
      --display-name="${BUDGET_DISPLAY_NAME}"
      --budget-amount="${BUDGET_AMOUNT}"
      --filter-projects="projects/${PROJECT_NUMBER}"
      --notifications-rule-pubsub-topic="projects/${PROJECT_ID}/topics/${TOPIC_NAME}"
    )
    # 阈值规则两边 flag 名【不同】：create 用 --threshold-rule，
    # update 只接受 --add-threshold-rule / --clear-threshold-rules / --threshold-rules-from-file
    # （`gcloud billing budgets update --help` 实测）。把 create 的 flags 原样传给 update
    # 会报 unrecognized arguments —— 启用 Billing 后每次重跑必败，且报错被吞、补救提示还指向权限。
    BUDGET_THRESHOLDS=(percent=0.5 percent=0.9 percent=1.0 percent=1.0,basis=forecasted-spend)
    BUDGET_CREATE_FLAGS=("${BUDGET_COMMON_FLAGS[@]}")
    BUDGET_UPDATE_FLAGS=("${BUDGET_COMMON_FLAGS[@]}" --clear-threshold-rules)
    for rule in "${BUDGET_THRESHOLDS[@]}"; do
      BUDGET_CREATE_FLAGS+=(--threshold-rule="${rule}")
      BUDGET_UPDATE_FLAGS+=(--add-threshold-rule="${rule}")
    done
    # 与本块其它步骤同理：预算创建失败（配额、API 未就绪、结算账号策略等）
    # 属于可降级范畴，不该把已经建好的核心链路一起带走。
    BUDGET_REMEDY="gcloud billing accounts add-iam-policy-binding ${BILLING_ACCOUNT} --member=\"${DEPLOYER_MEMBER}\" --role=roles/billing.costsManager（需结算账号管理员执行），并确认 billingbudgets.googleapis.com 已启用"
    if [[ -n "${EXISTING_BUDGET}" ]]; then
      if gcloud billing budgets update "${EXISTING_BUDGET##*/}" \
           --billing-account="${BILLING_ACCOUNT}" "${BUDGET_UPDATE_FLAGS[@]}" >/dev/null 2>&1; then
        log_ok "Billing 预算已更新"
      else
        record_skip "更新 Billing 预算" "预算仍沿用旧的阈值或推送配置" "${BUDGET_REMEDY}"
      fi
    else
      if gcloud billing budgets create \
           --billing-account="${BILLING_ACCOUNT}" "${BUDGET_CREATE_FLAGS[@]}" >/dev/null 2>&1; then
        log_ok "Billing 预算已创建"
      else
        record_skip "创建 Billing 预算" "预算超支不会转发到${CHANNEL_LABEL}" "${BUDGET_REMEDY}"
      fi
    fi
  fi
fi

# 13.5 Hub 多项目路由拓扑应用
reconcile_hub_sources

# 14. 自检
# 自检失败不再直接中断：此时已有跳过项待汇报，中断会让用户看不到"缺哪些权限"。
SELF_TEST_OK=true
run_self_test "${PROJECT_ID}" "${TOPIC_NAME}" || SELF_TEST_OK=false

# 15. 结论
# 只要有跳过项就不能打印"部署完成" —— 让一次不完整的部署看起来成功，
# 正是本项目反复防范的那类静默失效。
echo ""
if report_skips && [[ "${SELF_TEST_OK}" == "true" ]]; then
  log_ok "gcloud 部署完成"
  EXIT_CODE=0
elif [[ "${SELF_TEST_OK}" != "true" ]]; then
  log_error "gcloud 部署已完成资源创建，但自检未通过 —— 见上方错误与 docs/troubleshooting.md"
  EXIT_CODE=1
else
  log_warn "gcloud 部署以【不完整】状态结束：核心链路已建立，上列步骤被跳过"
  EXIT_CODE=2
fi

echo "   紧急停止: ./scripts/emergency-disable.sh --project=${PROJECT_ID}"
echo "   DLQ 重放: ./scripts/replay-dlq.sh --project=${PROJECT_ID}"
echo "   完全卸载: ./scripts/teardown-gcloud.sh --project=${PROJECT_ID} --region=${REGION}"
exit "${EXIT_CODE}"
