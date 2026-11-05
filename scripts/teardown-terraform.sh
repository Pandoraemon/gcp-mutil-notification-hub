#!/bin/bash
# scripts/teardown-terraform.sh —— 清理 Terraform 路径部署的基础设施及残留 Secret。
#
# 流程：
#   1. 选定项目，校验非 gcloud 路径环境（防止误对 gcloud 环境跑空 destroy 后误删 Secret）；
#   2. 配置 backend.tf 与必要变量，执行 terraform destroy（交互确认或 --yes 自动批准）；
#   3. destroy 成功后，按 ALL_CHANNEL_SECRET_NAMES 精确回收项目内残留的渠道 Secret（默认清理，除非 --keep-secrets）。
set -euo pipefail

cd "$(dirname "$0")/.."
source lib/common.sh

REGION="${REGION:-asia-east1}"
ASSUME_YES=false
KEEP_SECRETS=false
PROJECT_FLAG=""

usage() {
  cat <<'USAGE'
用法: ./scripts/teardown-terraform.sh [选项]
  --project=ID       资源所在项目（不传则交互式选择）
  --region=REGION    资源所在区域（默认 asia-east1）
  --keep-secrets     保留 Secret Manager 中的渠道凭据（默认清理）
  --delete-secrets   兼容 teardown-gcloud.sh 参数（默认即清理渠道凭据）
  --yes              跳过确认提示并自动批准 terraform destroy -auto-approve
  --help, -h         显示此帮助

清理范围:
  1. 在 terraform/ 目录执行 terraform destroy，清除由 Terraform 管理的所有资源：
     函数、Pub/Sub、IAM 绑定、Notification Channel、告警策略、源码 bucket 等。
  2. destroy 成功后，按本仓库的五个渠道 Secret 精确名回收残留凭据（除非 --keep-secrets）：
     feishu-default-webhook / feishu-default-secret / wecom-default-webhook /
     dingtalk-default-webhook / dingtalk-default-secret

不会删除:
  已启用的 API、Terraform state bucket（gs://<PROJECT_ID>-gcp-feishu-tfstate）。
  gcloud 路径部署的环境（topic 存在但无 managed-by=terraform 标签）会被拒绝，请用 scripts/teardown-gcloud.sh。
USAGE
}

for arg in "$@"; do
  case "${arg}" in
    --project=*)      PROJECT_FLAG="${arg#*=}" ;;
    --region=*)       REGION="${arg#*=}" ;;
    --keep-secrets)   KEEP_SECRETS=true ;;
    --delete-secrets) KEEP_SECRETS=false ;;
    --yes)            ASSUME_YES=true ;;
    --help|-h)        usage; exit 0 ;;
    *)                echo "未知参数: ${arg}" >&2; usage; exit 1 ;;
  esac
done
export ASSUME_YES

require_commands gcloud terraform

select_project "${PROJECT_FLAG}"
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)" 2>/dev/null || true)
FN_SA="${SERVICE_ACCOUNT_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
BUCKET_NAME="${PROJECT_ID}-gcp-feishu-tfstate"

# 防止误在 gcloud 部署的环境上执行：若 topic 存在但没有 managed-by=terraform 标签，拒绝执行。
# （若 topic 已在此前中断的 destroy 中被删掉，describe 失败，允许继续重跑收尾）
if gcloud pubsub topics describe "${TOPIC_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  detect_deploy_mode
  if [[ "${DEPLOY_MODE}" != "terraform" ]]; then
    log_error "topic ${TOPIC_NAME} 未带 managed-by=terraform 标签：这是 gcloud 路径部署的环境"
    echo "   本脚本只清理 Terraform 路径的资源。请改用：./scripts/teardown-gcloud.sh --project=${PROJECT_ID}" >&2
    exit 1
  fi
fi

# 防止本机残留的其它项目 terraform.tfvars 被 Terraform 自动加载造成跨项目污染
TFVARS_PROJECT="$(_tfvar project_id)"
if [[ -n "${TFVARS_PROJECT}" && "${TFVARS_PROJECT}" != "${PROJECT_ID}" ]]; then
  log_error "本机 terraform/terraform.tfvars 记录的项目 (${TFVARS_PROJECT}) 与目标项目 (${PROJECT_ID}) 不一致"
  echo "   为防止加载错误的变量文件，请先移走或备份 terraform/terraform.tfvars 后重试。" >&2
  exit 1
