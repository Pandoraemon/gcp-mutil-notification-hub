#!/bin/bash
# 配置修改向导：读取线上现状 → 分区逐项引导 → 展示差异 → 确认 → 交给部署脚本应用并重启生效。
#
# 设计约束：
#   - 本脚本【不】自己创建 / 修改任何资源。所有变更以环境变量形式交给
#     ./deploy-gcloud.sh --yes 或 ./deploy-terraform.sh --yes 执行（两条路径对等、幂等、
#     自带新 revision 与连通性自检）。也不用 `gcloud run services update` 改底层服务 ——
#     那会在下一次部署时被复位。
#   - 唯一的例外是 gcloud 模式下的「开 → 关」：部署脚本只 upsert 不删除，所以由本脚本在
#     部署【之后】调用 lib/common.sh 的精确删除函数（与 teardown 同一份实现）。
#     Terraform 模式下由 tfvars 的 enable_* / ops_email 控制，apply 自然删除。
#   - 凭据只经环境变量传给子进程：不写临时文件、不进 argv、不打印（webhook 只显示打码前缀）。
set -euo pipefail

cd "$(dirname "$0")/.."
source lib/common.sh

REGION="${REGION:-asia-east1}"
ASSUME_YES=false
DRY_RUN=false
PROJECT_FLAG=""
SECTIONS_ARG=""
ALL_SECTIONS=(channel filter rate policies sources switches source-filter hub)

usage() {
  cat <<'USAGE'
用法: ./scripts/configure.sh [选项]
  重新引导修改已部署环境的全部配置，确认后调用部署脚本应用，并强制函数拉新 revision（重启生效）。

  --project=ID        目标项目（不传则交互式选择，规则同部署脚本）
  --region=REGION     函数所在区域（默认 asia-east1）
  --section=LIST      只走指定分区（逗号分隔），其余保持现值：
                        channel       ① 通知渠道与凭据
                        filter        ② 告警过滤与日志（MIN_SEVERITY / LOG_LEVEL）
                        rate          ③ 发送速率与实例（MAX_SENDS_PER_MINUTE / MAX_INSTANCES）
                        policies      ④ 告警策略（ENABLE_PSH / ENABLE_DEFAULT_ALERTS / OPS_EMAIL）
                        sources       ⑤ 可选数据源（ENABLE_BILLING + BUDGET_AMOUNT / ENABLE_SCC）
                        switches      ⑥ 运行开关（KILL_SWITCH / PAUSE_MODE）
                        source-filter ⑦ 按来源过滤（SOURCE_MIN_SEVERITY）
  --dry-run           只展示「当前值 → 新值」差异，不执行任何写操作
  --yes               非交互：各项取环境变量，未提供则保持现值（未选分区的环境变量被忽略）
  --help, -h          显示此帮助

非交互（--yes）可用的环境变量:
  NOTIFY_CHANNEL                   feishu | wecom | dingtalk（变更渠道时必须同时提供新渠道凭据）
  FEISHU_WEBHOOK / FEISHU_SECRET   提供即视为「输入新凭据」；不提供 = 保持现有凭据
  WECOM_WEBHOOK
  DINGTALK_WEBHOOK / DINGTALK_SECRET
  MIN_SEVERITY / LOG_LEVEL
  SOURCE_MIN_SEVERITY              按来源最低转发级别，如 monitoring=HIGH;billing=OFF
  MAX_SENDS_PER_MINUTE / MAX_INSTANCES
  ENABLE_PSH / ENABLE_DEFAULT_ALERTS   y | n
  OPS_EMAIL                        设为空字符串（OPS_EMAIL=）= 关闭自监控
  ENABLE_BILLING / BUDGET_AMOUNT   y | n；金额如 100 或 100USD
  ENABLE_SCC                       y | n
  KILL_SWITCH / PAUSE_MODE         true | false

说明:
  部署模式自动识别：topic 带 managed-by=terraform 标签 → ./deploy-terraform.sh，否则 ./deploy-gcloud.sh。
  无任何变化时仍可选择强制重启（拉新 revision，使 Secret 的 latest 版本被重新解析）。
USAGE
}

for arg in "$@"; do
  case "${arg}" in
    --project=*) PROJECT_FLAG="${arg#*=}" ;;
    --region=*)  REGION="${arg#*=}" ;;
    --section=*) SECTIONS_ARG="${arg#*=}" ;;
    --dry-run)   DRY_RUN=true ;;
    --yes)       ASSUME_YES=true ;;
    --help|-h)   usage; exit 0 ;;
    *)           echo "未知参数: ${arg}" >&2; usage; exit 1 ;;
  esac
done
export ASSUME_YES

PENDING_BIND=()
PENDING_UNBIND=()

SELECTED_SECTIONS=()
if [[ -z "${SECTIONS_ARG}" ]]; then
  SELECTED_SECTIONS=("${ALL_SECTIONS[@]}")
else
  IFS=',' read -r -a _secs <<<"${SECTIONS_ARG}"
  for _s in "${_secs[@]}"; do
    _s="${_s//[[:space:]]/}"
    [[ -n "${_s}" ]] || continue
    _in_list "${_s}" "${ALL_SECTIONS[@]}" || die "未知分区: ${_s}（可选: ${ALL_SECTIONS[*]}）"
    SELECTED_SECTIONS+=("${_s}")
  done
  (( ${#SELECTED_SECTIONS[@]} > 0 )) || die "--section 不能为空"
fi
section_on() { _in_list "$1" "${SELECTED_SECTIONS[@]}"; }

require_commands gcloud python3

# ---------------------------------------------------------------------------
# 交互输入小工具（回车 = 默认值 = 当前值）
# ---------------------------------------------------------------------------
_read() {  # _read 变量名 提示（局部变量名刻意加前缀，避免与调用方传入的变量名同名而被 local 遮蔽）
  local _read_target=$1 _read_prompt=$2 _read_answer=""
  if ! read -rp "${_read_prompt}" _read_answer; then _read_answer=""; fi
  printf -v "${_read_target}" '%s' "${_read_answer}"
}
ask_choice() {  # ask_choice 变量名 提示 默认值 合法值...
  local __v=$1 __p=$2 __d=$3; shift 3
  local __a __try
  for __try in 1 2 3; do
    _read __a "${__p} [${__d}]: "
    __a="$(tr '[:lower:]' '[:upper:]' <<<"${__a:-${__d}}")"
    if _in_list "${__a}" "$@"; then printf -v "${__v}" '%s' "${__a}"; return 0; fi
    log_warn "无效输入「${__a}」，可选：$*"
  done
  die "连续 3 次输入无效，已取消（未做任何修改）"
}
ask_yn() {  # ask_yn 变量名 提示 默认(Y|N|空=必须作答)
  local __v=$1 __p=$2 __d=$3 __a __n __try __hint
  case "${__d}" in Y) __hint="Y/n" ;; N) __hint="y/N" ;; *) __hint="y/n，必须作答" ;; esac
  for __try in 1 2 3; do
    _read __a "${__p} (${__hint}): "
    __a="${__a:-${__d}}"
    if __n=$(normalize_yn "${__a}"); then printf -v "${__v}" '%s' "${__n}"; return 0; fi
    log_warn "请输入 y 或 n"
  done
  die "连续 3 次输入无效，已取消（未做任何修改）"
}
ask_bool() {  # ask_bool 变量名 提示 默认(true|false)
  local __v=$1 __p=$2 __d=$3 __a __n __try
  for __try in 1 2 3; do
    _read __a "${__p} (true/false) [${__d}]: "
    if __n=$(normalize_bool "${__a:-${__d}}"); then printf -v "${__v}" '%s' "${__n}"; return 0; fi
    log_warn "请输入 true 或 false"
  done
  die "连续 3 次输入无效，已取消（未做任何修改）"
}

channel_label_of() {
  case "$1" in feishu) echo "飞书" ;; wecom) echo "企业微信" ;; dingtalk) echo "钉钉" ;; *) echo "$1" ;; esac
}
state_label() {
  case "$1" in
    on)      echo "开启" ;;
    off)     echo "关闭" ;;
    partial) echo "部分存在" ;;
    Y)       echo "开启" ;;
    N)       echo "关闭" ;;
    *)       echo "未知" ;;
  esac
}
yn_from_state() {  # on/partial → Y，off → N，unknown → 空
  case "$1" in on|partial) echo Y ;; off) echo N ;; *) echo "" ;; esac
}

# ---------------------------------------------------------------------------
# 1. 项目 / 现状 / 部署模式
# ---------------------------------------------------------------------------
select_project "${PROJECT_FLAG}"
export REGION

echo ""
echo "==== GCP 告警转发 - 配置修改向导 ===="
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "项目 ID: ${PROJECT_ID} / 区域: ${REGION} / 模式: --dry-run（只读，不执行任何写操作）"
else
  echo "项目 ID: ${PROJECT_ID} / 区域: ${REGION}"
fi
echo "读取线上配置..."
load_live_config "${REGION}"

case "${LIVE_FUNCTION_STATE}" in
  present) ;;
  absent)
    log_error "函数 ${FUNCTION_NAME} 在 ${PROJECT_ID} / ${REGION} 中不存在：尚未部署，无配置可修改"
    other=$(gcloud functions list --gen2 --format="value(name)" 2>/dev/null \
      | awk -F/ -v fn="${FUNCTION_NAME}" '$NF==fn{print $4}' | head -3 | tr '\n' ' ' || true)
    if [[ -n "${other// /}" ]]; then
      echo "   在其它区域发现同名函数：${other}—— 请用 --region=<区域> 重跑" >&2
    else
      echo "   请先部署：./deploy-gcloud.sh --project=${PROJECT_ID}（或 ./deploy-terraform.sh）" >&2
    fi
    exit 1 ;;
  *)
    die "无法读取函数 ${FUNCTION_NAME} 的配置（权限不足或 Cloud Functions API 不可用）。
   需要 roles/cloudfunctions.viewer；可先执行：gcloud functions describe ${FUNCTION_NAME} --gen2 --region=${REGION} --project=${PROJECT_ID}" ;;
esac

DEPLOY_SCRIPT="./deploy-gcloud.sh"
[[ "${LIVE_DEPLOY_MODE}" == "terraform" ]] && DEPLOY_SCRIPT="./deploy-terraform.sh"
if [[ "${LIVE_DEPLOY_MODE}" == "terraform" && "${DRY_RUN}" != "true" ]]; then
  require_commands terraform
