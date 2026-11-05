#!/bin/bash
# 清理 gcloud 路径创建的全部资源（对齐 terraform destroy 的效果）。
#
# 删除顺序有讲究：先删函数（连带 Eventarc 触发器与托管订阅），再删订阅/topic，
# 否则 topic 上仍挂着订阅会导致删除失败或留下孤儿订阅。
set -euo pipefail

cd "$(dirname "$0")/.."
source lib/common.sh

REGION="${REGION:-asia-east1}"
ASSUME_YES=false
DELETE_SECRETS=false
PROJECT_FLAG=""

usage() {
  cat <<'USAGE'
用法: ./scripts/teardown-gcloud.sh [选项]
  --project=ID       资源所在项目（不传则交互式选择）
  --region=REGION    资源所在区域（默认 asia-east1）
  --delete-secrets   一并删除 Secret Manager 中的渠道凭据（默认保留）。按精确名删除、存在才删：
                       feishu-default-webhook / feishu-default-secret / wecom-default-webhook /
                       dingtalk-default-webhook / dingtalk-default-secret
                       （名字可用 SECRET_WEBHOOK_NAME / SECRET_SIGN_NAME / SECRET_WECOM_WEBHOOK_NAME /
                        SECRET_DINGTALK_WEBHOOK_NAME / SECRET_DINGTALK_SIGN_NAME 覆盖，须与部署时一致）
  --yes              跳过确认提示
  --help, -h         显示此帮助

会删除（只按本仓库固定的资源名 / displayName 精确匹配，不会碰客户自建的同前缀资源）:
  Cloud Functions 函数与 Eventarc 触发器、Pub/Sub 主题与订阅（含 DLQ）、
  Notification Channel（告警 Pub/Sub 渠道 + 自监控邮件渠道）、Service Health / 推荐默认 /
  自监控告警策略、SCC 导出配置、Billing 预算、自定义 Service Account 及其项目级角色绑定、
  上述五个渠道 Secret 上授给函数身份的 secretAccessor 绑定、源码 bucket 中的 zip。

不会删除:
  已启用的 API、Secret（除非 --delete-secrets）、源码 bucket 本身
  （bucket 可能被同项目其它函数共用）。
  Terraform 路径部署的环境（topic 带 managed-by=terraform 标签）会被拒绝，请用 terraform destroy。
USAGE
}

for arg in "$@"; do
  case "${arg}" in
    --project=*)      PROJECT_FLAG="${arg#*=}" ;;
    --region=*)       REGION="${arg#*=}" ;;
    --delete-secrets) DELETE_SECRETS=true ;;
    --yes)            ASSUME_YES=true ;;
    --help|-h)        usage; exit 0 ;;
    *)                echo "未知参数: ${arg}" >&2; usage; exit 1 ;;
  esac
done
export ASSUME_YES

require_commands gcloud

# 删除类操作尤其不能依赖"当前默认项目"：部署时选了 A、卸载时打到 B，
# 后果是把另一个项目的同名资源删掉。
select_project "${PROJECT_FLAG}"
# 与 _use_project 的容忍逻辑一致：cloudresourcemanager 未启用/无权限时不在此硬退出；
# 项目编号只用于结尾的提示文案。
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)" 2>/dev/null || true)
FN_SA="${SERVICE_ACCOUNT_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

# 识别 Terraform 部署：Terraform 路径给 topic 打了 managed-by=terraform 标签。
# 从 tfstate 底下把资源删掉会让下一次 plan 出一堆错误的 create/destroy，
# 这种环境必须走 terraform destroy。
# 判定逻辑在 lib/common.sh 的 detect_deploy_mode（scripts/configure.sh 共用同一份）。
detect_deploy_mode
if [[ "${DEPLOY_MODE}" == "terraform" ]]; then
  log_error "topic ${TOPIC_NAME} 带有 managed-by=terraform 标签：这是 Terraform 路径部署的环境"
  echo "   本脚本只清理 gcloud 路径的资源。请改用：cd terraform && terraform destroy" >&2
  exit 1
fi

echo "==== 清理 gcloud 路径资源 ===="
echo "项目 ID: ${PROJECT_ID} / 区域: ${REGION}"
log_warn "此操作不可逆。DLQ 中尚未重放的消息会一并丢失。"
echo ""
if [[ "${ASSUME_YES}" != "true" ]]; then
  read -rp "确认删除？请输入项目 ID 以继续: " CONFIRM
  [[ "${CONFIRM}" == "${PROJECT_ID}" ]] || { echo "输入不匹配，操作已取消"; exit 0; }
