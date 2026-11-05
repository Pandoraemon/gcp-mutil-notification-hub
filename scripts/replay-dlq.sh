#!/bin/bash
# DLQ 消息重放：把死信队列中的消息重新投回主 topic。
#
# 三个必须注意的点（每一个都会让重放静默失败或损坏消息）：
#   1. .message.data 是 base64，gcloud publish 会【再编码一次】，必须先解码；
#   2. --attribute 是字典型 flag，重复传递会互相覆盖，只有最后一个生效；
#   3. 必须先 publish 成功再 ACK，否则失败时消息既没重放也没留在 DLQ。
set -euo pipefail

cd "$(dirname "$0")/.."
source lib/common.sh

LIMIT="${LIMIT:-10}"
ASSUME_YES=false
PROJECT_FLAG=""
MAIN_TOPIC="${TOPIC_NAME}"

usage() {
  cat <<'USAGE'
用法: ./scripts/replay-dlq.sh [选项]
  --project=ID  DLQ 所在项目（不传则交互式选择）
  --limit=N   单次拉取并重放的最多消息条数（默认 10，亦可用 LIMIT 环境变量）
  --yes       跳过确认提示（谨慎：会直接重放拉到的全部消息）
  --help, -h  显示此帮助

行为:
  1. 若函数最近 10 分钟仍有 ERROR 日志，先警告（重放只会让消息立刻再次进 DLQ）；
  2. 拉取 DLQ 消息并列表展示（此时不 ACK）；
  3. 确认后逐条重放到主 topic，publish 成功才 ACK；
  4. 重放消息带 replayed=true 与递增的 replay_count 属性，
     函数侧在 replay_count > MAX_REPLAY_COUNT(2) 时直接丢弃，避免无限重放循环。
USAGE
}

for arg in "$@"; do
  case "${arg}" in
    --project=*) PROJECT_FLAG="${arg#*=}" ;;
    --limit=*) LIMIT="${arg#*=}" ;;
    --yes)     ASSUME_YES=true ;;
    --help|-h) usage; exit 0 ;;
    *)         echo "未知参数: ${arg}" >&2; usage; exit 1 ;;
  esac
done
export ASSUME_YES

require_commands gcloud jq base64

select_project "${PROJECT_FLAG}"

echo "==== DLQ 消息重放工具 ===="
echo ""

# 0. 前置检查：若函数仍在失败，重放只会让消息立刻再次进入 DLQ
#    `|| true`：缺 logging.viewer 时不该让 set -e 在这里无声退出 —— 查不到就当作"无法判断"继续
RECENT_ERRORS=$(gcloud logging read \
  "resource.labels.service_name=\"${FUNCTION_NAME}\" AND severity>=ERROR" \
  --freshness=10m --limit=1 --format='value(timestamp)' 2>/dev/null || true)
if [[ -n "${RECENT_ERRORS}" ]]; then
  log_warn "函数在最近 10 分钟内仍有 ERROR 日志（${RECENT_ERRORS}）。"
  echo "    建议先修复根因再重放，否则消息会立刻回到 DLQ。"
  if [[ "${ASSUME_YES}" != "true" ]]; then
    read -rp "仍要继续？(yes/NO): " GO; [[ "${GO}" == "yes" ]] || exit 0
  fi
fi

# 1. 预览（不 ACK，并立刻归还租约）
#
# 不能拿着【确认前】pull 到的 ackId 去 ack：pull 会给消息上租约并启动 ack deadline
# （gcloud 路径的 DLQ 订阅默认 10 秒），用户看列表、想一想、再输入 yes 早已超时 ——
# 过期 ackId 的 ack 不保证生效，消息会留在 DLQ 被下一次重放再投一遍（重复投递）。
# 做法：预览 pull 后马上 modify-ack-deadline=0 把消息还回去（等价 nack，立即可再投递），
# 确认后【重新 pull】拿新鲜的 ackId，拉到就 publish + ack，把租约窗口压到最短。
if ! gcloud pubsub subscriptions describe "${DLQ_SUBSCRIPTION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  die "DLQ 订阅 ${DLQ_SUBSCRIPTION} 不存在或无权访问（需 roles/pubsub.subscriber）"
fi
echo "正在预览 DLQ 消息（最多 ${LIMIT} 条，不取走）..."
PREVIEW=$(gcloud pubsub subscriptions pull "${DLQ_SUBSCRIPTION}" \
  --limit="${LIMIT}" --format=json --project="${PROJECT_ID}")
if [[ -z "${PREVIEW}" || "${PREVIEW}" == "[]" ]]; then
  log_ok "DLQ 为空，无需重放"
  exit 0