fi

# Terraform 模式下「未知」的开关不能随便传 N：apply 会把 state 里的资源删掉。
# 先用本机上次部署生成的 terraform/terraform.tfvars 兜底（lib/common.sh apply_tfvars_fallback，部署脚本共用）。
if [[ "${LIVE_DEPLOY_MODE}" == "terraform" ]]; then
  apply_tfvars_fallback
fi

# 本渠道现有 Secret 名：沿用线上挂载的名字（部署时可能用 SECRET_*_NAME 覆盖过）
adopt_live_secret_names() {
  local entry env secret
  IFS=',' read -r -a _entries <<<"${LIVE_SECRET_ENVS}"
  for entry in "${_entries[@]}"; do
    env="${entry%%=*}"; secret="${entry#*=}"; secret="${secret%%:*}"
    [[ -n "${env}" && -n "${secret}" ]] || continue
    case "${env}" in
      FEISHU_DEFAULT_WEBHOOK)   SECRET_WEBHOOK_NAME="${secret}" ;;
      FEISHU_DEFAULT_SECRET)    SECRET_SIGN_NAME="${secret}" ;;
      WECOM_DEFAULT_WEBHOOK)    SECRET_WECOM_WEBHOOK_NAME="${secret}" ;;
      DINGTALK_DEFAULT_WEBHOOK) SECRET_DINGTALK_WEBHOOK_NAME="${secret}" ;;
      DINGTALK_DEFAULT_SECRET)  SECRET_DINGTALK_SIGN_NAME="${secret}" ;;
    esac
  done
  export SECRET_WEBHOOK_NAME SECRET_SIGN_NAME SECRET_WECOM_WEBHOOK_NAME \
         SECRET_DINGTALK_WEBHOOK_NAME SECRET_DINGTALK_SIGN_NAME
}
adopt_live_secret_names

# 现有 webhook 的打码预览（只读 Secret 最新版本到内存，立即打码）。
# 读不到 / 无权限时静默降级为「Secret 名 + 最新版本号与创建时间」（只读元数据，不报错）。
LIVE_WEBHOOK_MASKED="（未知）"
_live_webhook_secret=""
case "${LIVE_NOTIFY_CHANNEL_EFF}" in
  feishu)   _live_webhook_secret="${SECRET_WEBHOOK_NAME}" ;;
  wecom)    _live_webhook_secret="${SECRET_WECOM_WEBHOOK_NAME}" ;;
  dingtalk) _live_webhook_secret="${SECRET_DINGTALK_WEBHOOK_NAME}" ;;
esac
if [[ -n "${_live_webhook_secret}" ]]; then
  _hook_value=$(gcloud secrets versions access latest --secret="${_live_webhook_secret}" 2>/dev/null || true)
  if [[ -n "${_hook_value}" ]]; then
    LIVE_WEBHOOK_MASKED="$(mask_webhook_shell "${_hook_value}")"
  else
    _ver_line=$(gcloud secrets versions list "${_live_webhook_secret}" --sort-by=~createTime --limit=1 \
      --format="value(name.basename(),createTime)" 2>/dev/null | head -1 || true)
    if [[ -n "${_ver_line}" ]]; then
      IFS=$'\t' read -r _ver_no _ver_time <<<"${_ver_line}"
      LIVE_WEBHOOK_MASKED="Secret ${_live_webhook_secret}（最新版本 ${_ver_no:-?}，创建于 ${_ver_time:-?}）"
    else
      LIVE_WEBHOOK_MASKED="Secret ${_live_webhook_secret}（版本信息不可读）"
    fi
    unset _ver_line _ver_no _ver_time
  fi
  unset _hook_value
fi

LIVE_BUDGET_CURRENCY="${LIVE_BUDGET_CURRENCY:-USD}"
live_budget_display() {
  case "${LIVE_BILLING}" in
    on) echo "开启（${LIVE_BUDGET_UNITS:-?} ${LIVE_BUDGET_CURRENCY}/月）" ;;
    *)  state_label "${LIVE_BILLING}" ;;
  esac
}
live_ops_display() {
  case "${LIVE_SELF_MON}" in
    on|partial) echo "${LIVE_OPS_EMAIL:-（收件人未知）}$( [[ "${LIVE_SELF_MON}" == partial ]] && echo "（策略不完整）")" ;;
    off)        echo "关闭" ;;
    *)          echo "未知" ;;
  esac
}

# ---------------------------------------------------------------------------
# 2. 当前配置总览
# ---------------------------------------------------------------------------
# printf 的 %-Ns 按【字节】补齐，中文标签（3 字节 / 2 列宽）会把整列挤歪。
# 改为按显示宽度补齐：wc -L 在 UTF-8 locale 下返回终端列宽（中文计 2）。
_pad() {
  local s=$1 width=$2 dw
  dw=$(printf '%s' "${s}" | LC_ALL=C.UTF-8 wc -L 2>/dev/null || echo "${#s}")
  printf '%s%*s' "${s}" $(( width > dw ? width - dw : 0 )) ''
}
print_row() { printf '  %s %s\n' "$(_pad "$1" 24)" "$2"; }
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━ 当前配置 ━━━━━━━━━━━━━━━━━━━━━━"
print_row "部署模式" "$( [[ "${LIVE_DEPLOY_MODE}" == terraform ]] && echo "Terraform（将调用 ./deploy-terraform.sh）" || echo "gcloud（将调用 ./deploy-gcloud.sh）")"
print_row "函数 revision" "${LIVE_REVISION:-未知}（更新于 ${LIVE_UPDATE_TIME:-未知}）"
print_row "① 通知渠道" "$(channel_label_of "${LIVE_NOTIFY_CHANNEL_EFF}")（NOTIFY_CHANNEL=${LIVE_NOTIFY_CHANNEL_EFF}）"
print_row "   Webhook" "${LIVE_WEBHOOK_MASKED}"
print_row "   Secret 挂载" "$(sed -E 's/=([^:,]+):[^,]*/=\1/g' <<<"${LIVE_SECRET_ENVS:-未知}")"
print_row "② MIN_SEVERITY" "${LIVE_MIN_SEVERITY_EFF}"
print_row "   按来源过滤" "$(source_filter_display "${LIVE_SOURCE_MIN_SEVERITY_EFF:-}")"
print_row "   LOG_LEVEL" "${LIVE_LOG_LEVEL_EFF}"
print_row "③ MAX_SENDS_PER_MINUTE" "${LIVE_MAX_SENDS_PER_MINUTE_EFF}"
print_row "   MAX_INSTANCES" "${LIVE_MAX_INSTANCES_EFF}"
print_row "④ PSH 告警策略" "$(state_label "${LIVE_PSH}")"
print_row "   推荐默认告警包" "$(state_label "${LIVE_DEFAULT_ALERTS}")"
print_row "   自监控邮箱 OPS_EMAIL" "$(live_ops_display)"
print_row "⑤ Billing 预算" "$(live_budget_display)"
print_row "   SCC 导出" "$(state_label "${LIVE_SCC}")${LIVE_SCC_NOTE:+（${LIVE_SCC_NOTE}）}"
print_row "⑥ KILL_SWITCH" "${LIVE_KILL_SWITCH_EFF}"
print_row "   PAUSE_MODE" "${LIVE_PAUSE_MODE_EFF}"
print_row "   CONFIG_REVISION" "${LIVE_CONFIG_REVISION:-（未设置）}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ "${LIVE_KILL_SWITCH_EFF}" == "true" ]]; then
  log_warn "══════ 当前 KILL_SWITCH=true：所有告警正被直接丢弃（不会重投）══════"
fi
if [[ "${LIVE_PAUSE_MODE_EFF}" == "true" ]]; then
  log_warn "══════ 当前 PAUSE_MODE=true：所有告警正在 nack 堆积，超过重试次数会进入 DLQ ══════"
fi

# ---------------------------------------------------------------------------
# 3. 新值初始化 = 现值
# ---------------------------------------------------------------------------
NEW_CHANNEL="${LIVE_NOTIFY_CHANNEL_EFF}"
CRED_ACTION=keep              # keep | new
NEW_MIN_SEVERITY="${LIVE_MIN_SEVERITY_EFF}"
NEW_SOURCE_MIN_SEVERITY="${LIVE_SOURCE_MIN_SEVERITY_EFF:-}"
NEW_LOG_LEVEL="${LIVE_LOG_LEVEL_EFF}"
NEW_RATE="${LIVE_MAX_SENDS_PER_MINUTE_EFF}"
NEW_MAX_INSTANCES="${LIVE_MAX_INSTANCES_EFF}"
RATE_TOUCHED=false
NEW_ENABLE_PSH="$(yn_from_state "${LIVE_PSH}")"
NEW_ENABLE_DEFAULT_ALERTS="$(yn_from_state "${LIVE_DEFAULT_ALERTS}")"
case "${LIVE_SELF_MON}" in
  on|partial) NEW_OPS_EMAIL="${LIVE_OPS_EMAIL}"; OPS_KNOWN=true ;;
  off)        NEW_OPS_EMAIL="";                 OPS_KNOWN=true ;;
  *)          NEW_OPS_EMAIL="";                 OPS_KNOWN=false ;;
esac
# 自监控开着但读不到收件人：保持不变就无法把邮箱传给部署脚本
[[ "${LIVE_SELF_MON}" != "off" && -z "${LIVE_OPS_EMAIL}" ]] && OPS_KNOWN=false
NEW_ENABLE_BILLING="$(yn_from_state "${LIVE_BILLING}")"
NEW_BUDGET_UNITS="${LIVE_BUDGET_UNITS:-100}"
NEW_BUDGET_CURRENCY="${LIVE_BUDGET_CURRENCY}"
NEW_ENABLE_SCC="$(yn_from_state "${LIVE_SCC}")"
NEW_KILL_SWITCH="${LIVE_KILL_SWITCH_EFF}"
NEW_PAUSE_MODE="${LIVE_PAUSE_MODE_EFF}"

INTERACTIVE=true
[[ "${ASSUME_YES}" == "true" ]] && INTERACTIVE=false
MAIN_MENU_LOOP=true
while [[ "${MAIN_MENU_LOOP}" == "true" ]]; do