fi

# 尝试读取线上函数的配置以获取 Hub 模式拓扑（需清理源项目）
load_live_function_config || true

# 每一步都容错：部分资源可能本就不存在（例如从未启用 SCC），
# 不能让一次失败中断整个清理流程。
step() { echo "→ $*"; }

if [[ -n "${LIVE_HUB_SOURCE_PROJECTS:-}" ]]; then
  step "断开源项目 (Hub 模式)"
  IFS=';' read -ra items <<< "${LIVE_HUB_SOURCE_PROJECTS}"
  for item in "${items[@]}"; do
    src="${item%%=*}"
    src_num="${item#*=}"
    disconnect_source_project "${src}" "${src_num}"
  done
fi

if [[ -n "${LIVE_HUB_SCOPE:-}" ]]; then
  step "删除聚合 Logging Sink"
  remove_hub_scope_sink "${LIVE_HUB_SCOPE}"
fi

if [[ -n "${LIVE_HUB_SOURCE_PROJECTS:-}${LIVE_HUB_SCOPE:-}" ]]; then
  step "删除 Hub 回灌审计日志 sink"
  remove_hub_routed_audit_sink
fi

step "删除 Cloud Functions 函数（连带 Eventarc 触发器与托管订阅）"
gcloud functions delete "${FUNCTION_NAME}" --region="${REGION}" --gen2 --quiet 2>/dev/null || \
  log_info "函数不存在，跳过"

step "删除 Pub/Sub 订阅与主题"
gcloud pubsub subscriptions delete "${DLQ_SUBSCRIPTION}" --quiet 2>/dev/null || \
  log_info "${DLQ_SUBSCRIPTION} 不存在，跳过"
# Eventarc 托管订阅通常随函数一起删除；残留的按【精确 topic】清掉。
# 过滤器必须用 `=` 全名精确匹配：`topic:${TOPIC_NAME}` 的 `:` 是 contains 语义，
# 会把 gcp-alerts-hub-prod、my-gcp-alerts-hub 等客户自己 topic 的订阅一并删掉。
# Subscription 资源的 topic 字段是全名 projects/<p>/topics/<t>。
SUB_FILTER="topic=\"projects/${PROJECT_ID}/topics/${TOPIC_NAME}\""
while read -r sub; do
  [[ -n "${sub}" ]] || continue
  step "删除残留的 Eventarc 订阅 ${sub##*/}"
  gcloud pubsub subscriptions delete "${sub}" --quiet 2>/dev/null || true
done < <(gcloud pubsub subscriptions list \
  --filter="${SUB_FILTER}" --format="value(name)" 2>/dev/null || true)
gcloud pubsub topics delete "${TOPIC_NAME}" --quiet 2>/dev/null || log_info "${TOPIC_NAME} 不存在，跳过"
gcloud pubsub topics delete "${DLQ_TOPIC_NAME}" --quiet 2>/dev/null || log_info "${DLQ_TOPIC_NAME} 不存在，跳过"

step "删除 Service Health (PSH)、推荐默认与自监控告警策略"
# 只删本仓库【拥有】的 displayName（清单在 lib/common.sh 的 MANAGED_POLICY_DISPLAY_NAMES，
# 与部署函数共用同一份）。不能按前缀：客户自建的 "Recommended - xxx" 会被误删。
# 带 userLabels.managed-by=terraform 的策略跳过并提示走 terraform destroy。
# 实现见 lib/common.sh 的 remove_alert_policies_by_display_names（configure.sh 的「开 → 关」共用）。
remove_alert_policies_by_display_names "${MANAGED_POLICY_DISPLAY_NAMES[@]}"

step "删除 Notification Channel（告警 Pub/Sub 渠道 + 自监控邮件渠道）"
# 字面量必须用双引号：notificationChannels 的 filter 语法不接受单引号，会返回
# INVALID_ARGUMENT。此前的单引号写法配上 2>/dev/null 的结果是【一个渠道都删不掉，
# 却也不报错】—— 卸载看起来成功，渠道全部留在项目里。（实现见 lib/common.sh）
remove_notification_channels_by_display_names "${CHANNEL_DISPLAY_NAME}" "${OPS_EMAIL_CHANNEL_DISPLAY_NAME}"

step "删除 SCC 导出配置（若有）"
# get-ancestors 不支持 --filter（rc=2）；与 deploy-gcloud.sh 同一写法沿祖先链找 organization。
# 旧写法下 ORG_ID 恒为空 → 这一步永远不执行，组织级导出配置残留并继续向已删除 topic 推送。
remove_scc_export