fi

echo "==== Terraform 基础设施清理 ===="
echo "项目 ID: ${PROJECT_ID} / 区域: ${REGION}"
log_warn "此操作不可逆。Terraform 管理的所有资源及 DLQ 中未重放的消息将被销毁。"
echo ""
if [[ "${ASSUME_YES}" != "true" ]]; then
  read -rp "确认销毁？请输入项目 ID 以继续: " CONFIRM
  [[ "${CONFIRM}" == "${PROJECT_ID}" ]] || { echo "输入不匹配，操作已取消"; exit 0; }
fi

# 当本机无 terraform.tfvars（例如全新 Cloud Shell 克隆）时，从线上函数读取渠道名，
# 避免 data.google_secret_manager_secret 按默认 feishu 刷新不存在的 Secret 导致 404。
TF_DESTROY_ARGS=(
  "-var=project_id=${PROJECT_ID}"
  "-var=region=${REGION}"
)
if [[ ! -f terraform/terraform.tfvars ]]; then
  load_live_function_config "${REGION}" || true
  TF_DESTROY_ARGS+=("-var=notify_channel=${LIVE_NOTIFY_CHANNEL:-feishu}")
fi

# 确保 backend.tf 指向当前项目
cat > terraform/backend.tf <<EOF
terraform {
  backend "gcs" {
    bucket = "${BUCKET_NAME}"
    prefix = "terraform/state"
  }
}
EOF

pushd terraform >/dev/null
terraform init -reconfigure

echo "执行 terraform destroy..."
if [[ "${ASSUME_YES}" == "true" ]]; then
  terraform destroy -input=false -auto-approve "${TF_DESTROY_ARGS[@]}"
else
  terraform destroy "${TF_DESTROY_ARGS[@]}"
fi
popd >/dev/null

log_ok "Terraform 资源清理完成"

# 回收 Secret 凭据与 IAM 绑定（与 teardown-gcloud.sh 保持逻辑对等）
EXISTING_CHANNEL_SECRETS=()
for secret in "${ALL_CHANNEL_SECRET_NAMES[@]}"; do
  if gcloud secrets describe "${secret}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    EXISTING_CHANNEL_SECRETS+=("${secret}")
  fi
done

SECRET_MEMBERS=("serviceAccount:${FN_SA}")
[[ -n "${PROJECT_NUMBER}" ]] && \
  SECRET_MEMBERS+=("serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com")

for secret in ${EXISTING_CHANNEL_SECRETS[@]+"${EXISTING_CHANNEL_SECRETS[@]}"}; do
  for member in "${SECRET_MEMBERS[@]}"; do
    gcloud secrets remove-iam-policy-binding "${secret}" \
      --project="${PROJECT_ID}" \
      --member="${member}" \
      --role="roles/secretmanager.secretAccessor" --condition=None >/dev/null 2>&1 || true
  done
done

if [[ "${KEEP_SECRETS}" == "true" ]]; then
  log_info "Secret 已保留（--keep-secrets）"
else
  echo "删除 Secret（飞书 / 企业微信 / 钉钉，存在才删）..."
  if (( ${#EXISTING_CHANNEL_SECRETS[@]} == 0 )); then
    log_info "未发现本仓库的渠道 Secret，跳过"
  fi
  for secret in ${EXISTING_CHANNEL_SECRETS[@]+"${EXISTING_CHANNEL_SECRETS[@]}"}; do
    if gcloud secrets delete "${secret}" --project="${PROJECT_ID}" --quiet 2>/dev/null; then
      log_info "已删除 Secret ${secret}"
    else
      log_warn "删除 Secret ${secret} 失败（权限不足？），请手工确认：gcloud secrets delete ${secret} --project=${PROJECT_ID}"
    fi
  done
fi

echo ""
log_ok "清理完成（项目 ${PROJECT_ID}${PROJECT_NUMBER:+ / 编号 ${PROJECT_NUMBER}}）"
echo "   Terraform state bucket gs://${BUCKET_NAME} 已保留（如需销毁请手工执行 gcloud storage rm -r gs://${BUCKET_NAME}）"