fi
# 立即归还租约。失败也不致命（10 秒后自然过期），只提示一下
PREVIEW_ACK_IDS=$(jq -r '[.[].ackId] | join(",")' <<<"${PREVIEW}")
gcloud pubsub subscriptions modify-ack-deadline "${DLQ_SUBSCRIPTION}" \
  --ack-ids="${PREVIEW_ACK_IDS}" --ack-deadline=0 --project="${PROJECT_ID}" >/dev/null 2>&1 \
  || log_warn "预览租约未能立即归还，确认后若拉到的消息变少，请等约 10 秒再重跑"

echo ""
printf '%-24s %-26s %s\n' "MESSAGE_ID" "PUBLISH_TIME" "SOURCE"
jq -r '.[] | [.message.messageId, .message.publishTime,
              (.message.attributes.source // "unknown")] | @tsv' <<<"${PREVIEW}" |
  while IFS=$'\t' read -r id t src; do printf '%-24s %-26s %s\n' "$id" "$t" "$src"; done
echo ""
echo "（以上为预览；确认后会重新拉取最多 ${LIMIT} 条，实际重放集合以重新拉取为准）"
if [[ "${ASSUME_YES}" != "true" ]]; then
  read -rp "是否重放到 ${MAIN_TOPIC}？(yes/NO): " CONFIRM
  [[ "${CONFIRM}" == "yes" ]] || { echo "操作已取消（未取走任何消息）"; exit 0; }
fi

# 2. 正式拉取（确认之后才做，拿新鲜的 ackId）
echo "正在拉取 DLQ 消息（最多 ${LIMIT} 条）..."
MESSAGES=$(gcloud pubsub subscriptions pull "${DLQ_SUBSCRIPTION}" \
  --limit="${LIMIT}" --format=json --project="${PROJECT_ID}")

if [[ -z "${MESSAGES}" || "${MESSAGES}" == "[]" ]]; then
  log_warn "重新拉取为空：预览的消息可能仍在租约期内，请等约 10 秒后重跑"
  exit 0
fi

# 3. 重放
echo ""
REPLAYED=0; FAILED=0
# 字段顺序有讲究：IFS=$'\t' 下连续的制表符会被折叠成一个分隔符，
# 因此可能为空的 attrs 必须放在最后一列，否则无属性的消息会让后面的列串位。
while IFS=$'\t' read -r ack_id msg_id data_b64 prev_count attrs; do
  # gcloud publish 会自行 base64 编码，因此必须先解码回原始 JSON。
  #
  # 坑：`--format=json` 输出的是 base64【url】变体（用 -_ 而非 +/），
  # 直接喂给 base64 -d 会报 "base64: invalid input" —— 而且只在消息内容
  # 恰好编码出 - 或 _ 时才触发，短消息测不出来，看起来像是偶发。
  # 先转回标准字母表：标准 base64 里不含 - 和 _，故此 tr 对两种编码都安全。
  #
  # 另一个坑：别改用 `--format='value(message.data)'` 绕开解码 —— 那个投影
  # 返回的是【已解码的明文】，而告警 JSON 自带换行，会把按行读取的循环冲垮。
  data=$(tr '_-' '/+' <<<"${data_b64}" | base64 -d)

  # --attribute 是字典型 flag：必须拼成单个 k=v,k=v，不能重复传递。
  # replay_count 递增，函数侧据此在超过阈值时丢弃，防止 DLQ→重放→再入 DLQ 的死循环。
  next_count=$(( ${prev_count:-0} + 1 ))
  attrs=$(sed -E 's/(^|,)(replayed|replay_count|replay_time)=[^,]*//g' <<<"${attrs}")
  attrs="${attrs#,}"
  attrs="${attrs:+${attrs},}replayed=true,replay_count=${next_count},replay_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if gcloud pubsub topics publish "${MAIN_TOPIC}" \
       --message="${data}" --attribute="${attrs}" >/dev/null; then
    # 仅在 publish 成功后才 ACK，保证"至少一次"而非"至多一次"
    gcloud pubsub subscriptions ack "${DLQ_SUBSCRIPTION}" --ack-ids="${ack_id}"
    echo "  ✅ 已重放 ${msg_id}（replay_count=${next_count}）"
    (( ++REPLAYED ))
  else
    echo "  ❌ 重放失败 ${msg_id}（未 ACK，消息保留在 DLQ 中）" >&2
    (( ++FAILED ))
  fi
done < <(jq -r '.[] | [.ackId, .message.messageId, .message.data,
                       (.message.attributes.replay_count // "0"),
                       ((.message.attributes // {}) | to_entries
                        | map("\(.key)=\(.value)") | join(","))] | @tsv' <<<"${MESSAGES}")

echo ""
log_ok "重放完成：成功 ${REPLAYED} 条，失败 ${FAILED} 条"
[[ ${FAILED} -eq 0 ]] || exit 1