if [[ -z "${SECTIONS_ARG}" && "${INTERACTIVE}" == "true" ]]; then
  echo ""
  echo "请选择要修改的分区编号（可多选，逗号分隔，如 1,4,5；直接回车 = 依次检查所有分区；0 = 退出）:"
  echo "  1) 通知渠道与凭据"
  echo "  2) 告警过滤与日志"
  echo "  3) 发送速率与实例"
  echo "  4) 告警策略"
  echo "  5) 可选数据源"
  echo "  6) 运行开关"
  echo "  7) 按来源过滤"
  echo "  8) 多项目汇聚（源项目 / 文件夹或组织范围 / 绑定告警策略）"
  __try_menu=""
  for __try_menu in 1 2 3; do
    _read _m_ans "  您的选择 [回车]: "
    _m_ans="${_m_ans//[[:space:]]/}"
    if [[ "${_m_ans}" == "0" ]]; then
      echo "已退出（未做任何修改）"
      exit 0
    elif [[ -z "${_m_ans}" ]]; then
      SELECTED_SECTIONS=("${ALL_SECTIONS[@]}")
      break
    else
      IFS="," read -r -a _m_arr <<<"${_m_ans}"
      SELECTED_SECTIONS=()
      _m_ok=true
      _m_i=""
      for _m_i in "${_m_arr[@]}"; do
        case "${_m_i}" in
          1) SELECTED_SECTIONS+=("channel") ;;
          2) SELECTED_SECTIONS+=("filter") ;;
          3) SELECTED_SECTIONS+=("rate") ;;
          4) SELECTED_SECTIONS+=("policies") ;;
          5) SELECTED_SECTIONS+=("sources") ;;
          6) SELECTED_SECTIONS+=("switches") ;;
          7) SELECTED_SECTIONS+=("source-filter") ;;
          8) SELECTED_SECTIONS+=("hub") ;;
          *) log_warn "无效编号: ${_m_i}"; _m_ok=false ;;
        esac
      done
      if [[ "${_m_ok}" == "true" ]]; then
        break
      fi
    fi
    [[ "${__try_menu}" == 3 ]] && die "连续 3 次输入无效，已退出（未做任何修改）"
  done
fi


section_header() { echo ""; echo "—— $1 ——（回车 = 保持当前值）"; }

# 渠道凭据的环境变量是否提供（--yes 下「提供 = 输入新凭据」）
creds_env_provided() {
  case "$1" in
    feishu)   [[ -n "${FEISHU_WEBHOOK:-}${FEISHU_SECRET:-}" ]] ;;
    wecom)    [[ -n "${WECOM_WEBHOOK:-}" ]] ;;
    dingtalk) [[ -n "${DINGTALK_WEBHOOK:-}${DINGTALK_SECRET:-}" ]] ;;
  esac
}
# 复用 lib/common.sh 的凭据采集与校验（交互 = 掩码输入；--yes = 读环境变量；校验失败即退出）
collect_credentials() {
  case "$1" in
    feishu)   _collect_feishu_credentials ;;
    wecom)    _collect_wecom_credentials ;;
    dingtalk) _collect_dingtalk_credentials ;;
  esac
}
new_webhook_value() {
  case "${NEW_CHANNEL}" in
    feishu) echo "${FEISHU_WEBHOOK:-}" ;; wecom) echo "${WECOM_WEBHOOK:-}" ;; dingtalk) echo "${DINGTALK_WEBHOOK:-}" ;;
  esac
}

# ---------------------------------------------------------------------------
# ① 通知渠道与凭据
# ---------------------------------------------------------------------------
if section_on channel; then
  if [[ "${INTERACTIVE}" == "true" ]]; then
    section_header "① 通知渠道与凭据"
    echo "  当前：$(channel_label_of "${LIVE_NOTIFY_CHANNEL_EFF}")（Webhook ${LIVE_WEBHOOK_MASKED}）"
    echo "  1) 飞书/Lark   2) 企业微信   3) 钉钉"
    case "${LIVE_NOTIFY_CHANNEL_EFF}" in feishu) _d=1 ;; wecom) _d=2 ;; dingtalk) _d=3 ;; esac
    _read _c "  通知渠道 [${_d}]: "
    case "${_c:-${_d}}" in
      1|feishu) NEW_CHANNEL=feishu ;; 2|wecom) NEW_CHANNEL=wecom ;; 3|dingtalk) NEW_CHANNEL=dingtalk ;;
      *) die "无效的渠道编号: ${_c}（应为 1 / 2 / 3）" ;;
    esac
    if [[ "${NEW_CHANNEL}" != "${LIVE_NOTIFY_CHANNEL_EFF}" ]]; then
      log_warn "渠道由 $(channel_label_of "${LIVE_NOTIFY_CHANNEL_EFF}") 变更为 $(channel_label_of "${NEW_CHANNEL}")：必须输入新渠道的凭据"
      CRED_ACTION=new
    else
      _read _k "  凭据：1) 保持现有凭据  2) 输入新凭据 [1]: "
      case "${_k:-1}" in 1) CRED_ACTION=keep ;; 2) CRED_ACTION=new ;; *) die "无效选择: ${_k}" ;; esac
    fi
    if [[ "${CRED_ACTION}" == "new" ]]; then
      # _collect_* 在 ASSUME_YES=false 时用 read（密钥 -s 掩码）采集
      collect_credentials "${NEW_CHANNEL}"
    fi
  else
    NEW_CHANNEL="${NOTIFY_CHANNEL:-${LIVE_NOTIFY_CHANNEL_EFF}}"
    _in_list "${NEW_CHANNEL}" feishu wecom dingtalk || die "NOTIFY_CHANNEL=${NEW_CHANNEL} 无效：只能是 feishu / wecom / dingtalk"
    if [[ "${NEW_CHANNEL}" != "${LIVE_NOTIFY_CHANNEL_EFF}" ]] || creds_env_provided "${NEW_CHANNEL}"; then
      CRED_ACTION=new
      # ASSUME_YES=true：缺少新渠道凭据时这里直接 die（渠道变更必须提供凭据）
      collect_credentials "${NEW_CHANNEL}"
    fi
  fi
fi
CHANNEL_CHANGED=false
[[ "${NEW_CHANNEL}" != "${LIVE_NOTIFY_CHANNEL_EFF}" ]] && CHANNEL_CHANGED=true

# 保持现有凭据：现在就校验 Secret（只读），别等确认之后才在部署脚本里失败
NOTIFY_CHANNEL="${NEW_CHANNEL}"
set_channel_secret_mapping
if [[ "${CRED_ACTION}" == "keep" ]]; then
  verify_channel_secrets_present
fi

# ---------------------------------------------------------------------------
# ② 告警过滤与日志
# ---------------------------------------------------------------------------
if section_on filter; then
  if [[ "${INTERACTIVE}" == "true" ]]; then
    section_header "② 告警过滤与日志"
    ask_choice NEW_MIN_SEVERITY "  MIN_SEVERITY 最低转发级别（CRITICAL/HIGH/MEDIUM/LOW/INFO）" "${NEW_MIN_SEVERITY}" "${VALID_MIN_SEVERITIES[@]}"
    ask_choice NEW_LOG_LEVEL "  LOG_LEVEL 函数日志级别（DEBUG/INFO/WARNING/ERROR）" "${NEW_LOG_LEVEL}" "${VALID_LOG_LEVELS[@]}"
  else
    NEW_MIN_SEVERITY="$(tr '[:lower:]' '[:upper:]' <<<"${MIN_SEVERITY:-${NEW_MIN_SEVERITY}}")"
    NEW_LOG_LEVEL="$(tr '[:lower:]' '[:upper:]' <<<"${LOG_LEVEL:-${NEW_LOG_LEVEL}}")"
    _in_list "${NEW_MIN_SEVERITY}" "${VALID_MIN_SEVERITIES[@]}" || die "MIN_SEVERITY=${NEW_MIN_SEVERITY} 无效：只能是 ${VALID_MIN_SEVERITIES[*]}"
    _in_list "${NEW_LOG_LEVEL}" "${VALID_LOG_LEVELS[@]}" || die "LOG_LEVEL=${NEW_LOG_LEVEL} 无效：只能是 DEBUG / INFO / WARNING / ERROR"
  fi
fi

# ---------------------------------------------------------------------------
# ③ 发送速率与实例（复用 validate_channel_rate_limit；渠道变更时速率默认值切到新渠道）
# ---------------------------------------------------------------------------
NEW_CH_DEFAULT_RATE="$(channel_default_rate "${NEW_CHANNEL}")"
[[ "${CHANNEL_CHANGED}" == "true" ]] && NEW_RATE="${NEW_CH_DEFAULT_RATE}"
check_rate() {  # 子 shell 中调用共享校验，die 只退出子 shell
  ( NOTIFY_CHANNEL="${NEW_CHANNEL}" MAX_SENDS_PER_MINUTE="$1" MAX_INSTANCES="$2"
    CHANNEL_LABEL="$(channel_label_of "${NEW_CHANNEL}")"
    validate_channel_rate_limit >/dev/null )
}
if section_on rate; then
  if [[ "${INTERACTIVE}" == "true" ]]; then
    section_header "③ 发送速率与实例"
    echo "  上限：MAX_SENDS_PER_MINUTE × MAX_INSTANCES ≤ $(channel_rate_cap "${NEW_CHANNEL}")（$(channel_label_of "${NEW_CHANNEL}")默认速率 ${NEW_CH_DEFAULT_RATE}）"
    for _try in 1 2 3; do
      _read _r "  MAX_SENDS_PER_MINUTE [${NEW_RATE}]: "
      _i_default="${NEW_MAX_INSTANCES}"
      _read _i "  MAX_INSTANCES [${_i_default}]: "
      if check_rate "${_r:-${NEW_RATE}}" "${_i:-${_i_default}}"; then
        NEW_RATE="${_r:-${NEW_RATE}}"; NEW_MAX_INSTANCES="${_i:-${_i_default}}"; RATE_TOUCHED=true; break
      fi
      [[ "${_try}" == 3 ]] && die "连续 3 次输入不合规，已取消（未做任何修改）"
    done
  else
    [[ -n "${MAX_SENDS_PER_MINUTE:-}" ]] && { NEW_RATE="${MAX_SENDS_PER_MINUTE}"; RATE_TOUCHED=true; }
    [[ "${MAX_INSTANCES_EXPLICIT}" == "true" ]] && { NEW_MAX_INSTANCES="${MAX_INSTANCES}"; RATE_TOUCHED=true; }
  fi
