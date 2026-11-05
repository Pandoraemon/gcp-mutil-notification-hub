#!/bin/bash
# 紧急禁用告警转发。
#
# 采用【软开关】而非删除订阅（ADR-005）：Eventarc 托管订阅名形如
# eventarc-asia-east1-gcp-alerts-to-feishu-sub-<hash>，删除它会破坏触发器，
# 且 emergency-enable.sh 无法重建出等价的托管订阅。翻转环境变量则秒级生效、完全可逆、
# 不触碰任何基础设施。
set -euo pipefail

cd "$(dirname "$0")/.."
source lib/common.sh

REGION="${REGION:-asia-east1}"
MODE="kill"
ASSUME_YES=false
PROJECT_FLAG=""

usage() {
  cat <<'USAGE'
用法: ./scripts/emergency-disable.sh [选项]
  --pause           暂停模式：消息堆积在订阅中，恢复后自动重投（用于 IM 平台侧故障：飞书 / 企业微信 / 钉钉）
  --project=ID      函数所在项目（不传则交互式选择）
  --region=REGION   函数所在区域（默认 asia-east1，亦可用 REGION 环境变量）
  --yes             跳过确认提示
  --help, -h        显示此帮助

两种禁用模式:
  默认（KILL_SWITCH）  函数直接 ack 丢弃全部消息。~30 秒生效。
                       禁用期间的告警【不会堆积、不可找回】。
                       适用：告警风暴刷屏，且不需要补发。
  --pause（PAUSE_MODE）函数对所有消息抛 TransientError，利用 Pub/Sub 重试堆积消息。
                       消息保留在订阅中（默认 7 天），恢复后自动重投。
                       适用：IM 平台（飞书 / 企业微信 / 钉钉）侧故障，恢复后需要补发。
                       注意：堆积超过 max_delivery_attempts=5 的消息会转入 DLQ，
                       需配合 ./scripts/replay-dlq.sh 找回；暂停时间较长时应先临时调大该值。

恢复: ./scripts/emergency-enable.sh
USAGE
}

for arg in "$@"; do
  case "${arg}" in
    --pause)    MODE="pause" ;;
    --project=*) PROJECT_FLAG="${arg#*=}" ;;
    --region=*) REGION="${arg#*=}" ;;
    --yes)      ASSUME_YES=true ;;
    --help|-h)  usage; exit 0 ;;
    *)          echo "未知参数: ${arg}" >&2; usage; exit 1 ;;
  esac
done
export ASSUME_YES

require_commands gcloud

select_project "${PROJECT_FLAG}"

# 必须让操作者知道开关的生命周期：它改的是底层 Cloud Run 服务的环境变量，
# 而 Gen2 函数的配置真相源是 Cloud Functions API —— 下一次 ./deploy-gcloud.sh（--set-env-vars
# 整体替换）或 terraform apply（function.tf 全量拥有 env）都会把它复位成 false，且不会有任何提示。
log_warn "本操作直接修改 Cloud Run 服务 ${FUNCTION_NAME} 的环境变量；"
echo "    下一次 ./deploy-gcloud.sh 或 terraform apply 会把该开关复位（恢复转发），请勿把它当成持久配置。" >&2
echo "" >&2

if [[ "${MODE}" == "pause" ]]; then
  echo "⏸  暂停告警转发（消息保留）"
  echo "   机制：置 PAUSE_MODE=true，函数 nack 所有消息，由 Pub/Sub 重试堆积"
  echo "   影响：恢复后自动重投；超过 5 次投递的消息会转入 DLQ，需用 replay-dlq.sh 找回"
  ENV_UPDATE="PAUSE_MODE=true"
else
  echo "⚠️  紧急禁用告警转发"
  echo "   机制：置 KILL_SWITCH=true，函数将直接丢弃（ack）所有消息"
  echo "   影响：禁用期间的告警【不会堆积、不可找回】"
  echo "   若需保留消息以便事后重放，请改用 --pause 模式（见 --help）"
  ENV_UPDATE="KILL_SWITCH=true"
fi
echo ""

if [[ "${ASSUME_YES}" != "true" ]]; then
  read -rp "确认继续？(yes/NO): " CONFIRM
  [[ "${CONFIRM}" == "yes" ]] || { echo "操作已取消"; exit 0; }
fi

# Gen2 函数的底座就是同名 Cloud Run 服务，直接改它的环境变量。
#
# 不能用 `gcloud functions deploy --update-env-vars`：该命令会把 --source
# 默认成【当前目录】。本仓库根目录没有 main.py（源码在 src/），于是急停
# 命令直接失败 —— 而横幅已经打印完了，看起来像是生效了。实测报错：
#   Invalid value for [--source]: Provided source directory does not have
#   file [main.py] which is required for [python312]
# 更危险的是反面情形：当前目录若恰好存在一个 main.py，急停操作会【静默地】
# 把一份不相干的代码部署到线上。
#
# run services update 还顺带解决了时效问题：deploy 要重新构建（3-5 分钟），
# 而急停承诺的是 30 秒内生效 —— 告警风暴时这个差别是决定性的。
gcloud run services update "${FUNCTION_NAME}" \
  --region="${REGION}" \
  --update-env-vars="${ENV_UPDATE}"

echo ""
log_ok "已生效：${ENV_UPDATE}（约 30 秒内所有实例完成滚动更新）"
echo "   恢复服务: ./scripts/emergency-enable.sh --project=${PROJECT_ID} --region=${REGION}"
