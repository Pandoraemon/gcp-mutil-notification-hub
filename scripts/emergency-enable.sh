#!/bin/bash
# 恢复告警转发：同时清掉 KILL_SWITCH 与 PAUSE_MODE。
#
# 两个开关一起复位，避免"disable 用了 --pause、enable 只清了 KILL_SWITCH"
# 导致函数看起来恢复了、实际仍在 nack 所有消息。
set -euo pipefail

cd "$(dirname "$0")/.."
source lib/common.sh

REGION="${REGION:-asia-east1}"
PROJECT_FLAG=""

usage() {
  cat <<'USAGE'
用法: ./scripts/emergency-enable.sh [选项]
  --project=ID      函数所在项目（不传则交互式选择）
  --region=REGION   函数所在区域（默认 asia-east1，亦可用 REGION 环境变量）
  --help, -h        显示此帮助

作用: 置 KILL_SWITCH=false 与 PAUSE_MODE=false，恢复正常转发（~30 秒生效）。
      若此前处于 --pause 模式，堆积在订阅中的消息会自动重投；
      已转入 DLQ 的消息需用 ./scripts/replay-dlq.sh 找回。
USAGE
}

for arg in "$@"; do
  case "${arg}" in
    --project=*) PROJECT_FLAG="${arg#*=}" ;;
    --region=*) REGION="${arg#*=}" ;;
    --help|-h)  usage; exit 0 ;;
    *)          echo "未知参数: ${arg}" >&2; usage; exit 1 ;;
  esac
done

require_commands gcloud

select_project "${PROJECT_FLAG}"

# 与 emergency-disable.sh 同理：这里改的是底层 Cloud Run 服务的环境变量，
# 下一次 ./deploy-gcloud.sh 或 terraform apply 会按部署配置整体重写（当前默认两开关均为 false）。
log_warn "本操作直接修改 Cloud Run 服务 ${FUNCTION_NAME} 的环境变量；"
echo "    下一次 ./deploy-gcloud.sh 或 terraform apply 会按部署配置复位这些开关。" >&2
echo "" >&2

echo "恢复告警转发..."
# 与 emergency-disable.sh 同理：必须走 Cloud Run 服务更新，不能用
# `gcloud functions deploy --update-env-vars`（--source 会默认成当前目录而报错）。
# 这一侧出问题更致命：急停停下来了却恢复不回去，等于把告警链路永久关停。
gcloud run services update "${FUNCTION_NAME}" \
  --region="${REGION}" \
  --update-env-vars="KILL_SWITCH=false,PAUSE_MODE=false"

echo ""
log_ok "告警转发已恢复（约 30 秒内所有实例完成滚动更新）"
echo "   验证连通性: gcloud pubsub topics publish ${TOPIC_NAME} --project=${PROJECT_ID} \\"
echo "     --message='{\"type\":\"test_event\",\"project_id\":\"${PROJECT_ID}\",\"deployment_time\":\"'\"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\"'\"}'"
echo "   检查 DLQ 中是否有待重放消息: ./scripts/replay-dlq.sh --project=${PROJECT_ID}"