fi
# 无论是否走了 ③，最终组合都必须合规（例如只改渠道时速率已切到新渠道默认值）
check_rate "${NEW_RATE}" "${NEW_MAX_INSTANCES}" || die "发送速率组合不合规（见上方错误），未做任何修改"

# ---------------------------------------------------------------------------
# ④ 告警策略
# ---------------------------------------------------------------------------
if section_on policies; then
  if [[ "${INTERACTIVE}" == "true" ]]; then
    section_header "④ 告警策略"
    ask_yn NEW_ENABLE_PSH "  部署 PSH（Personalized Service Health）两类官方告警策略？" "${NEW_ENABLE_PSH}"
    ask_yn NEW_ENABLE_DEFAULT_ALERTS "  部署推荐默认监控告警包（GCE/配额/LB&NAT/GKE&SQL/IAM 审计，11 条）？" "${NEW_ENABLE_DEFAULT_ALERTS}"
    _ops_d="${NEW_OPS_EMAIL:-无}"
    [[ "${OPS_KNOWN}" == "true" ]] || _ops_d="未知，回车 = 关闭"
    _read _o "  自监控收件邮箱 OPS_EMAIL（输入 - 关闭自监控）[${_ops_d}]: "
    _o="${_o//[[:space:]]/}"
    if [[ "${_o}" == "-" ]]; then NEW_OPS_EMAIL=""; OPS_KNOWN=true
    elif [[ -n "${_o}" ]]; then NEW_OPS_EMAIL="${_o}"; OPS_KNOWN=true
    elif [[ "${OPS_KNOWN}" != "true" ]]; then NEW_OPS_EMAIL=""; OPS_KNOWN=true
    fi
  else
    if [[ -n "${ENABLE_PSH:-}" ]]; then
      NEW_ENABLE_PSH="$(normalize_yn "${ENABLE_PSH}")" || die "ENABLE_PSH=${ENABLE_PSH} 无效：只能是 y / n"
    fi
    if [[ -n "${ENABLE_DEFAULT_ALERTS:-}" ]]; then
      NEW_ENABLE_DEFAULT_ALERTS="$(normalize_yn "${ENABLE_DEFAULT_ALERTS}")" || die "ENABLE_DEFAULT_ALERTS=${ENABLE_DEFAULT_ALERTS} 无效：只能是 y / n"
    fi
    if [[ -n "${OPS_EMAIL+x}" ]]; then NEW_OPS_EMAIL="${OPS_EMAIL//[[:space:]]/}"; OPS_KNOWN=true; fi
  fi
  if [[ -n "${NEW_OPS_EMAIL}" && ! "${NEW_OPS_EMAIL}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
    die "OPS_EMAIL=${NEW_OPS_EMAIL} 不像邮箱地址，未做任何修改"
  fi
fi

# ---------------------------------------------------------------------------
# ⑤ 可选数据源
# ---------------------------------------------------------------------------
parse_budget() {  # "100" / "100USD" / "100 USD" → NEW_BUDGET_UNITS / NEW_BUDGET_CURRENCY
  local raw="${1//[[:space:]]/}"
  [[ "${raw}" =~ ^([1-9][0-9]{0,9})([A-Za-z]{3})?$ ]] || return 1
  NEW_BUDGET_UNITS="${BASH_REMATCH[1]}"
  [[ -n "${BASH_REMATCH[2]}" ]] && NEW_BUDGET_CURRENCY="$(tr '[:lower:]' '[:upper:]' <<<"${BASH_REMATCH[2]}")"
  return 0
}
if section_on sources; then
  if [[ "${INTERACTIVE}" == "true" ]]; then
    section_header "⑤ 可选数据源"
    [[ "${LIVE_BILLING}" == "unknown" ]] && echo "  （无法读取 Billing 预算现状：缺 billing.viewer 或项目未绑结算账号）"
    ask_yn NEW_ENABLE_BILLING "  启用 Billing 预算告警？" "${NEW_ENABLE_BILLING}"
    if [[ "${NEW_ENABLE_BILLING}" == "Y" ]]; then
      for _try in 1 2 3; do
        _read _b "  月度预算金额（整数，币种 ${NEW_BUDGET_CURRENCY}）[${NEW_BUDGET_UNITS}]: "
        parse_budget "${_b:-${NEW_BUDGET_UNITS}}" && break
        log_warn "金额必须是正整数（可带三位币种，如 100USD）"
        [[ "${_try}" == 3 ]] && die "连续 3 次输入无效，已取消（未做任何修改）"
      done
    fi
    [[ -n "${LIVE_SCC_NOTE}" ]] && echo "  （SCC：${LIVE_SCC_NOTE}）"
    ask_yn NEW_ENABLE_SCC "  启用 SCC 安全中心导出？" "${NEW_ENABLE_SCC}"
  else
    if [[ -n "${ENABLE_BILLING:-}" ]]; then
      NEW_ENABLE_BILLING="$(normalize_yn "${ENABLE_BILLING}")" || die "ENABLE_BILLING=${ENABLE_BILLING} 无效：只能是 y / n"
    fi
    if [[ -n "${BUDGET_AMOUNT:-}" ]]; then
      parse_budget "${BUDGET_AMOUNT}" || die "BUDGET_AMOUNT=${BUDGET_AMOUNT} 无效：应为正整数，可带币种（如 100 或 100USD）"
    fi
    if [[ -n "${ENABLE_SCC:-}" ]]; then
      NEW_ENABLE_SCC="$(normalize_yn "${ENABLE_SCC}")" || die "ENABLE_SCC=${ENABLE_SCC} 无效：只能是 y / n"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# ⑥ 运行开关
# ---------------------------------------------------------------------------
if section_on switches; then
  if [[ "${INTERACTIVE}" == "true" ]]; then
    section_header "⑥ 运行开关"
    [[ "${LIVE_KILL_SWITCH_EFF}" == "true" ]] && log_warn "当前 KILL_SWITCH=true（急停中，告警被丢弃）—— 回车将【保持急停】"
    [[ "${LIVE_PAUSE_MODE_EFF}" == "true" ]] && log_warn "当前 PAUSE_MODE=true（暂停中，告警堆积）—— 回车将【保持暂停】"
    ask_bool NEW_KILL_SWITCH "  KILL_SWITCH 急停（true = 丢弃全部告警）" "${NEW_KILL_SWITCH}"
    ask_bool NEW_PAUSE_MODE "  PAUSE_MODE 暂停（true = nack 堆积，恢复后重投）" "${NEW_PAUSE_MODE}"
  else
    if [[ -n "${KILL_SWITCH:-}" ]]; then
      NEW_KILL_SWITCH="$(normalize_bool "${KILL_SWITCH}")" || die "KILL_SWITCH=${KILL_SWITCH} 无效：只能是 true / false"
    fi
    if [[ -n "${PAUSE_MODE:-}" ]]; then
      NEW_PAUSE_MODE="$(normalize_bool "${PAUSE_MODE}")" || die "PAUSE_MODE=${PAUSE_MODE} 无效：只能是 true / false"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# ⑦ 按来源过滤
# ---------------------------------------------------------------------------
if section_on source-filter; then
  if [[ "${INTERACTIVE}" == "true" ]]; then
    section_header "⑦ 按来源过滤"
    echo "  当前：$(source_filter_display "${NEW_SOURCE_MIN_SEVERITY:-}")"
    _srcs=(monitoring service_health billing scc)
    _labels=("Monitoring" "Service Health(PSH)" "Billing" "SCC")
    declare -a _parsed_pairs
    IFS=";" read -r -a _parsed_pairs <<<"${NEW_SOURCE_MIN_SEVERITY:-}"
    _src="" _lbl="" _cur="" _try="" _a="" _found="" _pair="" _new_val=""
    for ((i=0; i<${#_srcs[@]}; i++)); do
      _src="${_srcs[$i]}"
      _lbl="${_labels[$i]}"
      _cur=""
      for _pair in "${_parsed_pairs[@]}"; do
        if [[ "${_pair%%=*}" == "${_src}" ]]; then
          _cur="${_pair#*=}"
          break
        fi
      done
      echo "  - ${_lbl}（当前：${_cur:-跟随全局}）"
      echo "    回车=保持; 1=跟随全局; 2=关闭(OFF); 3=CRITICAL; 4=HIGH; 5=MEDIUM; 6=LOW; 7=INFO"
      for _try in 1 2 3; do
        _read _a "    请选择 [回车]: "
        if [[ -z "${_a}" ]]; then
          _new_val="${_cur}"
          break
        fi
        case "${_a}" in
          1) _new_val="" ; break ;;
          2|OFF|off) _new_val="OFF" ; break ;;
          3|CRITICAL|critical) _new_val="CRITICAL" ; break ;;
          4|HIGH|high) _new_val="HIGH" ; break ;;
          5|MEDIUM|medium) _new_val="MEDIUM" ; break ;;
          6|LOW|low) _new_val="LOW" ; break ;;
          7|INFO|info) _new_val="INFO" ; break ;;
          *) log_warn "输入无效，请重新选择" ;;
        esac
        [[ "${_try}" == 3 ]] && die "连续 3 次输入无效，已取消（未做任何修改）"
      done
      if [[ "${_new_val}" == "OFF" ]]; then
        if [[ "${_src}" == "service_health" && "${NEW_ENABLE_PSH:-}" != "N" ]]; then
          echo "    （提示：PSH 策略未关闭，仍会产生消息但被函数丢弃；如需彻底关闭请在 ④/⑤ 关闭）"
        elif [[ "${_src}" == "billing" && "${NEW_ENABLE_BILLING:-}" != "N" ]]; then
          echo "    （提示：Billing 预算未关闭，仍会产生消息但被函数丢弃；如需彻底关闭请在 ④/⑤ 关闭）"
        elif [[ "${_src}" == "scc" && "${NEW_ENABLE_SCC:-}" != "N" ]]; then
          echo "    （提示：SCC 导出配置未关闭，仍会产生消息但被函数丢弃；如需彻底关闭请在 ④/⑤ 关闭）"
        fi
      fi
      
      _found=false
      for ((j=0; j<${#_parsed_pairs[@]}; j++)); do
        if [[ "${_parsed_pairs[$j]%%=*}" == "${_src}" ]]; then
          if [[ -z "${_new_val}" ]]; then
            unset '_parsed_pairs[j]'
          else
            _parsed_pairs[$j]="${_src}=${_new_val}"
          fi
          _found=true
          break
        fi
      done
      if [[ "${_found}" == "false" && -n "${_new_val}" ]]; then
        _parsed_pairs+=("${_src}=${_new_val}")
      fi
    done
    
    NEW_SOURCE_MIN_SEVERITY=""
    for _pair in "${_parsed_pairs[@]:-}"; do
      NEW_SOURCE_MIN_SEVERITY+="${NEW_SOURCE_MIN_SEVERITY:+;}${_pair}"
    done
    NEW_SOURCE_MIN_SEVERITY="$(normalize_source_min_severity "${NEW_SOURCE_MIN_SEVERITY}")" || true
  else
    if [[ -n "${SOURCE_MIN_SEVERITY+x}" ]]; then
      if [[ -z "${SOURCE_MIN_SEVERITY}" ]]; then
        NEW_SOURCE_MIN_SEVERITY=""
      else
        NEW_SOURCE_MIN_SEVERITY="$(normalize_source_min_severity "${SOURCE_MIN_SEVERITY}")" || die "SOURCE_MIN_SEVERITY=${SOURCE_MIN_SEVERITY} 格式无效"
      fi
    fi
  fi
fi


# ⑧ 多项目汇聚
# ---------------------------------------------------------------------------
if section_on hub; then
  if [[ "${INTERACTIVE}" == "true" ]]; then
    section_header "⑧ 多项目汇聚（源项目 / 文件夹或组织范围 / 绑定告警策略）"
    NEW_HUB_SOURCE_PROJECTS="${NEW_HUB_SOURCE_PROJECTS-${LIVE_HUB_SOURCE_PROJECTS:-}}"
    NEW_HUB_SCOPE="${NEW_HUB_SCOPE-${LIVE_HUB_SCOPE:-}}"
    # PENDING_BIND / PENDING_UNBIND 只在脚本开头初始化一次：按 m 回主菜单再进 ⑧ 时保留待应用的绑定
    while true; do
      echo "  -------------------------------------------------"
      echo "  【汇聚范围】: ${NEW_HUB_SCOPE:-未设置}"
      echo "  【源项目列表】:"
      if [[ -z "${NEW_HUB_SOURCE_PROJECTS}" ]]; then
        echo "    (空)"
      else
        _i=1
        for _p in $(echo "${NEW_HUB_SOURCE_PROJECTS}" | tr ';' ' '); do
          echo "    ${_i}) ${_p%=*}"
          _i=$((_i+1))
        done
      fi
      echo "  -------------------------------------------------"
      echo "  子菜单: [a] 添加源项目  [r] 移除源项目  [s] 设置/清空范围  [b] 绑定告警策略  [v] 状态体检  [回车] 完成并返回"
      _hub_try=0
      while ((_hub_try < 3)); do
        _read _hub_action "  请选择 (a/r/s/b/v/[回车]): "
        _hub_action="$(tr '[:upper:]' '[:lower:]' <<<"${_hub_action//[[:space:]]/}")"
        case "${_hub_action}" in
          "") break 2 ;;
          a|r|s|b|v) break ;;
          *) log_warn "无效输入"; _hub_try=$((_hub_try+1)) ;;
        esac
      done
      ((_hub_try == 3)) && { echo "连续 3 次非法，返回上一级。"; break; }
      
      case "${_hub_action}" in
        a)
          echo "  当前可添加的 Active 项目（排除 Hub 与已有）："
          _all_active=$(gcloud projects list --format="value(projectId)" --filter="lifecycleState=ACTIVE" 2>/dev/null || true)
          _cand=()
          for _ap in ${_all_active}; do
            if [[ "${_ap}" == "${PROJECT_ID}" ]]; then continue; fi
            if echo "${NEW_HUB_SOURCE_PROJECTS}" | grep -qE "(^|;)${_ap}="; then continue; fi
            _cand+=("${_ap}")
          done
          if (( ${#_cand[@]} == 0 )); then
            echo "  (无)"
            _read _pids "  请输入要添加的项目 ID (逗号分隔): "
          else
            for ((i=0; i<${#_cand[@]}; i++)); do
              echo "    $((i+1))) ${_cand[$i]}"
            done
            _read _add_ans "  请输入项目编号或直接输入项目 ID（逗号分隔）: "
            _pids=""
            IFS="," read -r -a _ans_arr <<<"${_add_ans}"
            for _x in "${_ans_arr[@]}"; do
              _x="${_x//[[:space:]]/}"
              if [[ "${_x}" =~ ^[0-9]+$ ]] && (( _x >= 1 && _x <= ${#_cand[@]} )); then
                _pids+="${_cand[$((_x-1))]},"
              else
                _pids+="${_x},"
              fi
            done
          fi
          _pids="${_pids%,}"
          if [[ -n "${_pids}" ]]; then
            _pids_semi="${_pids//,/;}"
            _combined="${NEW_HUB_SOURCE_PROJECTS}${NEW_HUB_SOURCE_PROJECTS:+;}${_pids_semi}"
            _norm=$(normalize_hub_source_projects "${_combined}" 2>&1) || {
              log_warn "添加失败: ${_norm}"
              continue
            }
            NEW_HUB_SOURCE_PROJECTS="${_norm}"
          fi
          ;;
        r)
          _arr=()
          for _p in $(echo "${NEW_HUB_SOURCE_PROJECTS}" | tr ';' ' '); do
            _arr+=("${_p}")
          done
          if (( ${#_arr[@]} == 0 )); then
            log_warn "列表为空，无可移除项目"
            continue
          fi
          _read _rm_ans "  请输入要移除的项目编号（逗号分隔）: "
          IFS="," read -r -a _ans_arr <<<"${_rm_ans}"
          _keep=()
          for ((i=0; i<${#_arr[@]}; i++)); do
            _match=false
            for _x in "${_ans_arr[@]}"; do
              _x="${_x//[[:space:]]/}"
              if [[ "${_x}" == "$((i+1))" ]]; then _match=true; break; fi
            done
            if [[ "${_match}" == "false" ]]; then _keep+=("${_arr[$i]}"); fi
          done
          _new_val=""
          for _k in "${_keep[@]}"; do
            _new_val+="${_new_val:+;}${_k}"
          done
          NEW_HUB_SOURCE_PROJECTS="${_new_val}"
          ;;
        s)
          _read _scp "  请输入范围 (如 folders/123 或 organizations/456，输入 - 清空) [回车保持]: "
          _scp="${_scp//[[:space:]]/}"
          if [[ "${_scp}" == "-" ]]; then
            NEW_HUB_SCOPE=""
          elif [[ -n "${_scp}" ]]; then
            normalize_hub_scope "${_scp}" >/dev/null || {
              log_warn "范围格式非法: ${_scp} (应为 folders/xxx 或 organizations/xxx)"
              continue
            }
            NEW_HUB_SCOPE="${_scp}"
            echo "  正在查询该范围内的所有 Active 项目..."
            _scope_projs=$(list_scope_projects "${_scp}" 2>/dev/null || true)
            if [[ -n "${_scope_projs}" ]]; then
              echo "  查到以下项目："
              echo "${_scope_projs}" | awk -F= '{print "    - "$1}'
              _read _add_all "  全部加入源项目？(y/N): "
              if [[ "${_add_all}" =~ ^[Yy] ]]; then
                _pids_semi=$(echo "${_scope_projs}" | tr '\n' ';' | sed 's/;$//')
                _combined="${NEW_HUB_SOURCE_PROJECTS}${NEW_HUB_SOURCE_PROJECTS:+;}${_pids_semi}"
                if _norm=$(normalize_hub_source_projects "${_combined}" 2>&1); then
                  NEW_HUB_SOURCE_PROJECTS="${_norm}"
                else
                  log_warn "添加失败: ${_norm}"
                fi
              fi
            else
              echo "  (该范围下未找到项目或无权限)"
            fi
          fi
          ;;
        b)
          # Bind policies
          echo "  当前线上的源项目 (仅可选择线上已存在且配置完毕的): "
          _live_arr=()
          for _p in $(echo "${LIVE_HUB_SOURCE_PROJECTS:-}" | tr ';' ' '); do
            _live_arr+=("${_p%=*}")
          done
          if (( ${#_live_arr[@]} == 0 )); then
            echo "  (无已部署的源项目。请先应用新增项目后再绑定。)"
            continue
          fi
          for ((i=0; i<${#_live_arr[@]}; i++)); do
            echo "    $((i+1))) ${_live_arr[$i]}"
          done
          _read _bp "  请选择项目编号: "
          if [[ ! "${_bp}" =~ ^[0-9]+$ ]] || (( _bp < 1 || _bp > ${#_live_arr[@]} )); then
            log_warn "无效编号"
            continue
          fi
          _sel_proj="${_live_arr[$((_bp-1))]}"
          echo "  查询项目 ${_sel_proj} 的告警策略..."
          _pols=$(list_source_policies "${_sel_proj}" 2>/dev/null || true)
          if [[ -z "${_pols}" ]]; then
            echo "  (未找到策略或无权限)"
            continue
          fi
          _pol_names=()
          _pol_disp=()
          _pol_bound=()
          _i=1
          while IFS=$'\t' read -r _name _disp _ena _bound; do
            _pol_names+=("${_name}")
            _pol_disp+=("${_disp}")
            # check pending array
            _pb="${_bound}"
            for _pb_cand in "${PENDING_BIND[@]:-}"; do
               if [[ "${_pb_cand}" == "${_sel_proj}"$'	'"${_name}" ]]; then _pb="Y"; break; fi
            done
            for _pb_cand in "${PENDING_UNBIND[@]:-}"; do
               if [[ "${_pb_cand}" == "${_sel_proj}"$'	'"${_name}" ]]; then _pb="N"; break; fi
            done
            _pol_bound+=("${_pb}")
            echo "    ${_i}) [${_pb}] ${_disp}"
            _i=$((_i+1))
          done <<< "${_pols}"
          _read _toggle "  请输入要切换绑定状态的策略编号 (逗号分隔): "
          IFS="," read -r -a _t_arr <<<"${_toggle}"
          for _t in "${_t_arr[@]}"; do
            _t="${_t//[[:space:]]/}"
            if [[ "${_t}" =~ ^[0-9]+$ ]] && (( _t >= 1 && _t <= ${#_pol_names[@]} )); then
              _idx=$((_t-1))
              _pname="${_pol_names[$_idx]}"
              _pend_val="${_sel_proj}"$'	'"${_pname}"
              if [[ "${_pol_bound[$_idx]}" == "Y" ]]; then
                # Unbind
                _new_pb=()
                for _b in "${PENDING_BIND[@]}"; do
                  [[ "${_b}" != "${_pend_val}" ]] && _new_pb+=("${_b}")
                done
                PENDING_BIND=("${_new_pb[@]}")
                _found_un=false
                for _u in "${PENDING_UNBIND[@]}"; do [[ "${_u}" == "${_pend_val}" ]] && _found_un=true; done
                [[ "${_found_un}" == "false" ]] && PENDING_UNBIND+=("${_pend_val}")
                echo "    已标记解绑: ${_pol_disp[$_idx]}"
              else
                # Bind
                _new_pu=()
                for _u in "${PENDING_UNBIND[@]}"; do
                  [[ "${_u}" != "${_pend_val}" ]] && _new_pu+=("${_u}")
                done
                PENDING_UNBIND=("${_new_pu[@]}")
                _found_b=false
                for _b in "${PENDING_BIND[@]}"; do [[ "${_b}" == "${_pend_val}" ]] && _found_b=true; done
                [[ "${_found_b}" == "false" ]] && PENDING_BIND+=("${_pend_val}")
                echo "    已标记绑定: ${_pol_disp[$_idx]}"
              fi
            fi
          done
          ;;
        v)
          echo "  开始体检..."
          # 体检对象 = 当前编辑中的值（含未应用的新增/范围）；hub_health_check 读 HUB_SOURCE_PROJECTS / HUB_SCOPE
          HUB_SOURCE_PROJECTS="${NEW_HUB_SOURCE_PROJECTS}" HUB_SCOPE="${NEW_HUB_SCOPE}" hub_health_check 2>&1 | sed 's/^/    /'
          ;;
      esac
    done
  else
    if [[ -n "${HUB_SOURCE_PROJECTS+x}" ]]; then
      if [[ -z "${HUB_SOURCE_PROJECTS}" ]]; then
        NEW_HUB_SOURCE_PROJECTS=""
      else
        NEW_HUB_SOURCE_PROJECTS="$(normalize_hub_source_projects "${HUB_SOURCE_PROJECTS}")" || die "HUB_SOURCE_PROJECTS=${HUB_SOURCE_PROJECTS} 格式无效"
      fi
    else
      NEW_HUB_SOURCE_PROJECTS="${LIVE_HUB_SOURCE_PROJECTS:-}"
    fi
    if [[ -n "${HUB_SCOPE+x}" ]]; then
      if [[ -z "${HUB_SCOPE}" ]]; then
        NEW_HUB_SCOPE=""
      else
        normalize_hub_scope "${HUB_SCOPE}" >/dev/null || die "HUB_SCOPE=${HUB_SCOPE} 格式非法"
        NEW_HUB_SCOPE="${HUB_SCOPE}"
      fi
    else
      NEW_HUB_SCOPE="${LIVE_HUB_SCOPE:-}"
    fi
  fi
else
  # 本次未选 ⑧：沿用线上（或本轮菜单里 ⑧ 已编辑的值）。不能留空——空值会被当成「移除全部源项目」导出给部署脚本
  NEW_HUB_SOURCE_PROJECTS="${NEW_HUB_SOURCE_PROJECTS-${LIVE_HUB_SOURCE_PROJECTS:-}}"
  NEW_HUB_SCOPE="${NEW_HUB_SCOPE-${LIVE_HUB_SCOPE:-}}"
fi

# ---------------------------------------------------------------------------
# 未知现状的兜底
#   gcloud 模式：未知 + 保持 → 传 N，部署脚本不碰该资源，本脚本也不删（不是已知的「开 → 关」）。
#   Terraform 模式：传 N 会让 apply 删除 state 里的资源 → 交互模式必须作答，--yes 必须显式提供。
# ---------------------------------------------------------------------------
UNKNOWN_KEPT=()
resolve_unknown() {  # resolve_unknown 变量名 显示名 环境变量名 提示
  local var=$1 label=$2 envname=$3 prompt=$4
  [[ -z "${!var}" ]] || return 0
  if [[ "${LIVE_DEPLOY_MODE}" == "terraform" ]]; then
    if [[ "${INTERACTIVE}" == "true" ]]; then
      log_warn "无法读取「${label}」现状；Terraform 模式下必须明确选择（选 n 会让 apply 删除已有资源）"
      ask_yn "${var}" "  ${prompt}" ""
    else
      die "无法读取「${label}」现状。Terraform 模式下请显式设置 ${envname}=y|n 后重跑（否则 apply 可能误删资源）"
    fi
  else
    printf -v "${var}" '%s' "N"
    UNKNOWN_KEPT+=("${label}")
  fi
}
resolve_unknown NEW_ENABLE_PSH "PSH 告警策略" ENABLE_PSH "部署 PSH 两类官方告警策略？"
resolve_unknown NEW_ENABLE_DEFAULT_ALERTS "推荐默认告警包" ENABLE_DEFAULT_ALERTS "部署推荐默认监控告警包？"
resolve_unknown NEW_ENABLE_BILLING "Billing 预算" ENABLE_BILLING "启用 Billing 预算告警？"
resolve_unknown NEW_ENABLE_SCC "SCC 导出" ENABLE_SCC "启用 SCC 安全中心导出？"
if [[ "${OPS_KNOWN}" != "true" ]]; then
  if [[ "${LIVE_DEPLOY_MODE}" == "terraform" && "${INTERACTIVE}" != "true" ]]; then
    die "无法读取自监控收件邮箱。Terraform 模式下请显式设置 OPS_EMAIL=<邮箱>（或 OPS_EMAIL= 表示关闭）后重跑"
  elif [[ "${INTERACTIVE}" == "true" ]]; then
    _read _o "  无法读取自监控收件邮箱，请输入 OPS_EMAIL（留空 = 关闭）: "
    NEW_OPS_EMAIL="${_o//[[:space:]]/}"
  else
    UNKNOWN_KEPT+=("自监控（OPS_EMAIL）")
    OPS_UNKNOWN_KEEP=true
  fi
  OPS_KNOWN=true
fi

# ---------------------------------------------------------------------------
# 4. 差异
# ---------------------------------------------------------------------------
DIFF_ROWS=()
OFF_ROWS=()
add_diff() { [[ "$2" == "$3" ]] || DIFF_ROWS+=("$1"$'\x1f'"$2"$'\x1f'"$3"); }
ops_disp() { [[ -n "$1" ]] && echo "$1" || echo "关闭"; }
budget_disp() { [[ "$1" == "Y" ]] && echo "开启（$2 $3/月）" || echo "关闭"; }

LIVE_PSH_YN="$(yn_from_state "${LIVE_PSH}")"
LIVE_DEF_YN="$(yn_from_state "${LIVE_DEFAULT_ALERTS}")"
LIVE_BILL_YN="$(yn_from_state "${LIVE_BILLING}")"
LIVE_SCC_YN="$(yn_from_state "${LIVE_SCC}")"
LIVE_OPS_FOR_DIFF="$( [[ "${LIVE_SELF_MON}" == off ]] && echo "" || echo "${LIVE_OPS_EMAIL}")"

add_diff "通知渠道 NOTIFY_CHANNEL" "${LIVE_NOTIFY_CHANNEL_EFF}" "${NEW_CHANNEL}"
if [[ "${CRED_ACTION}" == "new" ]]; then
  DIFF_ROWS+=("渠道凭据"$'\x1f'"现有（${LIVE_WEBHOOK_MASKED}）"$'\x1f'"新凭据（$(mask_webhook_shell "$(new_webhook_value)")），写入 Secret 新版本")
fi
add_diff "MIN_SEVERITY" "${LIVE_MIN_SEVERITY_EFF}" "${NEW_MIN_SEVERITY}"
add_diff "按来源过滤" "$(source_filter_display "${LIVE_SOURCE_MIN_SEVERITY_EFF:-}")" "$(source_filter_display "${NEW_SOURCE_MIN_SEVERITY:-}")"
add_diff "LOG_LEVEL" "${LIVE_LOG_LEVEL_EFF}" "${NEW_LOG_LEVEL}"
add_diff "MAX_SENDS_PER_MINUTE" "${LIVE_MAX_SENDS_PER_MINUTE_EFF}" "${NEW_RATE}"
add_diff "MAX_INSTANCES" "${LIVE_MAX_INSTANCES_EFF}" "${NEW_MAX_INSTANCES}"
[[ -n "${LIVE_PSH_YN}" ]] && add_diff "PSH 告警策略" "$(state_label "${LIVE_PSH_YN}")" "$(state_label "${NEW_ENABLE_PSH}")"
[[ -n "${LIVE_DEF_YN}" ]] && add_diff "推荐默认告警包" "$(state_label "${LIVE_DEF_YN}")" "$(state_label "${NEW_ENABLE_DEFAULT_ALERTS}")"
[[ "${LIVE_SELF_MON}" != "unknown" && "${OPS_UNKNOWN_KEEP:-false}" != "true" ]] && add_diff "自监控 OPS_EMAIL" "$(ops_disp "${LIVE_OPS_FOR_DIFF}")" "$(ops_disp "${NEW_OPS_EMAIL}")"
[[ -n "${LIVE_BILL_YN}" ]] && add_diff "Billing 预算" "$(budget_disp "${LIVE_BILL_YN}" "${LIVE_BUDGET_UNITS}" "${LIVE_BUDGET_CURRENCY}")" "$(budget_disp "${NEW_ENABLE_BILLING}" "${NEW_BUDGET_UNITS}" "${NEW_BUDGET_CURRENCY}")"
[[ -n "${LIVE_SCC_YN}" ]] && add_diff "SCC 导出" "$(state_label "${LIVE_SCC_YN}")" "$(state_label "${NEW_ENABLE_SCC}")"
add_diff "KILL_SWITCH" "${LIVE_KILL_SWITCH_EFF}" "${NEW_KILL_SWITCH}"
add_diff "PAUSE_MODE" "${LIVE_PAUSE_MODE_EFF}" "${NEW_PAUSE_MODE}"

add_diff "多项目汇聚：源项目" "$(echo "${LIVE_HUB_SOURCE_PROJECTS:-未启用}" | tr ';' ', ' | sed -E 's/=[0-9]+//g')" "$(echo "${NEW_HUB_SOURCE_PROJECTS:-未启用}" | tr ';' ', ' | sed -E 's/=[0-9]+//g')"
add_diff "多项目汇聚：范围" "${LIVE_HUB_SCOPE:-未启用}" "${NEW_HUB_SCOPE:-未启用}"
if [[ ${#PENDING_BIND[@]} -gt 0 || ${#PENDING_UNBIND[@]} -gt 0 ]]; then
  DIFF_ROWS+=("绑定策略"$'\x1f'"-"$'\x1f'"+${#PENDING_BIND[@]} / -${#PENDING_UNBIND[@]}")
fi


# 关闭类变更（开 → 关）：要删除的资源

if [[ -n "${LIVE_HUB_SOURCE_PROJECTS:-}" ]]; then
  # check for removed projects
  _removed_projs=()
  for _p in $(echo "${LIVE_HUB_SOURCE_PROJECTS}" | tr ';' ' '); do
    if ! echo "${NEW_HUB_SOURCE_PROJECTS:-}" | grep -qE "(^|;)${_p%%=*}="; then
      _removed_projs+=("${_p%=*}")
    fi
  done
  if (( ${#_removed_projs[@]} > 0 )); then
    OFF_ROWS+=("多项目汇聚：移除源项目 (${_removed_projs[*]})，将删除其内的渠道/sink/scope关联，并从客户策略移除本 Hub 渠道")
  fi
  if [[ -n "${LIVE_HUB_SCOPE:-}" && -z "${NEW_HUB_SCOPE:-}" ]]; then
    OFF_ROWS+=("多项目汇聚：清空范围，将删除聚合 sink 并回退到逐项目 sink")
  fi
fi

REMOVE_PSH=false REMOVE_DEFAULT=false REMOVE_SELF_MON=false REMOVE_BILLING=false REMOVE_SCC=false
if [[ "${LIVE_PSH_YN}" == "Y" && "${NEW_ENABLE_PSH}" == "N" ]]; then
  REMOVE_PSH=true; OFF_ROWS+=("PSH 告警策略：删除「${PSH_POLICY_DISPLAY_NAMES[0]}」「${PSH_POLICY_DISPLAY_NAMES[1]}」")
fi
if [[ "${LIVE_DEF_YN}" == "Y" && "${NEW_ENABLE_DEFAULT_ALERTS}" == "N" ]]; then
  REMOVE_DEFAULT=true; OFF_ROWS+=("推荐默认告警包：删除 ${#DEFAULT_ALERT_POLICY_SPECS[@]} 条「Recommended - …」告警策略（按精确名）")
fi
# 现状未知且选择「保持不动」时（OPS_UNKNOWN_KEEP），NEW_OPS_EMAIL 为空只代表「不知道」，不是「关闭」。
if [[ "${OPS_UNKNOWN_KEEP:-false}" != "true" ]] \
   && [[ -n "${LIVE_OPS_FOR_DIFF}" || "${LIVE_SELF_MON}" == "partial" ]] && [[ -z "${NEW_OPS_EMAIL}" ]]; then
  REMOVE_SELF_MON=true; OFF_ROWS+=("自监控：删除策略「${SELF_MONITORING_POLICY_DISPLAY_NAMES[0]}」「${SELF_MONITORING_POLICY_DISPLAY_NAMES[1]}」与邮件渠道「${OPS_EMAIL_CHANNEL_DISPLAY_NAME}」")
fi
if [[ "${LIVE_BILL_YN}" == "Y" && "${NEW_ENABLE_BILLING}" == "N" ]]; then
  REMOVE_BILLING=true; OFF_ROWS+=("Billing：删除预算「$(billing_budget_display_name)」")
fi
if [[ "${LIVE_SCC_YN}" == "Y" && "${NEW_ENABLE_SCC}" == "N" ]]; then
  REMOVE_SCC=true; OFF_ROWS+=("SCC：删除组织 ${LIVE_ORG_ID:-?} 下的导出配置「${SCC_NOTIFICATION_ID}」")
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━ 变更预览 ━━━━━━━━━━━━━━━━━━━━━━"
if (( ${#DIFF_ROWS[@]} == 0 )); then
  echo "  无变化"
else
  printf '  %s %s\n' "$(_pad "项目" 24)" "当前值 → 新值"
  for _row in "${DIFF_ROWS[@]}"; do
    IFS=$'\x1f' read -r _k _o _n <<<"${_row}"
    printf '  %s %s → %s\n' "$(_pad "${_k}" 24)" "${_o}" "${_n}"
  done
fi
if (( ${#OFF_ROWS[@]} > 0 )); then
  echo ""
  echo "  关闭类变更（会删除资源）："
  for _row in "${OFF_ROWS[@]}"; do echo "    - ${_row}"; done
  if [[ "${LIVE_DEPLOY_MODE}" == "terraform" ]]; then
    echo "    （Terraform 模式：由 terraform apply 按 tfvars 的 enable_* / ops_email 删除）"
  else
    echo "    （gcloud 模式：部署脚本完成后，按精确名删除；带 managed-by=terraform 标签的资源会跳过）"
  fi
fi
if [[ "${CHANNEL_CHANGED}" == "true" ]]; then
  echo ""
  echo "  注：旧渠道（$(channel_label_of "${LIVE_NOTIFY_CHANNEL_EFF}")）的 Secret 会保留但不再挂载；不需要时可在 Secret Manager 中手工删除。"
fi
if (( ${#UNKNOWN_KEPT[@]} > 0 )); then
  echo ""
  echo "  现状未知、保持不动：${UNKNOWN_KEPT[*]}（本次不创建也不删除）"
fi
if [[ "${LIVE_DEPLOY_MODE}" == "terraform" ]]; then
  echo ""
  if [[ "${INTERACTIVE}" == "true" ]]; then
    echo "  Terraform 模式：确认后会先展示 terraform plan，并再次要求输入 yes 才 apply。"
  else
    echo "  Terraform 模式（--yes）：plan 后自动 apply。"
  fi
  echo "  注意：plan 中与本次修改无关的漂移（控制台手工改动等）也会一并应用。"
fi
if [[ "${NEW_KILL_SWITCH}" == "true" || "${NEW_PAUSE_MODE}" == "true" ]]; then
  echo ""
  log_warn "应用后 KILL_SWITCH=${NEW_KILL_SWITCH} / PAUSE_MODE=${NEW_PAUSE_MODE}：函数不投递告警，部署脚本的连通性自检会失败（属预期）"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo ""
  log_ok "--dry-run：未执行任何写操作。去掉 --dry-run 重跑即可应用。"
  exit 0
fi

if (( ${#DIFF_ROWS[@]} == 0 )); then
  if [[ "${INTERACTIVE}" == "true" ]]; then
    ask_yn _force "无变化，是否仍要强制重启函数（拉新 revision 使 Secret 等重新加载）？" "Y"
    [[ "${_force}" == "Y" ]] || { echo "操作已取消（未做任何修改）"; exit 0; }
  else
    log_info "无变化：仍将强制重启函数（拉新 revision 使 Secret 等重新加载）"
  fi
  MAIN_MENU_LOOP=false
elif [[ "${INTERACTIVE}" == "true" && -z "${SECTIONS_ARG}" ]]; then
  echo ""
  for _try in 1 2 3; do
    # 不设默认值：应用必须显式输入 a（原流程要求输入完整 yes，回车不能等于应用）
    _read _confirm "请选择：[a] 应用变更（将调用 ${DEPLOY_SCRIPT} --yes）  [m] 返回菜单继续修改  [q] 放弃并退出 (a/m/q): "
    _confirm="$(tr '[:upper:]' '[:lower:]' <<<"${_confirm//[[:space:]]/}")"
    case "${_confirm}" in
      a) MAIN_MENU_LOOP=false; break ;;
      m) continue 2 ;;
      q) echo "操作已放弃（未做任何修改）"; exit 0 ;;
      *) log_warn "无效选择，请输入 a, m 或 q" ;;
    esac
    [[ "${_try}" == 3 ]] && die "连续 3 次输入无效，已取消（未做任何修改）"
  done
elif [[ "${INTERACTIVE}" == "true" ]]; then
  echo ""
  _read _confirm "确认应用以上变更？将调用 ${DEPLOY_SCRIPT} --yes（yes/NO）: "
  [[ "${_confirm}" == "yes" ]] || { echo "操作已取消（未做任何修改）"; exit 0; }
  MAIN_MENU_LOOP=false
else
  MAIN_MENU_LOOP=false
fi

# ---------------------------------------------------------------------------
# 5. 应用：以环境变量交给部署脚本（凭据只在环境里，不进 argv / 文件）
# ---------------------------------------------------------------------------
done # MAIN_MENU_LOOP

APPLY_START="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
CONFIG_REVISION="$(date -u '+%Y%m%dT%H%M%SZ')"
[[ "${CONFIG_REVISION}" == "${LIVE_CONFIG_REVISION}" ]] && CONFIG_REVISION="${CONFIG_REVISION}-1"

if [[ "${LIVE_DEPLOY_MODE}" == "terraform" ]]; then
  APPLY_BUDGET_AMOUNT="${NEW_BUDGET_UNITS}"          # Terraform 的 billing_amount 只要数字（币种走 billing_currency）
else
  APPLY_BUDGET_AMOUNT="${NEW_BUDGET_UNITS}${NEW_BUDGET_CURRENCY}"   # gcloud --budget-amount 形如 100USD
fi


export HUB_SOURCE_PROJECTS="${NEW_HUB_SOURCE_PROJECTS:-}"
export HUB_SCOPE="${NEW_HUB_SCOPE:-}"
export NOTIFY_CHANNEL="${NEW_CHANNEL}"
export MIN_SEVERITY="${NEW_MIN_SEVERITY}" LOG_LEVEL="${NEW_LOG_LEVEL}"
# 显式导出（含空串）：空 = 清空按来源过滤；部署脚本以「是否设置」区分沿用线上与显式清空
export SOURCE_MIN_SEVERITY="${NEW_SOURCE_MIN_SEVERITY}"
export MAX_SENDS_PER_MINUTE="${NEW_RATE}" MAX_INSTANCES="${NEW_MAX_INSTANCES}"
export ENABLE_PSH="${NEW_ENABLE_PSH}" ENABLE_DEFAULT_ALERTS="${NEW_ENABLE_DEFAULT_ALERTS}"
export OPS_EMAIL="${NEW_OPS_EMAIL}"
export ENABLE_BILLING="${NEW_ENABLE_BILLING}" BUDGET_AMOUNT="${APPLY_BUDGET_AMOUNT}"
export ENABLE_SCC="${NEW_ENABLE_SCC}"
export KILL_SWITCH="${NEW_KILL_SWITCH}" PAUSE_MODE="${NEW_PAUSE_MODE}"
export CONFIG_REVISION PROJECT_ID
# 自监控现状未知且保持：部署脚本不登记「自监控被跳过」，也不创建 / 删除
export OPS_EMAIL_UNKNOWN_KEEP="${OPS_UNKNOWN_KEEP:-false}"
# Terraform：交互模式下 plan 后仍要人工输入 yes（deploy-terraform.sh 的 TF_APPLY_CONFIRM=interactive）；--yes 才自动批准
if [[ "${INTERACTIVE}" == "true" ]]; then
  export TF_APPLY_CONFIRM=interactive
else
  export TF_APPLY_CONFIRM=auto
fi
if [[ "${CRED_ACTION}" == "keep" ]]; then
  export KEEP_EXISTING_SECRETS=true
  unset FEISHU_WEBHOOK FEISHU_SECRET WECOM_WEBHOOK DINGTALK_WEBHOOK DINGTALK_SECRET
else
  export KEEP_EXISTING_SECRETS=false
  case "${NEW_CHANNEL}" in
    feishu)   export FEISHU_WEBHOOK FEISHU_SECRET ;;
    wecom)    export WECOM_WEBHOOK ;;
    dingtalk) export DINGTALK_WEBHOOK DINGTALK_SECRET ;;
  esac
fi

echo ""
echo "==== 应用配置：${DEPLOY_SCRIPT} --project=${PROJECT_ID} --region=${REGION} --yes（CONFIG_REVISION=${CONFIG_REVISION}）===="
DEPLOY_RC=0
if [[ "${LIVE_DEPLOY_MODE}" == "terraform" && "${INTERACTIVE}" == "true" ]]; then
  # 交互 TF：stdin 交给 deploy-terraform.sh，用于 plan 之后的 yes 确认
  "${DEPLOY_SCRIPT}" --project="${PROJECT_ID}" --region="${REGION}" --yes || DEPLOY_RC=$?
else
  "${DEPLOY_SCRIPT}" --project="${PROJECT_ID}" --region="${REGION}" --yes </dev/null || DEPLOY_RC=$?
fi
unset FEISHU_WEBHOOK FEISHU_SECRET WECOM_WEBHOOK DINGTALK_WEBHOOK DINGTALK_SECRET

if [[ "${DEPLOY_RC}" == "3" && "${LIVE_DEPLOY_MODE}" == "terraform" ]]; then
  echo ""
  log_warn "已在 terraform plan 确认处取消：未 apply，函数配置与 revision 均未改变"
  if [[ "${CRED_ACTION}" == "new" ]]; then
    log_warn "但新凭据已写入 Secret 新版本（${CHANNEL_SECRET_NAMES[*]}）；现有实例仍用旧值，直到下次重启。如需回退请在 Secret Manager 中停用该版本"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# 6. 重启证据：函数上的 CONFIG_REVISION 已是本次的值，且最新 revision 创建时间晚于应用开始
# ---------------------------------------------------------------------------

# Handle PENDING_BIND / PENDING_UNBIND
if [[ "${DEPLOY_RC}" == "0" || "${DEPLOY_RC}" == "2" ]]; then
  BIND_FAILURES=0
  if (( ${#PENDING_BIND[@]} > 0 )); then
    echo "==== 绑定告警策略 ===="
    for _b in "${PENDING_BIND[@]}"; do
      IFS=$'\t' read -r _bp _bname <<<"${_b}"
      if bind_policies_to_hub "${_bp}" "${_bname}"; then
        log_ok "已绑定策略: ${_bname} (在项目 ${_bp})"
      else
        log_warn "绑定策略失败: ${_bname} (在项目 ${_bp}) (请使用 gcloud beta monitoring policies update ... 补救)"
        BIND_FAILURES=$((BIND_FAILURES+1))
      fi
    done
  fi
  if (( ${#PENDING_UNBIND[@]} > 0 )); then
    echo "==== 解绑告警策略 ===="
    for _b in "${PENDING_UNBIND[@]}"; do
      IFS=$'\t' read -r _bp _bname <<<"${_b}"
      if unbind_policies_from_hub "${_bp}" "${_bname}"; then
        log_ok "已解绑策略: ${_bname} (在项目 ${_bp})"
      else
        log_warn "解绑策略失败: ${_bname} (在项目 ${_bp}) (请使用 gcloud beta monitoring policies update ... 补救)"
        BIND_FAILURES=$((BIND_FAILURES+1))
      fi
    done
  fi
  if (( BIND_FAILURES > 0 )); then
    DEPLOY_RC=2
  fi
fi

echo ""
echo "==== 校验重启生效 ===="
load_live_function_config "${REGION}"
APPLIED=false
RESTARTED=false
if [[ "${LIVE_FUNCTION_STATE}" == "present" && "${LIVE_CONFIG_REVISION}" == "${CONFIG_REVISION}" ]]; then
  APPLIED=true
  REV_CREATED=""
  if [[ -n "${LIVE_REVISION}" ]]; then
    REV_CREATED=$(gcloud run revisions describe "${LIVE_REVISION}" --region="${REGION}" \
      --format="value(metadata.creationTimestamp)" 2>/dev/null || true)
  fi
  REV_CREATED="${REV_CREATED:-${LIVE_UPDATE_TIME}}"
  if [[ -n "${REV_CREATED}" ]] && python3 - "${REV_CREATED}" "${APPLY_START}" <<'PY'
import re, sys
from datetime import datetime, timedelta, timezone
def p(s):
    # 兼容 2026-10-19T03:14:52Z / 2026-10-19T03:14:53.123456789Z / ...+00:00（Python 3.8+ 的 fromisoformat 不认 Z 与 9 位小数）
    m = re.match(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:?\d{2})?$", s.strip())
    if not m:
        raise SystemExit(1)
    dt = datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    if m.group(2):
        dt = dt.replace(microsecond=int(m.group(2)[:6].ljust(6, "0")))
    tz = m.group(3) or "Z"
    if tz != "Z":
        sign = 1 if tz[0] == "+" else -1
        hh, mm = int(tz[1:3]), int(tz[-2:])
        dt -= sign * timedelta(hours=hh, minutes=mm)
    return dt
# 留 60 秒余量容忍本机与服务端时钟偏差
sys.exit(0 if p(sys.argv[1]) >= p(sys.argv[2]) - timedelta(seconds=60) else 1)
PY
  then
    RESTARTED=true
    log_ok "函数已重启：最新 revision ${LIVE_REVISION:-?}（创建于 ${REV_CREATED}，应用开始于 ${APPLY_START}），CONFIG_REVISION=${CONFIG_REVISION}"
  else
    log_warn "CONFIG_REVISION 已更新为 ${CONFIG_REVISION}，但未能确认最新 revision（${LIVE_REVISION:-?} / ${REV_CREATED:-创建时间未知}）晚于应用开始时间 ${APPLY_START}"
  fi
else
  log_error "函数上的 CONFIG_REVISION（${LIVE_CONFIG_REVISION:-无}）不是本次的 ${CONFIG_REVISION}：配置未生效（部署脚本退出码 ${DEPLOY_RC}，见上方输出）"
fi

# ---------------------------------------------------------------------------
# 7. gcloud 模式的「开 → 关」：部署脚本已完成（只 upsert 不删），这里按精确名删除
# ---------------------------------------------------------------------------
if [[ "${LIVE_DEPLOY_MODE}" == "gcloud" && ${#OFF_ROWS[@]} -gt 0 ]]; then
  echo ""
  if [[ "${APPLIED}" != "true" ]]; then
    log_warn "配置未生效，跳过关闭类变更的资源删除（修复后重跑本脚本即可）"
  else
    echo "==== 删除已关闭功能的资源（精确名匹配）===="
    REMOVE_FAILURES=0
    [[ "${REMOVE_PSH}" == "true" ]]      && remove_psh_policies
    [[ "${REMOVE_DEFAULT}" == "true" ]]  && remove_default_alert_policies
    [[ "${REMOVE_SELF_MON}" == "true" ]] && remove_self_monitoring
    [[ "${REMOVE_BILLING}" == "true" ]]  && remove_billing_budget
    [[ "${REMOVE_SCC}" == "true" ]]      && remove_scc_export true
    if (( REMOVE_FAILURES == 0 )); then
      log_ok "关闭类变更已落实"
    else
      log_warn "${REMOVE_FAILURES} 项资源删除失败（见上），请补齐权限后重跑本脚本"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 8. 结论
# ---------------------------------------------------------------------------
echo ""
if [[ "${APPLIED}" != "true" ]]; then
  log_error "配置修改未生效"
  exit 1
fi
if [[ "${DEPLOY_RC}" == "0" && "${RESTARTED}" == "true" && "${REMOVE_FAILURES:-0}" == "0" ]]; then
  log_ok "配置已更新并重启生效（${LIVE_DEPLOY_MODE} 模式）"
  exit 0
fi
case "${DEPLOY_RC}" in
  0) ;;
  2) log_warn "部署脚本以【不完整】状态结束（退出码 2）：配置已生效，但有步骤被跳过 —— 见上方清单" ;;
  *) _why="常见原因：terraform apply / gcloud 步骤报错，或连通性自检未通过"
     [[ "${NEW_KILL_SWITCH}" == "true" || "${NEW_PAUSE_MODE}" == "true" ]] && _why="KILL_SWITCH / PAUSE_MODE 为 true 时连通性自检必然失败，属预期"
     log_warn "部署脚本退出码 ${DEPLOY_RC}（${_why}）：配置已生效，请按上方提示排查" ;;
esac
exit 2