step "删除 Billing 预算（若有）"
remove_billing_budget

step "删除 Service Account 与角色绑定"
# run.invoker 也要清：部署脚本在服务级授它（随 Run 服务一起消失），但当部署身份没有
# run.services.setIamPolicy 时，README 指导用户改授在【项目级】—— 那一条不会随函数删除，
# 会留下一条指向已删除 SA 的悬空绑定。
#
# secretmanager.secretAccessor 保留在这个列表里【只为向后兼容】：
# 旧版部署脚本把它授在项目级，用新版 teardown 清理旧环境时仍需能收回。
# 新版授在 secret 级，由下面单独处理。
for role in roles/secretmanager.secretAccessor roles/logging.logWriter roles/run.invoker; do
  gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${FN_SA}" --role="${role}" --condition=None >/dev/null 2>&1 || true
done

# Secret 级绑定必须显式回收。不保留 --delete-secrets 时 Secret 会留存，
# 而它上面那条指向【已删除 SA】的绑定不会自动消失 ——
# 表现为控制台里一个 deleted:serviceAccount:... 的孤儿条目，安全扫描会报出来。
#
# 覆盖三个渠道的全部五个 Secret（清单 ALL_CHANNEL_SECRET_NAMES 在 lib/common.sh）：
# 切换过渠道的项目里可能同时留有多套。只处理【存在】的 Secret，按精确名，不做前缀匹配。
# 除自定义 SA 外，也回收默认 compute SA 上的绑定：自定义 SA 创建失败时，部署脚本把
# secretAccessor 授给了回落的默认 compute SA（只动这五个本仓库拥有的 Secret，不碰项目级）。
EXISTING_CHANNEL_SECRETS=()
for secret in "${ALL_CHANNEL_SECRET_NAMES[@]}"; do
  if gcloud secrets describe "${secret}" >/dev/null 2>&1; then
    EXISTING_CHANNEL_SECRETS+=("${secret}")
  fi
done
SECRET_MEMBERS=("serviceAccount:${FN_SA}")
[[ -n "${PROJECT_NUMBER}" ]] && \
  SECRET_MEMBERS+=("serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com")
for secret in ${EXISTING_CHANNEL_SECRETS[@]+"${EXISTING_CHANNEL_SECRETS[@]}"}; do
  for member in "${SECRET_MEMBERS[@]}"; do
    gcloud secrets remove-iam-policy-binding "${secret}" \
      --member="${member}" \
      --role="roles/secretmanager.secretAccessor" --condition=None >/dev/null 2>&1 || true
  done
done

# 刻意【不】回收默认 compute SA 上的 roles/cloudbuild.builds.builder：
# 它是项目级构建基础设施权限，项目里的其他函数/构建可能依赖它，
# 而且很多项目在本方案部署之前就已经有了。收回它属于越界破坏。
gcloud iam service-accounts delete "${FN_SA}" --quiet 2>/dev/null || log_info "SA 不存在，跳过"

step "删除源码 zip 与存储桶"
gcloud storage rm "gs://${PROJECT_ID}-gcf-source/function-source.zip" --quiet 2>/dev/null || true
gcloud storage buckets delete "gs://${PROJECT_ID}-gcf-source" --quiet 2>/dev/null || log_info "源码存储桶不存在或非空，跳过"
rm -f function-source.zip

if [[ "${DELETE_SECRETS}" == "true" ]]; then
  step "删除 Secret（飞书 / 企业微信 / 钉钉，存在才删）"
  if (( ${#EXISTING_CHANNEL_SECRETS[@]} == 0 )); then
    log_info "未发现本仓库的渠道 Secret，跳过"
  fi
  for secret in ${EXISTING_CHANNEL_SECRETS[@]+"${EXISTING_CHANNEL_SECRETS[@]}"}; do
    if gcloud secrets delete "${secret}" --quiet 2>/dev/null; then
      log_info "已删除 Secret ${secret}"
    else
      log_warn "删除 Secret ${secret} 失败（权限不足？），请手工确认：gcloud secrets delete ${secret} --project=${PROJECT_ID}"
    fi
  done
else
  log_info "Secret 已保留（如需删除请加 --delete-secrets）"
fi

echo ""
log_ok "清理完成（项目 ${PROJECT_ID}${PROJECT_NUMBER:+ / 编号 ${PROJECT_NUMBER}}）"
echo "   已启用的 API 未被停用 —— 未使用的 API 不产生费用，如需停用请手工执行 gcloud services disable"
