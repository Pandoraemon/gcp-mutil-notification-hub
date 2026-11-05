#!/bin/bash
# lib/common.sh —— 两条部署路径共享的函数库。
#
# 设计约束：本文件只定义函数与常量，不产生任何副作用（不 set -e、不执行 gcloud），
# 以便被 deploy-*.sh 与 scripts/* 安全地 source。
#
# 覆盖的失效模式（详见规格说明书 Risks 表）：
#   - Gen2 缺 run/eventarc/artifactregistry 任一 API 即部署失败；
#   - 服务代理（P4SA）懒创建，未创建就授权 = 写入永不生效的绑定 → 告警静默不发；
#   - `secrets create || true` 在重跑换新 webhook 时静默沿用旧值；
#   - 自检必须能自动判定成败，而不是让用户"自己去群里看一眼"。

# 让脚本可从任意目录调用
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# 全局资源名（两条路径必须一致，否则 scripts/* 会操作错对象）
TOPIC_NAME="${TOPIC_NAME:-gcp-alerts-hub}"
DLQ_TOPIC_NAME="${DLQ_TOPIC_NAME:-gcp-alerts-dlq}"
DLQ_SUBSCRIPTION="${DLQ_SUBSCRIPTION:-gcp-alerts-dlq-sub}"
FUNCTION_NAME="${FUNCTION_NAME:-gcp-alerts-to-feishu}"
SERVICE_ACCOUNT_ID="${SERVICE_ACCOUNT_ID:-gcp-alerts-fn}"
SECRET_WEBHOOK_NAME="${SECRET_WEBHOOK_NAME:-feishu-default-webhook}"
SECRET_SIGN_NAME="${SECRET_SIGN_NAME:-feishu-default-secret}"
# 企业微信 / 钉钉渠道的 Secret 名（默认值与 Terraform 变量 wecom_default_webhook_secret /
# dingtalk_default_webhook_secret / dingtalk_default_sign_secret 的默认值逐字一致；可用环境变量覆盖）。
# 企业微信群机器人没有签名机制，凭据就是 Webhook URL 里的 key，因此只有一个 Secret。
SECRET_WECOM_WEBHOOK_NAME="${SECRET_WECOM_WEBHOOK_NAME:-wecom-default-webhook}"
SECRET_DINGTALK_WEBHOOK_NAME="${SECRET_DINGTALK_WEBHOOK_NAME:-dingtalk-default-webhook}"
SECRET_DINGTALK_SIGN_NAME="${SECRET_DINGTALK_SIGN_NAME:-dingtalk-default-secret}"
# 三个渠道的全部 Secret：teardown 按这份清单【精确名】逐个回收（存在才处理）。
# 部署只会创建所选渠道的那一两个，但切换过渠道的项目里可能同时留有多套。
ALL_CHANNEL_SECRET_NAMES=(
  "${SECRET_WEBHOOK_NAME}"
  "${SECRET_SIGN_NAME}"
  "${SECRET_WECOM_WEBHOOK_NAME}"
  "${SECRET_DINGTALK_WEBHOOK_NAME}"
  "${SECRET_DINGTALK_SIGN_NAME}"
)
# 函数实例上限（gcloud --max-instances / Terraform max_instances）。限流上限校验
# validate_channel_rate_limit 要用它：令牌桶是【每实例】的，群机器人的限额是【每群】的。
# 先记下调用方是否【显式】提供了 MAX_INSTANCES：重跑部署时未显式提供才沿用线上值
# （见 resolve_runtime_config），而下一行的默认值赋值之后就分辨不出来了。
if [[ -n "${MAX_INSTANCES:-}" ]]; then MAX_INSTANCES_EXPLICIT=true; else MAX_INSTANCES_EXPLICIT=false; fi
MAX_INSTANCES="${MAX_INSTANCES:-2}"
# 自监控告警模板（templates/self-monitoring-*.yaml）里的变量名用的是 DLQ_SUBSCRIPTION_NAME，
# 与 Terraform 变量同名；这里做个别名并导出，envsubst 才替换得到。
DLQ_SUBSCRIPTION_NAME="${DLQ_SUBSCRIPTION}"
export DLQ_SUBSCRIPTION_NAME

# Notification Channel 的 displayName（部署按它查重，卸载按它精确删除）
CHANNEL_DISPLAY_NAME="${CHANNEL_DISPLAY_NAME:-Feishu Alert Hub}"
OPS_EMAIL_CHANNEL_DISPLAY_NAME="${OPS_EMAIL_CHANNEL_DISPLAY_NAME:-GCP Alerts Hub Ops Email}"

# ---------------------------------------------------------------------------
# 本仓库【拥有】的告警策略 displayName 清单 —— 部署与卸载共用同一份。
#
# teardown 必须按这份清单【精确匹配】删除，不能按前缀/子串：gcloud --filter 的
# `key:value` 是 contains 语义，`displayName:'Recommended - '` 会把客户自建的、
# 以及同项目 Terraform 托管的同名前缀策略一起删掉。
# 新增一条策略时只改这里，deploy_* 函数与 teardown 自动跟上。
# ---------------------------------------------------------------------------
PSH_POLICY_DISPLAY_NAMES=(
  "GCP Service Health Incident"
  "GCP Service Health Emerging Incident"
)
# 旧版本曾部署过的 PSH 策略名：PSH 日志源的 category 只有 INCIDENT，这两条永远不触发，
# 已从部署清单移除；保留在卸载清单里以便回收旧环境。
LEGACY_PSH_POLICY_DISPLAY_NAMES=(
  "GCP Service Health Scheduled Maintenance"
  "GCP Service Health Security Bulletin"
)
# "模板相对路径|displayName"，供 deploy_recommended_default_alerts 遍历
DEFAULT_ALERT_POLICY_SPECS=(
  "templates/default-alerts/gce-cpu-high.yaml|Recommended - GCE High CPU Utilization"
  "templates/default-alerts/gce-disk-high.yaml|Recommended - GCE Disk Space High Utilization"
  "templates/default-alerts/gce-host-maintenance.yaml|Recommended - GCE Host Error & Maintenance Event"
  "templates/default-alerts/quota-exceeded.yaml|Recommended - GCP Quota Exceeded & Allocation Warning"
  "templates/default-alerts/network-lb-5xx.yaml|Recommended - HTTP Load Balancer 5xx Error Spike"
  "templates/default-alerts/network-cloud-nat.yaml|Recommended - Cloud NAT Port Exhaustion & Packet Drops"
  "templates/default-alerts/gke-container-health.yaml|Recommended - GKE Container Restart & Memory High"
  "templates/default-alerts/cloudsql-resource-high.yaml|Recommended - Cloud SQL CPU / Memory / Disk High"
  "templates/default-alerts/audit-high-risk-iam.yaml|Recommended - High-Risk IAM Policy Change"
  "templates/default-alerts/audit-sa-key-created.yaml|Recommended - Service Account Key Created"
  "templates/default-alerts/gce-upcoming-maintenance.yaml|Recommended - GCE & GPU Upcoming Host Maintenance"
)
SELF_MONITORING_POLICY_DISPLAY_NAMES=(
  "GCP Alerts Hub - Permanent Send Failure"
  "GCP Alerts Hub - DLQ Backlog"
)

# 汇总成一份扁平清单（teardown 用）。
MANAGED_POLICY_DISPLAY_NAMES=(
  "${PSH_POLICY_DISPLAY_NAMES[@]}"
  "${LEGACY_PSH_POLICY_DISPLAY_NAMES[@]}"
  "${SELF_MONITORING_POLICY_DISPLAY_NAMES[@]}"
)
for _spec in "${DEFAULT_ALERT_POLICY_SPECS[@]}"; do
  MANAGED_POLICY_DISPLAY_NAMES+=("${_spec#*|}")
done
unset _spec

# ---------------------------------------------------------------------------
# 输出helper
# ---------------------------------------------------------------------------
log_info()  { echo "  $*"; }
log_ok()    { echo "✅ $*"; }
log_warn()  { echo "⚠️  $*" >&2; }
log_error() { echo "❌ $*" >&2; }

die() { log_error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# 降级跳过登记
#
# 权限不足时不中断主流程，但【绝不假装成功】。本项目最危险的失效模式是
# "部署显示成功、日志显示正常、群里就是没有卡片" —— 静默跳过一步授权，
# 正是制造这种失效的最短路径。因此每次跳过都登记在册，结尾统一打印
# "本次部署不完整"清单，并让脚本以非 0 退出。
#
# 分级原则：产出空壳的步骤（topic/订阅、Secret、源码上传、函数部署）仍然 die；
# 只让"失去某个数据源或某项兜底、但主链路仍成立"的步骤走降级。
# ---------------------------------------------------------------------------
SKIPPED_STEPS=()
# \x1f（单元分隔符）而非 | 或 : 作字段分隔：补救提示里本身就含 : 与 /
_SKIP_FS=$'\x1f'

record_skip() {
  local title=$1 impact=$2 remedy=$3
  SKIPPED_STEPS+=("${title}${_SKIP_FS}${impact}${_SKIP_FS}${remedy}")
  log_warn "已跳过：${title}"
  echo "    影响：${impact}" >&2
  echo "    补救：${remedy}" >&2
}

# 可降级步骤。用法：
#   soft_step "<跳过项>" "<影响>" "<补救命令>" -- <命令...>
# 命令失败时登记并返回 0，因此在 set -e 下不会中断调用方。
# 调用方若需要知道这一步到底成没成功（例如决定要不要打印 ✅），读 LAST_STEP_OK。
LAST_STEP_OK=true
soft_step() {
  local title=$1 impact=$2 remedy=$3
  shift 3
  [[ "${1:-}" == "--" ]] && shift
  if "$@" >/dev/null 2>&1; then
    LAST_STEP_OK=true
    return 0
  fi
  LAST_STEP_OK=false
  record_skip "${title}" "${impact}" "${remedy}"
  return 0
}

# soft_step 的带重试版本：用于「刚创建的身份马上被引用」这类 IAM 传播竞态。
# 新建 SA 后立刻 add-iam-policy-binding 会间歇性报 "Service account ... does not exist"
# （Argolis 实测：新项目首次部署 secretAccessor 因此被跳过，随后 functions deploy 以
# "Permission denied on secret" 硬失败）。失败后每 pause 秒重试一次，共 attempts 次，
# 全部失败才登记跳过 —— 真正缺权限时最多多等 attempts×pause 秒，代价可接受。
# 用法：soft_step_retry 12 5 "标题" "影响" "补救" -- cmd args...
soft_step_retry() {
  local attempts=$1 pause=$2 title=$3 impact=$4 remedy=$5
  shift 5
  [[ "${1:-}" == "--" ]] && shift
  local i
  for (( i = 1; i <= attempts; i++ )); do
    if "$@" >/dev/null 2>&1; then
      LAST_STEP_OK=true
      [[ ${i} -gt 1 ]] && log_ok "${title}（第 ${i} 次尝试成功，IAM 传播已完成）"
      return 0
    fi
    (( i < attempts )) && sleep "${pause}"
  done
  LAST_STEP_OK=false
  record_skip "${title}" "${impact}" "${remedy}"
  return 0
}

# 结尾汇报。返回 1 表示"部署不完整"，调用方据此决定退出码与结束语。
report_skips() {
  if (( ${#SKIPPED_STEPS[@]} == 0 )); then
    return 0
  fi
  local entry title impact remedy i=1
  echo ""
  echo "══════════════════════════════════════════════════════════════"
  log_warn "本次部署【不完整】：${#SKIPPED_STEPS[@]} 个步骤因权限不足被跳过"
  echo "══════════════════════════════════════════════════════════════"
  for entry in "${SKIPPED_STEPS[@]}"; do
    IFS="${_SKIP_FS}" read -r title impact remedy <<<"${entry}"
    echo ""
    echo "  ${i}. ${title}"
    echo "     影响：${impact}"
    echo "     补救：${remedy}"
    i=$(( i + 1 ))
  done
  echo ""
  echo "  补齐权限后重跑本脚本即可 —— 全流程幂等，已建成的资源不会重复创建。"
  echo "  完整角色清单见 docs/full-guide.md 的「所需 IAM 权限」一节。"
  echo ""
  return 1
}

# 前置依赖检查：缺 jq 只会在 replay-dlq.sh 跑到一半时才炸，提前拦住
require_commands() {
  local missing=()
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
  done
  if (( ${#missing[@]} > 0 )); then
    die "缺少必需命令: ${missing[*]}（请先安装后重试）"
  fi
}

# ---------------------------------------------------------------------------
# 部署者身份解析
#
# 补救提示里要给出 `--member=...`。脚本由客户在自己环境里跑，执行者可能是个人账号、
# CI 的 Service Account、被模拟的 SA 或 WIF 联合身份 —— 不能假设，只能运行时解析：
#   - 以 gserviceaccount.com 结尾  → serviceAccount:<email>
#   - 其它                         → user:<email>
#   - 解析不到（未登录 / (unset)）  → 字面量 '<你的账号>'（带引号：裸写 <> 会被 bash
#                                     当成重定向，粘贴即报 "你: No such file or directory"）
# 允许用 DEPLOYER_MEMBER 环境变量整体覆盖（WIF principal:// 等 gcloud 读不出的场景）。
# 结果写入全局 DEPLOYER_MEMBER 并导出。
# ---------------------------------------------------------------------------
resolve_deployer_member() {
  if [[ -n "${DEPLOYER_MEMBER:-}" ]]; then
    export DEPLOYER_MEMBER
    return 0
  fi
  local account
  account=$(gcloud config get-value account 2>/dev/null || true)
  account="${account//[[:space:]]/}"
  if [[ -z "${account}" || "${account}" == "(unset)" ]]; then
    DEPLOYER_MEMBER="'<你的账号>'"
  elif [[ "${account}" == *.gserviceaccount.com ]]; then
    DEPLOYER_MEMBER="serviceAccount:${account}"
  else
    DEPLOYER_MEMBER="user:${account}"
  fi
  export DEPLOYER_MEMBER
}

# ---------------------------------------------------------------------------
# 部署者权限预检（只读）
#
# 用 cloudresourcemanager 的 projects:testIamPermissions 探测当前身份实际拥有的权限
# 子集 —— 这是唯一能在【不创建任何资源】的前提下回答"缺哪些权限"的办法（gcloud 没有
# 对应子命令）。缺失项在建资源之前就列出来，并给出一条合并好的补救命令，
# 避免跑了 10 分钟、函数都部署完了，才在 Billing 那一步发现少个角色。
#
# 它只是预警，不是门禁：
#   - 权限可能来自组、来自有条件的绑定、来自自定义角色，探测结果偏保守；
#   - curl 不通（无网络 / 公司代理 / CBA 拦截）或 API 未启用时只 WARNING，不阻塞；
#   - 交互模式下询问是否继续；--yes / 非 TTY 下只打印清单，不阻塞。
# 调用位置：prompt_optional_sources 之后（知道启用了哪些可选模块）、
#           check_and_enable_apis 之前（还没对项目做任何写操作）。
# ---------------------------------------------------------------------------
# 范围模式预检：部署者在文件夹 / 组织上必须能管理 sink。否则 apply / 部署中途 403，
# 而范围内的源项目已被判定为「不需要项目级 sink」→ 日志无人路由（2026-10-27 Argolis 实测）。读不到令牌 / 无 curl 时跳过
preflight_hub_scope_permissions() {
  local scope="${HUB_SCOPE:-}" token resp url perm missing=()
  [[ -n "${scope}" ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  token=$(gcloud auth print-access-token 2>/dev/null || true)
  [[ -n "${token}" ]] || return 0
  if [[ "${scope}" == folders/* ]]; then
    url="https://cloudresourcemanager.googleapis.com/v3/${scope}:testIamPermissions"
  else
    url="https://cloudresourcemanager.googleapis.com/v1/${scope}:testIamPermissions"
  fi
  resp=$(curl -s -X POST -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
    -H "x-goog-user-project: ${PROJECT_ID}" \
    -d '{"permissions":["logging.sinks.create","logging.sinks.get","logging.sinks.update","logging.sinks.delete"]}' \
    "${url}" 2>/dev/null || true)
  for perm in logging.sinks.create logging.sinks.get logging.sinks.update logging.sinks.delete; do
    grep -q "\"${perm}\"" <<<"${resp}" || missing+=("${perm}")
  done
  if (( ${#missing[@]} > 0 )); then
    log_error "部署者在汇聚范围 ${scope} 上缺少：${missing[*]}（范围内源项目的日志将无人路由）"
    echo "请让 ${scope} 的管理员授予 roles/logging.configWriter 后重跑，例如："
    if [[ "${scope}" == folders/* ]]; then
      echo "  gcloud resource-manager folders add-iam-policy-binding ${scope#folders/} --member=\"${DEPLOYER_MEMBER:-user:<部署者>}\" --role=roles/logging.configWriter"
    else
      echo "  gcloud organizations add-iam-policy-binding ${scope#organizations/} --member=\"${DEPLOYER_MEMBER:-user:<部署者>}\" --role=roles/logging.configWriter"
    fi
    return 1
  fi
  log_ok "汇聚范围 ${scope} 的 sink 管理权限预检通过"
}

preflight_deployer_permissions() {
  local -a required=(
    "resourcemanager.projects.setIamPolicy"
    "serviceusage.services.enable"
    "iam.serviceAccounts.create"
    "secretmanager.secrets.create"
    "pubsub.topics.create"
    "cloudfunctions.functions.create"
    "monitoring.alertPolicies.create"
    "monitoring.notificationChannels.create"
  )
  # 权限 → 能补齐它的预定义角色（补救命令用）
  local -A role_for=(
    ["resourcemanager.projects.setIamPolicy"]="roles/resourcemanager.projectIamAdmin"
    ["serviceusage.services.enable"]="roles/serviceusage.serviceUsageAdmin"
    ["iam.serviceAccounts.create"]="roles/iam.serviceAccountAdmin"
    ["secretmanager.secrets.create"]="roles/secretmanager.admin"
    ["pubsub.topics.create"]="roles/pubsub.admin"
    ["cloudfunctions.functions.create"]="roles/cloudfunctions.developer"
    ["monitoring.alertPolicies.create"]="roles/monitoring.alertPolicyEditor"
    ["monitoring.notificationChannels.create"]="roles/monitoring.notificationChannelEditor"
  )
  if [[ -n "${HUB_SOURCE_PROJECTS:-}" || -n "${HUB_SCOPE:-}" ]]; then
    required+=(
      "pubsub.topics.setIamPolicy"
      "monitoring.metricsScopes.link"
    )
    role_for["pubsub.topics.setIamPolicy"]="roles/pubsub.admin"
    role_for["monitoring.metricsScopes.link"]="roles/monitoring.metricsScopesAdmin"
  fi


  echo "预检部署者权限（只读探测，不创建任何资源）..."
  if ! command -v curl >/dev/null 2>&1; then
    log_warn "本机没有 curl，跳过权限预检；缺权限的步骤会在执行时逐个登记为「已跳过」"
    return 0
  fi

  local token
  token=$(gcloud auth print-access-token 2>/dev/null || true)
  if [[ -z "${token}" ]]; then
    log_warn "无法获取访问令牌（未登录？），跳过权限预检"
    return 0
  fi

  local body perm
  body="{\"permissions\":[$(printf '"%s",' "${required[@]}" | sed 's/,$//')]}"
  # 不用 --fail-with-body（需 curl ≥ 7.76，旧 macOS / 精简 CI 镜像没有），
  # 改为把 HTTP 状态码追加在末行自行判断。
  local response http_code
  if ! response=$(curl -sS --max-time 20 -X POST \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "${body}" -w '\n%{http_code}' \
        "https://cloudresourcemanager.googleapis.com/v1/projects/${PROJECT_ID}:testIamPermissions" 2>&1); then
    # 不阻塞：网络/代理/API 未启用都可能让这一步失败，而部署本身未必受影响
    log_warn "权限预检请求失败，跳过（后续缺权限的步骤仍会逐个登记）"
    echo "    $(head -c 300 <<<"${response}" | tr '\n' ' ')" >&2
    return 0
  fi
  http_code="${response##*$'\n'}"
  response="${response%$'\n'*}"
  if [[ ! "${http_code}" =~ ^2[0-9][0-9]$ ]]; then
    log_warn "权限预检返回 HTTP ${http_code}，跳过（常见于 cloudresourcemanager API 未启用或缺 resourcemanager.projects.get）"
    echo "    $(head -c 300 <<<"${response}" | tr '\n' ' ')" >&2
    return 0
  fi

  local -a missing=()
  for perm in "${required[@]}"; do
    # 不依赖 jq：返回体形如 {"permissions": ["a", "b"]}，按字面量找即可
    grep -qF "\"${perm}\"" <<<"${response}" || missing+=("${perm}")
  done

  if (( ${#missing[@]} == 0 )); then
    log_ok "部署者权限预检通过（${DEPLOYER_MEMBER}）"
    return 0
  fi

  # 去重角色，拼成一条可直接粘贴的补救命令
  local -A seen=()
  local -a roles=()
  for perm in "${missing[@]}"; do
    local r="${role_for[${perm}]}"
    [[ -n "${seen[${r}]:-}" ]] && continue
    seen["${r}"]=1; roles+=("${r}")
  done
  local remedy="" r
  for r in "${roles[@]}"; do
    remedy+="gcloud projects add-iam-policy-binding ${PROJECT_ID} --member=\"${DEPLOYER_MEMBER}\" --role=${r} && "
  done
  remedy="${remedy% && }"

  echo ""
  log_warn "部署者 ${DEPLOYER_MEMBER} 缺少 ${#missing[@]} 项权限（探测结果偏保守：组/条件绑定可能未计入）："
  for perm in "${missing[@]}"; do
    echo "    - ${perm}（${role_for[${perm}]}）" >&2
  done
  echo "    补救（需项目 IAM 管理员执行，之后等约 60 秒再重跑）：" >&2
  echo "    ${remedy}" >&2
  echo "" >&2
  echo "    继续的话，缺权限的步骤会被跳过并在结尾列出，核心链路可能不完整。" >&2

  if [[ "${ASSUME_YES:-false}" == "true" || ! -t 0 ]]; then
    return 0
  fi
  local go
  read -rp "仍要继续部署？(yes/NO): " go
  [[ "${go}" == "yes" ]] || { echo "操作已取消（未创建任何资源）"; exit 0; }
  return 0
}

# ---------------------------------------------------------------------------
# 构建身份：确保默认 compute SA 具备 roles/cloudbuild.builds.builder
#
# 自 2024 年起，新建项目的默认 compute SA【不再自动携带】该角色，而 Gen2 函数
# 默认就用这个 SA 当 Cloud Build 的工作身份。两条部署路径都会踩，但表现不同：
#   gcloud 路径     —— 先打印一条 WARNING（容易被 3-5 分钟的部署日志淹没），随后构建失败；
#   Terraform 路径  —— apply 直接硬失败中断，留下一份半成品 state，实测报错：
#                      "Build failed with status: FAILURE. Could not build the function
#                       due to a missing permission on the build service account."
#
# 因此本函数【必须】在创建函数之前调用。放在 lib 里共享，是为了避免两条路径各修各的 ——
# 这个项目已经出现过多次「一条路径修了、另一条没修」的不对等。
#
# 用法: ensure_build_sa_role <PROJECT_ID> [PROJECT_NUMBER]
ensure_build_sa_role() {
  local project_id=$1
  local project_number=${2:-}

  if [[ -z "${project_number}" ]]; then
    project_number=$(gcloud projects describe "${project_id}" \
      --format="value(projectNumber)" 2>/dev/null || true)
  fi
  if [[ -z "${project_number}" ]]; then
    record_skip "检查构建身份" \
      "无法解析项目编号，未能确认构建身份权限；函数构建可能失败" \
      "gcloud projects describe ${project_id} --format='value(projectNumber)' 应能正常返回"
    return 0
  fi

  local build_sa="${project_number}-compute@developer.gserviceaccount.com"
  local build_role="roles/cloudbuild.builds.builder"

  echo "检查构建身份权限..."

  if ! gcloud iam service-accounts describe "${build_sa}" \
       --project="${project_id}" >/dev/null 2>&1; then
    # 该 SA 由 compute API 首次启用时创建。不擅自创建（属项目级基础设施），只如实报出。
    record_skip "检查构建身份 ${build_sa}" \
      "默认构建 Service Account 不存在，Cloud Functions 构建阶段可能失败" \
      "gcloud services enable compute.googleapis.com --project=${project_id}（会自动创建该 SA），然后重跑本脚本"
    return 0
  fi

  if gcloud projects get-iam-policy "${project_id}" --flatten="bindings[].members" \
       --filter="bindings.role=${build_role} AND bindings.members:${build_sa}" \
       --format="value(bindings.role)" 2>/dev/null | grep -q .; then
    log_ok "构建身份已具备 ${build_role}"
    return 0
  fi

  if ! gcloud projects add-iam-policy-binding "${project_id}" \
       --member="serviceAccount:${build_sa}" --role="${build_role}" \
       --condition=None >/dev/null 2>&1; then
    record_skip "为构建身份补授 ${build_role}" \
      "函数构建【很可能直接失败】：Cloud Build 无权拉取源码或推送镜像" \
      "gcloud projects add-iam-policy-binding ${project_id} --member=serviceAccount:${build_sa} --role=${build_role}（需 roles/resourcemanager.projectIamAdmin），授权后等约 60 秒再重跑本脚本"
    log_warn "构建身份缺少 ${build_role}，接下来的部署可能失败。补救命令见上。"
    return 0
  fi

  log_ok "已为构建身份补授 ${build_role}"
  # IAM 绑定有传播延迟。刚授完立刻部署，构建仍可能以同样的权限错误失败 ——
  # 那个报错与"根本没授权"一模一样，足以让人怀疑上面这条命令没生效。
  # 这里轮询到绑定可见为止，把这种假象挡掉。
  echo -n "  等待 IAM 传播"
  local _i
  for _i in $(seq 1 18); do
    sleep 5; echo -n "."
    if gcloud projects get-iam-policy "${project_id}" --flatten="bindings[].members" \
         --filter="bindings.role=${build_role} AND bindings.members:${build_sa}" \
         --format="value(bindings.role)" 2>/dev/null | grep -q .; then
      break
    fi
  done
  echo " 就绪"
}

# ---------------------------------------------------------------------------
# 选择目标项目
#
# 优先级：--project=ID 参数 > PROJECT_ID 环境变量 > 交互式选择 > gcloud 默认项目。
#
# 选定后导出 CLOUDSDK_CORE_PROJECT 而不是执行 `gcloud config set project`：
# 前者只影响本次脚本派生的 gcloud 子进程，后者会改写用户机器（或 Cloud Shell）上的
# 持久化配置 —— 部署一次就把别人的默认项目换掉，是最容易引发误操作的副作用。
#
# 结果写入全局 PROJECT_ID 并导出（而非 echo 返回），这样交互提示不会污染调用方的
# 命令替换结果。
# ---------------------------------------------------------------------------

# 校验并锁定项目。所有入口最终都走这里，保证"笔误的项目 ID"在建资源前就被拦下。
_use_project() {
  local id="$1"
  [[ -n "${id}" ]] || die "项目 ID 不能为空"
  PROJECT_ID="${id}"
  CLOUDSDK_CORE_PROJECT="${id}"
  export PROJECT_ID CLOUDSDK_CORE_PROJECT

  # --quiet 不可省略：cloudresourcemanager 未启用时 describe 会弹出
  # "Would you like to enable and retry (y/N)?" 交互提示，而此处 stderr 被捕获、
  # stdin 仍连着终端 —— 脚本会挂在一个用户根本看不见的问题上。
  local err
  if err=$(gcloud projects describe "${id}" --quiet --format="value(projectId)" 2>&1 >/dev/null); then
    log_ok "已选择项目 ${PROJECT_ID}"
    return
  fi

  # 校验失败 ≠ 项目不存在。全新项目里 cloudresourcemanager API 往往尚未启用
  # （本仓库的 check_and_enable_apis 正是用来启用它的），此时"查不了"是预期状态，
  # 不能据此拒绝一个合法项目。只有在确实能查、且查不到时才拦下笔误。
  if grep -qiE 'SERVICE_DISABLED|has not been used in project|API \[cloudresourcemanager' <<<"${err}"; then
    log_warn "暂时无法校验项目 ${PROJECT_ID}（cloudresourcemanager API 未启用），继续执行"
    echo "    若项目 ID 有误，后续第一条 gcloud 命令就会报错，不会误建资源" >&2
    return
  fi
  die "项目不存在或当前账号无权访问: ${id}（需 resourcemanager.projects.get 权限）"
}

select_project() {
  local requested="${1:-${PROJECT_ID:-}}"
  local current
  current=$(gcloud config get-value project 2>/dev/null || true)
  [[ "${current}" == "(unset)" ]] && current=""

  # 1. 显式指定：不询问，直接校验后使用
  if [[ -n "${requested}" ]]; then
    _use_project "${requested}"
    return
  fi

  # 2. 非交互（--yes 或 stdin 不是终端，例如 CI / 管道）：只能沿用 gcloud 默认项目。
  #    此处若再去 read，会读走管道里的数据并静默选错项目。
  if [[ "${ASSUME_YES:-false}" == "true" || ! -t 0 ]]; then
    [[ -n "${current}" ]] || \
      die "非交互模式下未指定项目。请用 --project=PROJECT_ID，或先执行 gcloud config set project"
    _use_project "${current}"
    return
  fi

  # 3. 交互式：列出当前账号可见的项目
  local -a ids=() names=()
  local id name
  while IFS=$'\t' read -r id name; do
    [[ -n "${id}" ]] || continue
    ids+=("${id}"); names+=("${name}")
  done < <(gcloud projects list --sort-by=projectId \
             --format="value(projectId,name)" 2>/dev/null || true)

  # list 无权限 ≠ 不能部署：只被授予单个项目权限的账号很常见，降级为手工输入而非报错退出
  if (( ${#ids[@]} == 0 )); then
    log_warn "无法列出项目（当前账号可能缺少 resourcemanager.projects.list 权限）"
    local manual
    read -rp "请直接输入要部署的项目 ID${current:+ [${current}]}: " manual
    _use_project "${manual:-${current}}"
    return
  fi

  echo ""
  echo "请选择要部署的 GCP 项目："
  local i marker default_idx=""
  for i in "${!ids[@]}"; do
    marker=""
    if [[ "${ids[$i]}" == "${current}" ]]; then
      marker="  ← 当前默认"
      default_idx=$(( i + 1 ))
    fi
    printf '  %2d) %-34s %s%s\n' "$(( i + 1 ))" "${ids[$i]}" "${names[$i]}" "${marker}"
  done
  echo ""

  local prompt="输入编号或项目 ID"
  [[ -n "${default_idx}" ]] && prompt+=" [${default_idx}]"
  local input
  read -rp "${prompt}: " input
  input="${input:-${default_idx}}"
  [[ -n "${input}" ]] || die "未选择项目"

  # 纯数字一定是编号：GCP 项目 ID 必须以小写字母开头，不存在全数字的项目 ID
  if [[ "${input}" =~ ^[0-9]+$ ]]; then
    (( input >= 1 && input <= ${#ids[@]} )) || die "编号超出范围: ${input}"
    _use_project "${ids[$(( input - 1 ))]}"
  else
    _use_project "${input}"
  fi
}

# ---------------------------------------------------------------------------
# API 启用（幂等）
# 注意：Gen2 函数依赖 run/eventarc/artifactregistry，缺任何一个部署都会失败
# ---------------------------------------------------------------------------
check_and_enable_apis() {
  local core_apis=(
    "pubsub.googleapis.com"
    "cloudfunctions.googleapis.com"
    "run.googleapis.com"                # Gen2 底座
    "eventarc.googleapis.com"           # Gen2 事件触发器
    "artifactregistry.googleapis.com"   # Gen2 镜像仓库
    "cloudbuild.googleapis.com"
    "secretmanager.googleapis.com"
    "monitoring.googleapis.com"
    "logging.googleapis.com"
    "servicehealth.googleapis.com"      # Personalized Service Health 日志
    "cloudresourcemanager.googleapis.com"
  )
  # 可选数据源的 API 单列：启用失败只影响对应数据源，不该拖垮整个部署
  local optional_apis=()
  [[ "${ENABLE_SCC:-N}" =~ ^[Yy]$ ]]     && optional_apis+=("securitycenter.googleapis.com")
  [[ "${ENABLE_BILLING:-N}" =~ ^[Yy]$ ]] && optional_apis+=("billingbudgets.googleapis.com")

  echo "检查并启用所需 API..."
  local enabled can_list=true
  if ! enabled=$(gcloud services list --enabled --format="value(config.name)" 2>/dev/null); then
    can_list=false
    enabled=""
    log_warn "无法列出已启用的 API（缺 serviceusage.services.list），改为逐个尝试启用"
  fi

  local api
  for api in "${core_apis[@]}"; do
    if grep -qx "${api}" <<<"${enabled}"; then
      log_info "✓ ${api}"
      continue
    fi
    echo "  Enabling ${api}..."
    if gcloud services enable "${api}" 2>/dev/null; then
      continue
    fi
    # 查不到清单时，"enable 失败"与"其实早已由管理员启用"无法区分 ——
    # 此时不能 die，否则会把一个本可成功的部署拦在门外；让后续真实操作去暴露问题。
    if [[ "${can_list}" == "false" ]]; then
      record_skip "启用核心 API ${api}" \
        "若该 API 实际未启用，后续步骤会失败；若已由管理员启用则无影响" \
        "gcloud services enable ${api} --project=${PROJECT_ID}"
      continue
    fi
    die "无法启用核心 API ${api}（需 roles/serviceusage.serviceUsageAdmin）。
   缺少它时后续步骤只会产出一个不工作的空壳，因此中止而非跳过。"
  done

  for api in "${optional_apis[@]}"; do
    if grep -qx "${api}" <<<"${enabled}"; then
      log_info "✓ ${api}"
      continue
    fi
    echo "  Enabling ${api}..."
    if gcloud services enable "${api}" 2>/dev/null; then
      continue
    fi
    record_skip "启用 ${api}" "对应的可选数据源本次不会配置" \
      "gcloud services enable ${api} --project=${PROJECT_ID}"
    # 同时关掉开关：让后续步骤别在缺 API 的前提下继续尝试，徒增噪声
    case "${api}" in
      securitycenter.googleapis.com) ENABLE_SCC=N;     export ENABLE_SCC ;;
      billingbudgets.googleapis.com) ENABLE_BILLING=N; export ENABLE_BILLING ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 显式创建服务代理（P4SA）
# 服务代理是懒创建的：直接对尚不存在的 SA 做 add-iam-policy-binding 会失败，
# 或写入一条永不生效的绑定 —— 这正是"Monitoring 告警静默不发"的典型根因。
# ---------------------------------------------------------------------------
ensure_service_agents() {
  echo "创建服务代理（P4SA）..."
  local svcs=("monitoring.googleapis.com" "pubsub.googleapis.com")
  [[ "${ENABLE_SCC:-N}" =~ ^[Yy]$ ]] && svcs+=("securitycenter.googleapis.com")

  local svc
  for svc in "${svcs[@]}"; do
    soft_step "创建 ${svc} 的服务代理" \
      "该服务代理可能不存在，后续对它的 publisher 授权会写入一条【永不生效】的绑定 → 对应数据源静默无告警" \
      "gcloud beta services identity create --service=${svc} --project=${PROJECT_ID}" \
      -- gcloud beta services identity create --service="${svc}"
  done
  # 服务代理创建后需要几秒才能在 IAM 中被引用，否则后续绑定可能报 SA 不存在
  sleep 5
  return 0
}

# ---------------------------------------------------------------------------
# 通知渠道选择 + 凭据输入（单平台三选一：飞书/Lark、企业微信、钉钉）
#
# 交互模式：菜单 1) 飞书/Lark 2) 企业微信 3) 钉钉（回车 = 飞书，或沿用预置的 NOTIFY_CHANNEL）。
# 非交互模式（--yes / CI）：读环境变量
#   NOTIFY_CHANNEL（默认 feishu）
#   feishu:   FEISHU_WEBHOOK、FEISHU_SECRET
#   wecom:    WECOM_WEBHOOK
#   dingtalk: DINGTALK_WEBHOOK、DINGTALK_SECRET
# 两种模式走同一套校验 —— 否则 CI 能带着空密钥 / 错 URL 部署出一个永远发不出卡片的函数。
#
# 结果写入全局变量（两条部署路径共用，避免各写一份映射）：
#   NOTIFY_CHANNEL        feishu | wecom | dingtalk
#   CHANNEL_LABEL         飞书 | 企业微信 | 钉钉（用户可见文案用）
#   CHANNEL_SECRET_NAMES  本渠道要创建 / 授权的 Secret 名数组
#   CHANNEL_SECRET_ENVS   与上面一一对应的函数环境变量名数组
#   CHANNEL_SET_SECRETS   gcloud --set-secrets 字符串，如 WECOM_DEFAULT_WEBHOOK=wecom-default-webhook:latest
# ---------------------------------------------------------------------------

# Shell 侧严格校验（逐字取自接口契约；飞书沿用下方 _collect_feishu_credentials 里的原有正则）
WECOM_WEBHOOK_RE='^https://qyapi\.weixin\.qq\.com/cgi-bin/webhook/send\?key=[A-Za-z0-9-]+$'
DINGTALK_WEBHOOK_RE='^https://oapi\.dingtalk\.com/robot/send\?access_token=[A-Za-z0-9]+$'

prompt_channel_credentials() {
  if [[ "${ASSUME_YES:-false}" == "true" ]]; then
    NOTIFY_CHANNEL="${NOTIFY_CHANNEL:-feishu}"
  else
    local default_idx=1 choice
    case "${NOTIFY_CHANNEL:-}" in
      wecom)    default_idx=2 ;;
      dingtalk) default_idx=3 ;;
    esac
    echo ""
    echo "请选择通知渠道（每次部署只能选一个，default/security/billing 三类告警都发往该平台）："
    echo "  1) 飞书/Lark"
    echo "  2) 企业微信"
    echo "  3) 钉钉"
    read -rp "输入编号 [${default_idx}]: " choice
    choice="${choice:-${default_idx}}"
    case "${choice}" in
      1|feishu)   NOTIFY_CHANNEL=feishu ;;
      2|wecom)    NOTIFY_CHANNEL=wecom ;;
      3|dingtalk) NOTIFY_CHANNEL=dingtalk ;;
      *)          die "无效的渠道编号: ${choice}（应为 1 / 2 / 3）" ;;
    esac
  fi

  # 保留现有凭据（scripts/configure.sh 选「保持现有凭据」时设置）：不询问、不写 Secret 新版本，
  # 但必须确认本渠道的 Secret 都在且有启用版本 —— 否则新 revision 会因 --set-secrets 解析失败而起不来。
  if [[ "${KEEP_EXISTING_SECRETS:-false}" == "true" ]]; then
    case "${NOTIFY_CHANNEL}" in
      feishu|wecom|dingtalk) ;;
      *) die "NOTIFY_CHANNEL=${NOTIFY_CHANNEL} 无效：只能是 feishu / wecom / dingtalk（未设置时默认 feishu）" ;;
    esac
    set_channel_secret_mapping
    verify_channel_secrets_present
    log_ok "通知渠道：${CHANNEL_LABEL}（NOTIFY_CHANNEL=${NOTIFY_CHANNEL}，KEEP_EXISTING_SECRETS=true：沿用现有凭据）"
    return 0
  fi

  case "${NOTIFY_CHANNEL}" in
    feishu)   _collect_feishu_credentials ;;
    wecom)    _collect_wecom_credentials ;;
    dingtalk) _collect_dingtalk_credentials ;;
    *)        die "NOTIFY_CHANNEL=${NOTIFY_CHANNEL} 无效：只能是 feishu / wecom / dingtalk（未设置时默认 feishu）" ;;
  esac
  set_channel_secret_mapping
  log_ok "通知渠道：${CHANNEL_LABEL}（NOTIFY_CHANNEL=${NOTIFY_CHANNEL}）"
}

# 兼容包装：旧调用方 / 客户自写的包装脚本可能仍调用这个名字。
# 行为 = prompt_channel_credentials（NOTIFY_CHANNEL 未设置时就是飞书，与旧版一致）。
prompt_feishu_credentials() {
  prompt_channel_credentials "$@"
}

# 按 NOTIFY_CHANNEL 设置 Secret 名 ↔ 环境变量映射（不读取、不打印任何密文）。
# CHANNEL_SECRET_SOURCES 记的是【持有密文的 shell 变量名】，upsert_channel_secrets 间接取值，
# 这样密文不会被复制进额外的数组。
set_channel_secret_mapping() {
  CHANNEL_SECRET_NAMES=()
  CHANNEL_SECRET_ENVS=()
  CHANNEL_SECRET_SOURCES=()
  case "${NOTIFY_CHANNEL:-feishu}" in
    feishu)
      CHANNEL_LABEL="飞书"
      CHANNEL_SECRET_ENVS=(FEISHU_DEFAULT_WEBHOOK FEISHU_DEFAULT_SECRET)
      CHANNEL_SECRET_NAMES=("${SECRET_WEBHOOK_NAME}" "${SECRET_SIGN_NAME}")
      CHANNEL_SECRET_SOURCES=(FEISHU_WEBHOOK FEISHU_SECRET)
      ;;
    wecom)
      CHANNEL_LABEL="企业微信"
      CHANNEL_SECRET_ENVS=(WECOM_DEFAULT_WEBHOOK)
      CHANNEL_SECRET_NAMES=("${SECRET_WECOM_WEBHOOK_NAME}")
      CHANNEL_SECRET_SOURCES=(WECOM_WEBHOOK)
      ;;
    dingtalk)
      CHANNEL_LABEL="钉钉"
      CHANNEL_SECRET_ENVS=(DINGTALK_DEFAULT_WEBHOOK DINGTALK_DEFAULT_SECRET)
      CHANNEL_SECRET_NAMES=("${SECRET_DINGTALK_WEBHOOK_NAME}" "${SECRET_DINGTALK_SIGN_NAME}")
      CHANNEL_SECRET_SOURCES=(DINGTALK_WEBHOOK DINGTALK_SECRET)
      ;;
    *)
      die "NOTIFY_CHANNEL=${NOTIFY_CHANNEL} 无效：只能是 feishu / wecom / dingtalk"
      ;;
  esac
  CHANNEL_SET_SECRETS=""
  local i
  for i in "${!CHANNEL_SECRET_NAMES[@]}"; do
    CHANNEL_SET_SECRETS+="${CHANNEL_SET_SECRETS:+,}${CHANNEL_SECRET_ENVS[$i]}=${CHANNEL_SECRET_NAMES[$i]}:latest"
  done
  export NOTIFY_CHANNEL CHANNEL_LABEL CHANNEL_SET_SECRETS
}

# 只写入所选渠道的 Secret（幂等：已存在则追加新版本，见 upsert_secret）。两条部署路径共用。
upsert_channel_secrets() {
  local i src
  if [[ "${KEEP_EXISTING_SECRETS:-false}" == "true" ]]; then
    # 存在性已在 prompt_channel_credentials → verify_channel_secrets_present 中校验
    log_info "KEEP_EXISTING_SECRETS=true：沿用现有 Secret（${CHANNEL_SECRET_NAMES[*]}），不追加新版本"
    return 0
  fi
  for i in "${!CHANNEL_SECRET_NAMES[@]}"; do
    src="${CHANNEL_SECRET_SOURCES[$i]}"
    upsert_secret "${CHANNEL_SECRET_NAMES[$i]}" "${!src}"
  done
}

# 企业微信群机器人：无签名，凭据就是 URL 里的 key（务必当作密钥保管）。
_collect_wecom_credentials() {
  if [[ "${ASSUME_YES:-false}" == "true" ]]; then
    [[ -n "${WECOM_WEBHOOK:-}" ]] || \
      die "--yes 模式下 NOTIFY_CHANNEL=wecom 必须通过环境变量提供 WECOM_WEBHOOK"
  else
    read -rp "请输入企业微信群机器人 Webhook URL: " WECOM_WEBHOOK
  fi
  if [[ ! "${WECOM_WEBHOOK}" =~ ${WECOM_WEBHOOK_RE} ]]; then
    echo "错误：无效的企业微信 Webhook URL。应形如" >&2
    echo "  https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" >&2
    echo "（在群聊 → 群机器人 / 消息推送 → 添加机器人后复制；不要带多余参数或空格）" >&2
    exit 1
  fi
  export WECOM_WEBHOOK
}

# 钉钉自定义机器人：安全设置三选一（加签 / 自定义关键词 / IP 地址段）。
# DINGTALK_SECRET 必填：加签模式填 SEC 开头的密钥；未开启加签显式填 NONE。
# 空值一律拒绝 —— 与飞书同理，"忘了填"和"有意不签名"必须能区分开。
_collect_dingtalk_credentials() {
  if [[ "${ASSUME_YES:-false}" == "true" ]]; then
    [[ -n "${DINGTALK_WEBHOOK:-}" && -n "${DINGTALK_SECRET:-}" ]] || \
      die "--yes 模式下 NOTIFY_CHANNEL=dingtalk 必须通过环境变量提供 DINGTALK_WEBHOOK 与 DINGTALK_SECRET（未开启加签请显式填 NONE）"
  else
    read -rp "请输入钉钉自定义机器人 Webhook URL: " DINGTALK_WEBHOOK
    read -rsp "请输入加签密钥（SEC 开头；未开启加签请输入 NONE）: " DINGTALK_SECRET
    echo
  fi
  if [[ ! "${DINGTALK_WEBHOOK}" =~ ${DINGTALK_WEBHOOK_RE} ]]; then
    echo "错误：无效的钉钉 Webhook URL。应形如" >&2
    echo "  https://oapi.dingtalk.com/robot/send?access_token=xxxxxxxx" >&2
    echo "（不要把 &timestamp=…&sign=… 拼进来：签名由函数在每次发送时实时计算）" >&2
    exit 1
  fi
  if [[ -z "${DINGTALK_SECRET}" ]]; then
    echo "错误：钉钉加签密钥不能为空。未开启加签请显式输入 NONE。" >&2
    exit 1
  fi
  if [[ "${DINGTALK_SECRET}" =~ [[:space:]] ]]; then
    # 粘贴时带进来的空格 / 换行会让每一次签名都算错 → 钉钉 errcode=310000，全部卡片被拒
    echo "错误：钉钉加签密钥中含有空白字符（多半是复制粘贴带入的），请重新输入。" >&2
    exit 1
  fi
  if [[ "${DINGTALK_SECRET}" == "NONE" ]]; then
    log_warn "钉钉未使用加签（DINGTALK_SECRET=NONE）。推荐在机器人安全设置中开启「加签」。"
    echo "    若改用「自定义关键词」，关键词必须设为：GCP告警（卡片标题固定以它开头，其它关键词会让全部卡片被拒）" >&2
    echo "    「IP 地址（段）」需要固定出口 IP，本方案默认的函数出口 IP 不固定，不建议单独使用" >&2
  elif [[ ! "${DINGTALK_SECRET}" =~ ^SEC[A-Za-z0-9]+$ ]]; then
    # 只警告不拦截：官方说明密钥以 SEC 开头，但未公布完整格式，硬拦可能误伤合法密钥
    log_warn "钉钉加签密钥通常以 SEC 开头，当前输入不像加签密钥；若有误，所有卡片会被钉钉以 errcode=310000 拒绝"
  fi
  export DINGTALK_WEBHOOK DINGTALK_SECRET
}

# ---------------------------------------------------------------------------
# 发送速率（MAX_SENDS_PER_MINUTE）按渠道取默认值并校验上限
#
# 令牌桶是【每实例】的，而群机器人的限额是【每群】的：飞书 100 条/分钟；
# 企业微信、钉钉 20 条/分钟（钉钉超限还会封禁 10 分钟）。因此要求
#   速率 × MAX_INSTANCES ≤ 上限（飞书 80 / 企业微信 16 / 钉钉 16，即平台限额预留 20% 余量）
# 与 Terraform 的 precondition 同一口径。两条部署脚本都在建任何资源之前调用。
# ---------------------------------------------------------------------------
channel_default_rate() {
  case "${1:-}" in
    feishu)         echo 40 ;;
    wecom|dingtalk) echo 8 ;;
    *)              return 1 ;;
  esac
}

channel_rate_cap() {
  case "${1:-}" in
    feishu)         echo 80 ;;
    wecom|dingtalk) echo 16 ;;
    *)              return 1 ;;
  esac
}

channel_min_retry_delay() {
  case "${1:-}" in
    dingtalk)       echo "80s" ;;
    feishu|wecom|*) echo "10s" ;;
  esac
}

# 结果写入全局 MAX_SENDS_PER_MINUTE（未设置时取渠道默认值）与
# MAX_SENDS_PER_MINUTE_EXPLICIT（true = 来自环境变量；Terraform 路径据此决定是否写进 tfvars）。
validate_channel_rate_limit() {
  local ch="${NOTIFY_CHANNEL:-feishu}" default cap
  default=$(channel_default_rate "${ch}") || die "NOTIFY_CHANNEL=${ch} 无效：只能是 feishu / wecom / dingtalk"
  cap=$(channel_rate_cap "${ch}")

  if [[ -n "${MAX_SENDS_PER_MINUTE:-}" ]]; then
    MAX_SENDS_PER_MINUTE_EXPLICIT=true
  else
    MAX_SENDS_PER_MINUTE="${default}"
    MAX_SENDS_PER_MINUTE_EXPLICIT=false
  fi
  # 0 会让函数部署成功却永远不发任何卡片（静默失效），必须拦下
  [[ "${MAX_SENDS_PER_MINUTE}" =~ ^[1-9][0-9]{0,5}$ ]] || \
    die "MAX_SENDS_PER_MINUTE=${MAX_SENDS_PER_MINUTE} 无效：必须是正整数（${CHANNEL_LABEL:-${ch}} 默认 ${default}）"
  [[ "${MAX_INSTANCES}" =~ ^[1-9][0-9]{0,3}$ ]] || \
    die "MAX_INSTANCES=${MAX_INSTANCES} 无效：必须是正整数（默认 2）"

  if (( MAX_SENDS_PER_MINUTE * MAX_INSTANCES > cap )); then
    local ban_note=""
    [[ "${ch}" == "dingtalk" ]] && ban_note="（钉钉超限会封禁 10 分钟）"
    die "发送速率超出 ${CHANNEL_LABEL:-${ch}} 群机器人限额：MAX_SENDS_PER_MINUTE(${MAX_SENDS_PER_MINUTE}) × MAX_INSTANCES(${MAX_INSTANCES}) = $(( MAX_SENDS_PER_MINUTE * MAX_INSTANCES )) > ${cap}。
   超限的消息会被平台拒绝${ban_note}。请调低 MAX_SENDS_PER_MINUTE（${CHANNEL_LABEL:-${ch}} 默认 ${default}）或 MAX_INSTANCES；
   若是从其它渠道切换过来，请 unset MAX_SENDS_PER_MINUTE 以使用渠道默认值。"
  fi
  export MAX_SENDS_PER_MINUTE MAX_SENDS_PER_MINUTE_EXPLICIT MAX_INSTANCES
}

# ---------------------------------------------------------------------------
# 交互式输入飞书凭据（掩码输入）
# 非交互模式（--yes / CI）下改从 FEISHU_WEBHOOK / FEISHU_SECRET 环境变量取值，
# 校验逻辑两种模式完全一致 —— 否则 CI 能带着空密钥部署出一个永远发不出卡片的函数。
# （原 prompt_feishu_credentials 的实现，校验与报错文案保持不变；现由
#  prompt_channel_credentials 在 NOTIFY_CHANNEL=feishu 时调用。）
# ---------------------------------------------------------------------------
_collect_feishu_credentials() {
  if [[ "${ASSUME_YES:-false}" == "true" ]]; then
    [[ -n "${FEISHU_WEBHOOK:-}" && -n "${FEISHU_SECRET:-}" ]] || \
      die "--yes 模式下必须通过环境变量提供 FEISHU_WEBHOOK 与 FEISHU_SECRET"
  else
    read -rp "请输入飞书/Lark Webhook URL: " FEISHU_WEBHOOK
    read -rsp "请输入签名密钥（未开启签名校验请输入 NONE）: " FEISHU_SECRET
    echo
  fi

  # 同时支持飞书国内版与 Lark 国际版（跨国企业场景）
  local feishu_re='^https://open\.feishu\.cn/open-apis/bot/v2/hook/[A-Za-z0-9-]+$'
  local lark_re='^https://open\.larksuite\.com/open-apis/bot/v2/hook/[A-Za-z0-9-]+$'
  if [[ ! "${FEISHU_WEBHOOK}" =~ ${feishu_re} && ! "${FEISHU_WEBHOOK}" =~ ${lark_re} ]]; then
    echo "错误：无效的 Webhook URL。应形如" >&2
    echo "  https://open.feishu.cn/open-apis/bot/v2/hook/xxxxxxxx   （飞书）" >&2
    echo "  https://open.larksuite.com/open-apis/bot/v2/hook/xxxxxxxx（Lark）" >&2
    exit 1
  fi
  if [[ -z "${FEISHU_SECRET}" ]]; then
    echo "错误：签名密钥不能为空。未开启签名校验请显式输入 NONE。" >&2
    echo "（空密钥会导致所有卡片被飞书以 sign match fail 拒绝，且 HTTP 状态码仍是 200）" >&2
    exit 1
  fi
}

# 可选数据源与推荐告警包开关：
# - PSH（Personalized Service Health 两类官方推荐策略）默认自动开启（可通过 ENABLE_PSH=N 显式关闭）
# - 推荐默认监控告警包（GCE/配额/LB&NAT/GKE&SQL/高危IAM审计）交互式询问，--yes 下沿用环境变量（默认 N）
# - OPS_EMAIL：自监控告警（IM 链路自身故障：永久发送失败 / DLQ 积压）的邮件收件人。
#   IM 平台（飞书/企业微信/钉钉）坏掉的时候不能再靠它报警，所以这条通道必须是邮件。留空允许，但会登记为跳过项。
# 交互 y/n：已沿用线上值时回车 = 沿用；必须作答（Terraform 模式现状未知）时没有默认值。
_ask_optional_yn() {
  local var=$1 prompt=$2 ans norm try def=""
  _optional_must_ask "${var}" || def="${!var:-}"
  for try in 1 2 3; do
    if [[ -n "${def}" ]]; then
      read -rp "${prompt}(y/n，回车沿用线上：${def}): " ans || ans=""
      ans="${ans:-${def}}"
    else
      read -rp "${prompt}(y/n，现状未知，必须作答): " ans || ans=""
    fi
    if norm=$(normalize_yn "${ans}"); then printf -v "${var}" '%s' "${norm}"; return 0; fi
    log_warn "请输入 y 或 n"
  done
  die "连续 3 次输入无效，已取消（未创建任何资源）"
}

prompt_optional_sources() {
  ENABLE_PSH="${ENABLE_PSH:-Y}"
  if [[ "${ASSUME_YES:-false}" == "true" ]]; then
    ENABLE_DEFAULT_ALERTS="${ENABLE_DEFAULT_ALERTS:-N}"
    ENABLE_SCC="${ENABLE_SCC:-N}"
    ENABLE_BILLING="${ENABLE_BILLING:-N}"
    OPS_EMAIL="${OPS_EMAIL:-}"
  else
    # 重跑时（函数已存在）以线上现状作回车默认值；Terraform 模式下现状未知的项必须作答。
    _optional_must_ask ENABLE_PSH && _ask_optional_yn ENABLE_PSH "是否部署默认 PSH 官方两类告警策略？"
    if _optional_is_inherited ENABLE_DEFAULT_ALERTS || _optional_must_ask ENABLE_DEFAULT_ALERTS; then
      _ask_optional_yn ENABLE_DEFAULT_ALERTS "是否一键部署推荐默认监控告警包（GCE/配额/LB&NAT/GKE&SQL/IAM审计）？"
    else
      read -rp "是否一键部署推荐默认监控告警包（GCE/配额/LB&NAT/GKE&SQL/IAM审计）？(y/N): " ENABLE_DEFAULT_ALERTS
      ENABLE_DEFAULT_ALERTS=${ENABLE_DEFAULT_ALERTS:-N}
    fi
    if _optional_is_inherited ENABLE_SCC || _optional_must_ask ENABLE_SCC; then
      _ask_optional_yn ENABLE_SCC "是否启用 SCC 安全中心导出？"
    else
      read -rp "是否启用 SCC 安全中心导出？(y/N): " ENABLE_SCC;    ENABLE_SCC=${ENABLE_SCC:-N}
    fi
    if _optional_is_inherited ENABLE_BILLING || _optional_must_ask ENABLE_BILLING; then
      _ask_optional_yn ENABLE_BILLING "是否启用 Billing 预算告警？"
    else
      read -rp "是否启用 Billing 预算告警？(y/N): " ENABLE_BILLING; ENABLE_BILLING=${ENABLE_BILLING:-N}
    fi
    if _optional_must_ask OPS_EMAIL; then
      read -rp "无法读取线上自监控收件邮箱，请输入运维通知邮箱（留空 = 关闭自监控）: " OPS_EMAIL
    elif [[ -z "${OPS_EMAIL:-}" ]]; then
      read -rp "运维通知邮箱（IM 链路自身故障时的兜底收件人，留空跳过）: " OPS_EMAIL
    fi
  fi
  OPS_EMAIL="${OPS_EMAIL//[[:space:]]/}"
  if [[ -n "${OPS_EMAIL}" && ! "${OPS_EMAIL}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
    log_warn "OPS_EMAIL 格式不像邮箱地址（${OPS_EMAIL}），本次忽略；自监控告警将被跳过"
    OPS_EMAIL=""
  fi
  export ENABLE_PSH ENABLE_DEFAULT_ALERTS ENABLE_SCC ENABLE_BILLING OPS_EMAIL
}

# ---------------------------------------------------------------------------
# 告警策略模板幂等部署（先按 displayName 查，存在则 update，不存在则 create）
# ---------------------------------------------------------------------------
upsert_alert_policy_from_template() {
  local template_file=$1
  local display_name=$2
  local remedy=$3

  local policy_file
  # mktemp 的 X 后面不能带后缀：macOS/BSD mktemp 不认，客户在 Mac 上会在此硬退出
  policy_file=$(mktemp "${TMPDIR:-/tmp}/monitoring-policy.XXXXXX")
  # documentation 文案按所选渠道显示（飞书 / 企业微信 / 钉钉）；未经 prompt_channel_credentials 时用中性措辞
  export CHANNEL_LABEL="${CHANNEL_LABEL:-IM 机器人}"
  envsubst < "${template_file}" > "${policy_file}"

  # 只匹配真正的变量引用 ${NAME}，并排除注释行
  if grep -vE '^[[:space:]]*#' "${policy_file}" | grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*\}'; then
    rm -f "${policy_file}"
    die "告警策略模板 ${template_file} 存在未替换的变量，请检查 export（CHANNEL_ID / EMAIL_CHANNEL_ID / PROJECT_ID / FUNCTION_NAME / DLQ_SUBSCRIPTION_NAME）"
  fi

  local existing_policy
  existing_policy=$(gcloud beta monitoring policies list \
    --filter="displayName='${display_name}'" --format="value(name)" 2>/dev/null | head -1 || true)
  if [[ -n "${existing_policy}" ]]; then
    if gcloud beta monitoring policies update "${existing_policy}" \
         --policy-from-file="${policy_file}" >/dev/null 2>&1; then
      log_ok "告警策略已更新：${display_name}"
    else
      record_skip "更新告警策略「${display_name}」" "该告警策略仍沿用旧配置" "${remedy}"
    fi
  else
    if gcloud beta monitoring policies create --policy-from-file="${policy_file}" >/dev/null 2>&1; then
      log_ok "告警策略已创建：${display_name}"
    else
      record_skip "创建告警策略「${display_name}」" "该监控告警未生效，相关事件不会触发通知" "${remedy}"
    fi
  fi
  rm -f "${policy_file}"
}

# 告警策略类步骤共用的补救命令（需 DEPLOYER_MEMBER 已由 resolve_deployer_member 解析）
_alert_policy_remedy() {
  echo "gcloud projects add-iam-policy-binding ${PROJECT_ID} --member=\"${DEPLOYER_MEMBER:-'<你的账号>'}\" --role=roles/monitoring.alertPolicyEditor && gcloud projects add-iam-policy-binding ${PROJECT_ID} --member=\"${DEPLOYER_MEMBER:-'<你的账号>'}\" --role=roles/logging.configWriter"
}

# 部署默认 Personalized Service Health (PSH) 官方推荐策略集 —— 两类：
# 已确认故障（INCIDENT）与新兴故障（EMERGING）。
# 不部署「计划维护」「安全公告」：PSH 事件日志（servicehealth.googleapis.com/activity）的 category 枚举只有 INCIDENT，
# 那两条策略在这个数据源上永远不会触发 —— 客户以为有覆盖、实际没有，正是本项目最反对的静默失效。
deploy_psh_alert_policies() {
  local sh_remedy
  sh_remedy=$(_alert_policy_remedy)

  if [[ ! "${ENABLE_PSH:-Y}" =~ ^[Yy]$ ]]; then
    log_info "已通过 ENABLE_PSH=${ENABLE_PSH} 跳过默认 PSH 告警策略部署"
    return 0
  fi

  if [[ -z "${CHANNEL_ID:-}" ]]; then
    record_skip "创建默认 PSH（Personalized Service Health）告警策略集" \
      "Service Health 数据源不通。此处刻意不创建无渠道的策略：那会在控制台里显示为一条正常策略，却永远不发通知" \
      "先补齐 Notification Channel 权限，再重跑本脚本"
    return 0
  fi

  echo "配置默认 PSH（Personalized Service Health）官方推荐策略集（两类）..."
  upsert_alert_policy_from_template \
    "${REPO_ROOT}/templates/service-health-alert-policy.yaml" \
    "${PSH_POLICY_DISPLAY_NAMES[0]}" \
    "${sh_remedy}"
  upsert_alert_policy_from_template \
    "${REPO_ROOT}/templates/psh-emerging-incident-policy.yaml" \
    "${PSH_POLICY_DISPLAY_NAMES[1]}" \
    "${sh_remedy}"
}

# 部署推荐的默认高级监控告警包（GCE / 配额 / LB & NAT / GKE & Cloud SQL / 高危 IAM 审计）
deploy_recommended_default_alerts() {
  if [[ ! "${ENABLE_DEFAULT_ALERTS:-N}" =~ ^[Yy]$ ]]; then
    return 0
  fi

  local alert_remedy
  alert_remedy=$(_alert_policy_remedy)

  if [[ -z "${CHANNEL_ID:-}" ]]; then
    record_skip "创建推荐默认监控告警包" \
      "缺少 Notification Channel，推荐默认告警策略无法绑定通知渠道" \
      "先补齐 Notification Channel 权限，再重跑本脚本"
    return 0
  fi

  echo "配置推荐默认监控告警包（GCE / 配额 / 网络 / GKE & SQL / 安全审计）..."
  # 清单在文件顶部的 DEFAULT_ALERT_POLICY_SPECS：与 teardown 共用，别在这里另写一份
  local entry tpl_rel policy_title
  for entry in "${DEFAULT_ALERT_POLICY_SPECS[@]}"; do
    IFS='|' read -r tpl_rel policy_title <<<"${entry}"
    upsert_alert_policy_from_template "${REPO_ROOT}/${tpl_rel}" "${policy_title}" "${alert_remedy}"
  done
}

# ---------------------------------------------------------------------------
# 自监控告警（"监控的监控"）—— gcloud 路径
#
# 本项目最怕的失效形态是"部署成功、日志无错、群里没卡片"。两种情况函数自己已经知道
# 却没人会收到通知：
#   1. 永久发送失败（webhook 失效 / 签名错）→ 函数 ack + ERROR 日志 reason=permanent_send_failure；
#   2. 消息进了 DLQ（连续 5 次失败）。
# 这两条告警必须走【邮件】：IM 平台本身就是坏掉的那一环，不能再把告警发回 IM 群。
# 模板由 templates/self-monitoring-*.yaml 提供，变量：
#   ${PROJECT_ID} ${FUNCTION_NAME} ${DLQ_SUBSCRIPTION_NAME} ${EMAIL_CHANNEL_ID}
# Terraform 路径由 .tf 实现同样两条策略（变量 ops_email），本函数只给 gcloud 路径调用。
# ---------------------------------------------------------------------------
deploy_self_monitoring_alerts() {
  local alert_remedy
  alert_remedy=$(_alert_policy_remedy)

  if [[ -z "${OPS_EMAIL:-}" && "${OPS_EMAIL_UNKNOWN_KEEP:-false}" == "true" ]]; then
    log_info "无法读取自监控现状：本次保持不动（不创建也不删除）；如需变更请显式设置 OPS_EMAIL"
    return 0
  fi
  if [[ -z "${OPS_EMAIL:-}" ]]; then
    record_skip "创建自监控告警（永久发送失败 / DLQ 积压）" \
      "IM 链路自身故障时【无人知晓】：webhook 失效、消息进 DLQ 都只会留在日志里" \
      "重跑本脚本并在提示处填写运维邮箱（或预置环境变量 OPS_EMAIL=ops@example.com）"
    return 0
  fi

  local tpl_failure="${REPO_ROOT}/templates/self-monitoring-permanent-failure.yaml"
  local tpl_dlq="${REPO_ROOT}/templates/self-monitoring-dlq-depth.yaml"
  if [[ ! -f "${tpl_failure}" || ! -f "${tpl_dlq}" ]]; then
    record_skip "创建自监控告警（永久发送失败 / DLQ 积压）" \
      "缺少模板文件 templates/self-monitoring-*.yaml，自监控告警未部署" \
      "确认制品完整（重新拉取最新版本）后重跑本脚本"
    return 0
  fi

  echo "配置自监控告警（收件人 ${OPS_EMAIL}）..."

  # 1. 邮件类型 Notification Channel（幂等：按 displayName + type 查，查询失败不建）
  #    过滤器字面量必须用双引号：channels 的 filter 语法不接受单引号。
  local query_ok=true
  EMAIL_CHANNEL_ID=$(gcloud beta monitoring channels list \
    --filter="displayName=\"${OPS_EMAIL_CHANNEL_DISPLAY_NAME}\" AND type=\"email\"" \
    --format="value(name)" 2>/dev/null | head -1) || query_ok=false
  if [[ "${query_ok}" != "true" ]]; then
    record_skip "创建 / 复用自监控邮件渠道" \
      "无法确认渠道是否已存在，为避免重复渠道本次不创建；自监控告警未部署" \
      "确认已有 roles/monitoring.notificationChannelEditor 后重跑本脚本（幂等）"
    EMAIL_CHANNEL_ID=""
    return 0
  fi
  if [[ -n "${EMAIL_CHANNEL_ID}" ]]; then
    # 收件人可能换了：按最新输入刷新 labels，让"重跑换邮箱"真正生效
    if gcloud beta monitoring channels update "${EMAIL_CHANNEL_ID}" \
         --update-channel-labels="email_address=${OPS_EMAIL}" >/dev/null 2>&1; then
      log_ok "自监控邮件渠道已存在，收件人已同步为 ${OPS_EMAIL}"
    else
      log_warn "自监控邮件渠道已存在，但未能更新收件人（可能仍指向旧邮箱）"
    fi
  else
    EMAIL_CHANNEL_ID=$(gcloud beta monitoring channels create \
      --type=email \
      --display-name="${OPS_EMAIL_CHANNEL_DISPLAY_NAME}" \
      --channel-labels="email_address=${OPS_EMAIL}" \
      --format="value(name)" 2>/dev/null || true)
    if [[ -n "${EMAIL_CHANNEL_ID}" ]]; then
      log_ok "自监控邮件渠道已创建"
    else
      record_skip "创建自监控邮件渠道「${OPS_EMAIL_CHANNEL_DISPLAY_NAME}」" \
        "自监控告警无处可发；IM 链路故障时无人知晓" \
        "gcloud projects add-iam-policy-binding ${PROJECT_ID} --member=\"${DEPLOYER_MEMBER}\" --role=roles/monitoring.notificationChannelEditor"
      return 0
    fi
  fi
  # envsubst 只替换已导出的变量
  export EMAIL_CHANNEL_ID PROJECT_ID FUNCTION_NAME DLQ_SUBSCRIPTION_NAME

  # 2. 两条策略（displayName 与 SELF_MONITORING_POLICY_DISPLAY_NAMES / teardown 对齐）
  upsert_alert_policy_from_template "${tpl_failure}" \
    "${SELF_MONITORING_POLICY_DISPLAY_NAMES[0]}" "${alert_remedy}"
  upsert_alert_policy_from_template "${tpl_dlq}" \
    "${SELF_MONITORING_POLICY_DISPLAY_NAMES[1]}" "${alert_remedy}"
}

# ---------------------------------------------------------------------------
# Secret 写入（幂等且不静默保留旧值）
# `gcloud secrets create ... || true` 会在重跑换新 webhook 时静默沿用旧值 ——
# 用户以为改了群，实际卡片仍发往旧群，且没有任何提示。
# ---------------------------------------------------------------------------
upsert_secret() {
  local name=$1 value=$2
  if gcloud secrets describe "${name}" >/dev/null 2>&1; then
    printf '%s' "${value}" | gcloud secrets versions add "${name}" --data-file=- >/dev/null
    echo "  ↻ ${name}: 已追加新版本"
  else
    printf '%s' "${value}" | gcloud secrets create "${name}" \
      --replication-policy=automatic --data-file=- >/dev/null
    echo "  + ${name}: 已创建"
  fi
}

# ---------------------------------------------------------------------------
# 自检流程
# ---------------------------------------------------------------------------
run_self_test() {
  local PROJECT_ID=$1
  local TOPIC=$2

  echo ""
  echo "==== 部署自检 ===="
  echo "发送自检消息..."

  # 注意：gcloud pubsub topics publish 会自行对 --message 做 base64 编码。
  # 此处再手工 base64 会导致函数侧 b64decode 后拿到的仍是 base64 文本，
  # json.loads 必然失败（且 GNU base64 默认 76 字符换行会进一步破坏消息）。
  local payload
  payload=$(cat <<EOF
{
  "type": "test_event",
  "project_id": "${PROJECT_ID}",
  "deployment_time": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "version": "1.1.0",
  "components": {
    "pubsub": "healthy",
    "cloud_functions": "healthy",
    "secret_manager": "healthy"
  }
}
EOF
)

  # 自检开始时间：日志判定要以它为时间下界，否则 10 分钟内任何一条真实告警、
  # 或上一次部署留下的 'Alert delivered' 都会把本次自检判成通过（假阳性）。
  # 往前留 60 秒余量，容忍本机与 Cloud Logging 之间的时钟偏差。
  local start_ts
  start_ts=$(date -u -d '-60 seconds' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -v-60S '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u '+%Y-%m-%dT%H:%M:%SZ')

  # 本函数常以 `run_self_test … || SELF_TEST_OK=false` 的形式被调用，此时函数体内
  # set -e 失效 —— publish 失败（部署者没有 pubsub.publisher）不会中断，而是静默
  # 空等 150 秒后给出"函数从未被触发"的错误诊断。必须显式判断。
  if ! gcloud pubsub topics publish "${TOPIC}" \
       --message="${payload}" \
       --attribute="source=self-test,timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; then
    log_error "自检消息发布失败：当前身份无法向 ${TOPIC} 发布消息"
    echo "   补救：gcloud pubsub topics add-iam-policy-binding ${TOPIC} --member=\"${DEPLOYER_MEMBER:-'<你的账号>'}\" --role=roles/pubsub.publisher --project=${PROJECT_ID}"
    echo "   （这只影响自检本身；告警数据源走的是各自的服务代理，不受此权限影响）"
    return 1
  fi

  echo ""
  # 这里【必须轮询】，不能固定 sleep 一次就判定。
  #
  # 脚本在几十秒前刚授完 run.invoker，而 IAM 绑定有传播延迟。传播完成前 Eventarc 的
  # 投递会被 403 拒绝，Pub/Sub 按退避重试（实测间隔 10s → 13s → 17s），整条链路
  # 通常在 40-60 秒后自愈。原先固定 sleep 30 正好卡在传播中间，把一次【本来成功的
  # 部署】报成失败 —— 实测时间线：
  #   12:02:49 / 12:03:02 / 12:03:19 三次 403，自检在此放弃，12:03:40 投递成功。
  local -i waited=0 interval=10 max_wait=150
  local delivered="" log_read_failed=false
  # 只认【本次】自检的投递记录：timestamp 下界 + alert_type=test_event
  # （main.py 在 'Alert delivered' 的 extra 里带 alert_type，落到 jsonPayload.alert_type）。
  local delivered_filter="resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"${FUNCTION_NAME}\" AND jsonPayload.message=\"Alert delivered\" AND jsonPayload.alert_type=\"test_event\" AND timestamp>=\"${start_ts}\""
  echo -n "⏳ 等待投递结果（最多 ${max_wait} 秒，成功即提前结束）"
  while (( waited < max_wait )); do
    sleep "${interval}"; waited=$(( waited + interval )); echo -n "."
    if ! delivered=$(gcloud logging read "${delivered_filter}" \
      --freshness=10m --limit=1 --format='value(timestamp)' 2>/dev/null); then
      log_read_failed=true
      break
    fi
    [[ -n "${delivered}" ]] && break
  done
  echo ""

  # 判定顺序：先找【正向证据】，找不到再去日志里诊断原因。
  #
  # 反过来做会两头不准：
  #   - 只查 ERROR 会漏掉"投递被 Eventarc 拒绝"（那记的是 WARNING，函数根本没被调用，
  #     不可能有 ERROR）—— 链路全断却报"未发现错误"；
  #   - 只要见到 WARNING 就判失败，又会被 "Empty Authorization header" 这类
  #     无认证探测请求的噪声误伤 —— 卡片明明送到了却报失败。
  # 唯一可靠的成功信号是函数自己记的 'Alert delivered'。
  local dlq_depth
  dlq_depth=$(gcloud pubsub subscriptions describe "${DLQ_SUBSCRIPTION}" \
    --format='value(name)' >/dev/null 2>&1 && echo ok || echo missing)

  if [[ "${log_read_failed}" == "true" ]]; then
    record_skip "自检：读取函数日志" \
      "无法自动判定投递成败，需人工确认${CHANNEL_LABEL:-IM}群是否收到自检卡片" \
      "gcloud projects add-iam-policy-binding ${PROJECT_ID} --member=\"${DEPLOYER_MEMBER:-'<你的账号>'}\" --role=roles/logging.viewer"
    echo "   请人工确认${CHANNEL_LABEL:-IM}群已收到：🟢 [GCP 监控告警中心] 连通性自检成功"
    return 0
  fi

  if [[ -n "${delivered}" ]]; then
    log_ok "自检通过：已确认投递成功（Alert delivered @ ${delivered}，DLQ 订阅状态：${dlq_depth}）"
    echo "   ${CHANNEL_LABEL:-IM}群应已收到卡片：🟢 [GCP 监控告警中心] 连通性自检成功"
    return 0
  fi

  # 到这里说明没有成功投递记录 —— 拉 WARNING 以上日志判断卡在哪一环
  log_error "自检失败：${max_wait} 秒内未找到 'Alert delivered'（DLQ 订阅状态：${dlq_depth}）"
  local logs
  logs=$(gcloud logging read \
    "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"${FUNCTION_NAME}\" AND severity>=WARNING" \
    --freshness=10m --limit=20 --format='value(severity,textPayload,jsonPayload.message,jsonPayload.reason,jsonPayload.channel,jsonPayload.platform_code,jsonPayload.http_status)' 2>/dev/null || true)

  # 投递权限问题单独识别：它的表征最像"一切正常"，必须给出确切的补救命令。
  # 只匹配 run.routes.invoke —— 泛匹配 "was not authenticated" 会命中无关的
  # "Empty Authorization header" 噪声。
  if grep -qF 'run.routes.invoke' <<<"${logs}"; then
    # 看到 403 【不等于】绑定缺失。必须实测一次再下结论：
    # 原先无条件断言"缺 run.invoker"，会让用户去重授一条【已经存在】的绑定，
    # 重授不报错、也不解决问题，于是把人引向完全错误的排查方向。
    # 触发器身份：gcloud 路径由 deploy-gcloud.sh 导出 INVOKER_SA（= --trigger-service-account，
    # 自定义 SA 创建失败时回落默认 compute SA）；Terraform 路径固定为函数 SA。
    # 查错 SA 会得出"绑定缺失"的错误结论，把人引向重授一条已存在的绑定。
    local invoker_sa="${INVOKER_SA:-${SERVICE_ACCOUNT_ID}@${PROJECT_ID}.iam.gserviceaccount.com}"
    local binding_exists=false
    if gcloud run services get-iam-policy "${FUNCTION_NAME}" \
         --region="${REGION:-}" --format="value(bindings.role,bindings.members)" 2>/dev/null \
         | grep -F 'roles/run.invoker' | grep -qF "${invoker_sa}"; then
      binding_exists=true
    elif gcloud projects get-iam-policy "${PROJECT_ID}" --flatten="bindings[].members" \
           --filter="bindings.role=roles/run.invoker AND bindings.members:${invoker_sa}" \
           --format="value(bindings.role)" 2>/dev/null | grep -q .; then
      binding_exists=true
    fi

    if [[ "${binding_exists}" == "true" ]]; then
      echo "   原因：run.invoker 绑定【已经存在】，日志里的 403 是 IAM 传播尚未完成。"
      echo "         这不是配置错误 —— 重复授权不会让它更快生效，请不要重授。"
      echo "   处理：等 1-2 分钟后重跑部署脚本（幂等）确认，或直接查证："
      echo "           gcloud logging read 'resource.labels.service_name=\"${FUNCTION_NAME}\"" \
           "AND jsonPayload.message=\"Alert delivered\"' --freshness=10m --limit=5 --project=${PROJECT_ID}"
      echo "         若${CHANNEL_LABEL:-IM}群里已经收到自检卡片，则本次部署实际是成功的。"
    else
      echo "   原因：Eventarc 无法调用函数 —— 触发器身份确实缺 run.invoker，函数从未被执行"
      echo "   补救：gcloud run services add-iam-policy-binding ${FUNCTION_NAME} \\"
      echo "           --region=${REGION:-<region>} --project=${PROJECT_ID} \\"
      echo "           --member=serviceAccount:${invoker_sa} \\"
      echo "           --role=roles/run.invoker"
    fi
    return 1
  fi

  local errors
  errors=$(grep -E '^ERROR|^CRITICAL' <<<"${logs}" || true)
  if [[ -n "${errors}" ]]; then
    echo "   函数日志中的错误（severity / message / reason / channel / platform_code / http_status）："
    echo "${errors}"
    # 永久发送失败几乎都是凭据或机器人状态问题，按平台业务码给出直接可执行的下一步
    case "${errors}" in
      *$'\t'93000*|*$'\t'93004*)
        echo "   原因：企业微信返回 93000/93004 —— Webhook 无效、机器人已被移出群或被停用。"
        echo "   处理：重新复制群机器人 Webhook，执行 ./scripts/configure.sh --section=channel 更新凭据（见 docs/bot-setup.md）" ;;
      *$'\t'310000*)
        echo "   原因：钉钉返回 310000 —— 加签密钥不匹配、关键词不是「GCP告警」或开了 IP 白名单。"
        echo "   处理：见 docs/troubleshooting.md「钉钉 errcode=310000」，改好后用 ./scripts/configure.sh --section=channel 更新" ;;
      *$'\t'300001*)
        echo "   原因：钉钉返回 300001 —— access_token 不存在（机器人已删除或 Webhook 复制不完整）。"
        echo "   处理：重新复制 Webhook，用 ./scripts/configure.sh --section=channel 更新" ;;
      *$'\t'19001*|*$'\t'19021*|*$'\t'9499*)
        echo "   原因：飞书返回 19001/19021/9499 —— token 错误、签名密钥不匹配或机器人已被移出群。"
        echo "   处理：见 docs/troubleshooting.md「sign match fail」，用 ./scripts/configure.sh --section=channel 更新" ;;
    esac
  else
    echo "   函数既没报错也没成功投递 —— 常见于消息被过滤，或函数从未被触发。"
  fi
  echo "   排查指引：docs/troubleshooting.md"
  return 1
}

# ===========================================================================
# 配置现状读取 / 运行时配置解析 / 关闭类变更的精确删除
#
# 供 scripts/configure.sh（配置修改向导）、两条部署脚本（重跑不回退线上配置）与
# scripts/teardown-gcloud.sh（卸载）共用。读取类函数一律【降级不中断】：任何一次
# 读取失败都记为「未知」并继续 —— 注意 pipefail 在 $(...) 里同样生效，所以每个
# 命令替换都带 `|| true` 或显式 rc 判断，绝不能让 set -e 在读取阶段静默退出。
# JSON 一律用 python3 解析（不假设 jq 存在）。
# ===========================================================================

# 函数运行时取值的合法集合（与 src/config.py / src/parsers/base.py 对齐）
VALID_MIN_SEVERITIES=(CRITICAL HIGH MEDIUM LOW INFO)
VALID_LOG_LEVELS=(DEBUG INFO WARNING ERROR CRITICAL)   # 向导只提示前四个；CRITICAL 为 src/config.py 亦接受的值
SCC_NOTIFICATION_ID="${SCC_NOTIFICATION_ID:-feishu-scc-export}"

billing_budget_display_name() { echo "Feishu Alert Budget - ${PROJECT_ID}"; }

# Webhook 打码（与 src/log_utils.mask_webhook 同口径）：只保留 token / key / access_token
# 的前 4 位。纯 bash 实现 —— 不把 URL 交给任何外部进程的 argv。无法识别的格式一律整串打码。
mask_webhook_shell() {
  local url="${1:-}"
  if [[ -z "${url}" ]]; then
    echo ""
  elif [[ "${url}" =~ ^(https?://[^?#]*(/hook/)|https?://[^?#]*\?(.*&)?(key=|access_token=))([A-Za-z0-9]{0,4}) ]]; then
    echo "${BASH_REMATCH[1]}${BASH_REMATCH[5]}****"
  else
    echo "****"
  fi
}

# 小工具：值是否在列表里
_in_list() { local v=$1; shift; local x; for x in "$@"; do [[ "${x}" == "${v}" ]] && return 0; done; return 1; }

# 按来源过滤：规范化 SOURCE_MIN_SEVERITY（小写来源、大写级别、固定顺序 monitoring;service_health;billing;scc）。
# 非法时 stderr 说明并返回 1。纯 bash + tr，兼容 macOS bash 3.2。
normalize_source_min_severity() {
  local raw="${1:-}"
  if [[ -z "${raw}" ]]; then
    echo ""
    return 0
  fi
  local -a pairs
  IFS=";" read -r -a pairs <<<"${raw}"
  local k v key val
  local m_val="" sh_val="" b_val="" s_val=""
  local pair
  for pair in "${pairs[@]}"; do
    pair="${pair//[[:space:]]/}"
    [[ -z "${pair}" ]] && continue
    k="${pair%%=*}"
    v="${pair#*=}"
    if [[ "${k}" == "${pair}" ]]; then
      echo "SOURCE_MIN_SEVERITY 格式错误: 缺少等号 (${pair})" >&2
      return 1
    fi
    key="$(tr '[:upper:]' '[:lower:]' <<<"${k}")"
    val="$(tr '[:lower:]' '[:upper:]' <<<"${v}")"
    
    if [[ ! "${val}" =~ ^(OFF|CRITICAL|HIGH|MEDIUM|LOW|INFO)$ ]]; then
      echo "SOURCE_MIN_SEVERITY 非法级别: ${val}" >&2
      return 1
    fi
    case "${key}" in
      monitoring) m_val="${val}" ;;
      service_health) sh_val="${val}" ;;
      billing) b_val="${val}" ;;
      scc) s_val="${val}" ;;
      *)
        echo "SOURCE_MIN_SEVERITY 非法来源: ${key}" >&2
        return 1
        ;;
    esac
  done
  local res=""
  [[ -n "${m_val}" ]] && res+="${res:+;}monitoring=${m_val}"
  [[ -n "${sh_val}" ]] && res+="${res:+;}service_health=${sh_val}"
  [[ -n "${b_val}" ]] && res+="${res:+;}billing=${b_val}"
  [[ -n "${s_val}" ]] && res+="${res:+;}scc=${s_val}"
  echo "${res}"
}

source_filter_display() {
  local raw="${1:-}"
  [[ -z "${raw}" ]] && { echo "全部跟随全局"; return 0; }
  local -a pairs
  IFS=";" read -r -a pairs <<<"${raw}"
  local out="" pair k v key_label val_label
  for pair in "${pairs[@]}"; do
    k="${pair%%=*}"
    v="${pair#*=}"
    case "${k}" in
      monitoring) key_label="Monitoring" ;;
      service_health) key_label="Service Health(PSH)" ;;
      billing) key_label="Billing" ;;
      scc) key_label="SCC" ;;
      *) key_label="${k}" ;;
    esac
    case "${v}" in
      OFF) val_label="关闭" ;;
      *) val_label="${v}" ;;
    esac
    out+="${out:+, }${key_label}=${val_label}"
  done
  echo "${out}"
}

# 布尔归一化：true/1/yes/on/y → true；false/0/no/off/n → false；其它 → 原样返回 1
normalize_bool() {
  case "$(tr '[:upper:]' '[:lower:]' <<<"${1:-}")" in
    true|1|yes|on|y)  echo true ;;
    false|0|no|off|n) echo false ;;
    *) return 1 ;;
  esac
}
# Y/N 开关归一化（部署脚本的 ENABLE_* 约定是 ^[Yy]$）
normalize_yn() {
  case "$(tr '[:upper:]' '[:lower:]' <<<"${1:-}")" in
    y|yes|true|1|on)  echo Y ;;
    n|no|false|0|off) echo N ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 部署模式识别：Terraform 路径给 topic 打了 managed-by=terraform 标签。
# 结果：DEPLOY_MODE=terraform|gcloud，TOPIC_MANAGED_BY=<标签原值>
# （teardown-gcloud.sh 据此拒绝清理 TF 环境；configure.sh 据此选择部署脚本）
# ---------------------------------------------------------------------------
detect_deploy_mode() {
  TOPIC_MANAGED_BY=$(gcloud pubsub topics describe "${TOPIC_NAME}" \
    --format="value(labels.managed-by)" 2>/dev/null || true)
  if [[ "${TOPIC_MANAGED_BY}" == "terraform" ]]; then
    DEPLOY_MODE=terraform
  else
    DEPLOY_MODE=gcloud
  fi
  export DEPLOY_MODE
}

# ---------------------------------------------------------------------------
# 读取线上函数配置（只读）。用法：load_live_function_config [REGION]
# 结果：
#   LIVE_FUNCTION_STATE      present | absent | unknown
#   LIVE_NOTIFY_CHANNEL / LIVE_MIN_SEVERITY / LIVE_LOG_LEVEL / LIVE_MAX_SENDS_PER_MINUTE /
#   LIVE_KILL_SWITCH / LIVE_PAUSE_MODE / LIVE_CONFIG_REVISION   （环境变量原值，缺省为空）
#   LIVE_MAX_INSTANCES       serviceConfig.maxInstanceCount
#   LIVE_SECRET_ENVS         "ENV=secret:version,..."（只有 Secret 名，没有值）
#   LIVE_REVISION / LIVE_UPDATE_TIME
# ---------------------------------------------------------------------------
load_live_function_config() {
  local region="${1:-${REGION:-}}"
  LIVE_FUNCTION_STATE=unknown
  LIVE_NOTIFY_CHANNEL="" LIVE_MIN_SEVERITY="" LIVE_SOURCE_MIN_SEVERITY="" LIVE_LOG_LEVEL="" LIVE_MAX_SENDS_PER_MINUTE=""
  LIVE_KILL_SWITCH="" LIVE_PAUSE_MODE="" LIVE_CONFIG_REVISION="" LIVE_MAX_INSTANCES=""
  LIVE_HUB_SOURCE_PROJECTS="" LIVE_HUB_SCOPE=""
  LIVE_SECRET_ENVS="" LIVE_REVISION="" LIVE_UPDATE_TIME=""

  if ! command -v python3 >/dev/null 2>&1; then
    log_warn "本机没有 python3，无法解析线上函数配置（按「未知」处理）"
    return 0
  fi
  local json="" rc=0 err=""
  json=$(gcloud functions describe "${FUNCTION_NAME}" --gen2 --region="${region}" \
    --quiet --format=json 2>/dev/null) || rc=$?
  if (( rc != 0 )); then
    err=$(gcloud functions describe "${FUNCTION_NAME}" --gen2 --region="${region}" \
      --quiet --format=json 2>&1 >/dev/null || true)
    if grep -qiE 'NOT_FOUND|not found|does not exist' <<<"${err}"; then
      LIVE_FUNCTION_STATE=absent
    fi
    return 0
  fi

  local parsed="" k v
  parsed=$(LIVE_JSON="${json}" python3 - <<'PY' 2>/dev/null || true
import json, os
try:
    d = json.loads(os.environ.get("LIVE_JSON") or "")
except Exception:
    raise SystemExit(3)
if not isinstance(d, dict) or not d:
    raise SystemExit(3)
sc = d.get("serviceConfig") or {}
env = sc.get("environmentVariables") or {}
def out(k, v):
    v = "" if v is None else str(v)
    print("%s\t%s" % (k, v.replace("\t", " ").replace("\n", " ")))
print("OK\t1")
for k in ("NOTIFY_CHANNEL", "MIN_SEVERITY", "LOG_LEVEL", "MAX_SENDS_PER_MINUTE",
          "KILL_SWITCH", "PAUSE_MODE", "CONFIG_REVISION", "HUB_SOURCE_PROJECTS", "HUB_SCOPE"):
    out(k, env.get(k))
out("SOURCE_MIN_SEVERITY", env.get("SOURCE_MIN_SEVERITY"))
out("MAX_INSTANCES", sc.get("maxInstanceCount"))
out("REVISION", sc.get("revision"))
out("UPDATE_TIME", d.get("updateTime"))
secs = sc.get("secretEnvironmentVariables") or []
out("SECRET_ENVS", ",".join("%s=%s:%s" % (s.get("key"), s.get("secret"), s.get("version") or "latest")
                            for s in secs if isinstance(s, dict)))
PY
)
  grep -q $'^OK\t1$' <<<"${parsed}" || return 0
  LIVE_FUNCTION_STATE=present
  while IFS=$'\t' read -r k v; do
    case "${k}" in
      NOTIFY_CHANNEL)       LIVE_NOTIFY_CHANNEL="${v}" ;;
      SOURCE_MIN_SEVERITY)  LIVE_SOURCE_MIN_SEVERITY="${v}" ;;
      MIN_SEVERITY)         LIVE_MIN_SEVERITY="${v}" ;;
      LOG_LEVEL)            LIVE_LOG_LEVEL="${v}" ;;
      MAX_SENDS_PER_MINUTE) LIVE_MAX_SENDS_PER_MINUTE="${v}" ;;
      KILL_SWITCH)          LIVE_KILL_SWITCH="${v}" ;;
      PAUSE_MODE)           LIVE_PAUSE_MODE="${v}" ;;
      CONFIG_REVISION)      LIVE_CONFIG_REVISION="${v}" ;;
      HUB_SOURCE_PROJECTS)  LIVE_HUB_SOURCE_PROJECTS="${v}" ;;
      HUB_SCOPE)            LIVE_HUB_SCOPE="${v}" ;;

      MAX_INSTANCES)        LIVE_MAX_INSTANCES="${v}" ;;
      REVISION)             LIVE_REVISION="${v}" ;;
      UPDATE_TIME)          LIVE_UPDATE_TIME="${v}" ;;
      SECRET_ENVS)          LIVE_SECRET_ENVS="${v}" ;;
    esac
  done <<<"${parsed}"
  return 0
}

# 线上值 → 有效值（函数侧的缺省语义：未设置 = feishu / MEDIUM / INFO / false / 渠道默认速率）
_effective_live_values() {
  LIVE_NOTIFY_CHANNEL_EFF="${LIVE_NOTIFY_CHANNEL:-feishu}"
  LIVE_MIN_SEVERITY_EFF="$(tr '[:lower:]' '[:upper:]' <<<"${LIVE_MIN_SEVERITY:-MEDIUM}")"
  LIVE_SOURCE_MIN_SEVERITY_EFF="${LIVE_SOURCE_MIN_SEVERITY:-}"
  LIVE_LOG_LEVEL_EFF="$(tr '[:lower:]' '[:upper:]' <<<"${LIVE_LOG_LEVEL:-INFO}")"
  LIVE_KILL_SWITCH_EFF="$(normalize_bool "${LIVE_KILL_SWITCH:-false}" || echo false)"
  LIVE_PAUSE_MODE_EFF="$(normalize_bool "${LIVE_PAUSE_MODE:-false}" || echo false)"
  LIVE_MAX_SENDS_PER_MINUTE_EFF="${LIVE_MAX_SENDS_PER_MINUTE:-$(channel_default_rate "${LIVE_NOTIFY_CHANNEL_EFF}" 2>/dev/null || echo 40)}"
  LIVE_MAX_INSTANCES_EFF="${LIVE_MAX_INSTANCES:-2}"
}

# ---------------------------------------------------------------------------
# 读取线上【完整】配置（只读）：函数 + 告警策略 + 自监控邮箱 + 预算 + SCC + 部署模式。
# 用法：load_live_config [REGION]
# 额外结果（状态取值 on | off | partial | unknown）：
#   LIVE_DEPLOY_MODE、LIVE_PSH、LIVE_DEFAULT_ALERTS、LIVE_SELF_MON、LIVE_OPS_EMAIL、
#   LIVE_BILLING、LIVE_BILLING_ACCOUNT、LIVE_BUDGET_UNITS、LIVE_BUDGET_CURRENCY、
#   LIVE_SCC、LIVE_SCC_NOTE、LIVE_ORG_ID
# ---------------------------------------------------------------------------
_count_present() {  # $1=已存在 displayName 清单（换行分隔），其余=期望清单 → 输出 on/off/partial
  local listing=$1; shift
  local n=0 total=$# name
  for name in "$@"; do grep -qxF -- "${name}" <<<"${listing}" && n=$(( n + 1 )); done
  if (( n == 0 )); then echo off; elif (( n == total )); then echo on; else echo partial; fi
}

load_live_config() {
  local region="${1:-${REGION:-}}"
  load_live_function_config "${region}"
  _effective_live_values
  load_live_resources
}

# 只读函数以外的部分（告警策略 / 自监控邮箱 / 预算 / SCC / 部署模式）。
# 部署脚本重跑时（resolve_runtime_config）也用它来沿用可选数据源的现状。
load_live_resources() {
  detect_deploy_mode
  LIVE_DEPLOY_MODE="${DEPLOY_MODE}"

  # 1. 告警策略：一次 list，按 displayName【精确】比对（filter 的 = 也是精确匹配，这里再核一遍）
  local default_names=() spec filter="" name listing rc=0
  for spec in "${DEFAULT_ALERT_POLICY_SPECS[@]}"; do default_names+=("${spec#*|}"); done
  for name in "${PSH_POLICY_DISPLAY_NAMES[@]}" "${default_names[@]}" "${SELF_MONITORING_POLICY_DISPLAY_NAMES[@]}"; do
    filter+="${filter:+ OR }displayName=\"${name}\""
  done
  listing=$(gcloud beta monitoring policies list --filter="${filter}" \
    --format="value(displayName)" 2>/dev/null) || rc=$?
  if (( rc != 0 )); then
    LIVE_PSH=unknown LIVE_DEFAULT_ALERTS=unknown LIVE_SELF_MON=unknown
  else
    LIVE_PSH=$(_count_present "${listing}" "${PSH_POLICY_DISPLAY_NAMES[@]}")
    LIVE_DEFAULT_ALERTS=$(_count_present "${listing}" "${default_names[@]}")
    LIVE_SELF_MON=$(_count_present "${listing}" "${SELF_MONITORING_POLICY_DISPLAY_NAMES[@]}")
  fi

  # 2. 自监控邮件渠道的收件人（filter 字面量必须双引号，见 deploy_self_monitoring_alerts）
  LIVE_OPS_EMAIL=""
  rc=0
  LIVE_OPS_EMAIL=$(gcloud beta monitoring channels list \
    --filter="displayName=\"${OPS_EMAIL_CHANNEL_DISPLAY_NAME}\" AND type=\"email\"" \
    --format="value(labels.email_address)" 2>/dev/null | head -1) || rc=$?
  (( rc == 0 )) || LIVE_OPS_EMAIL=""
  LIVE_OPS_EMAIL="${LIVE_OPS_EMAIL//[[:space:]]/}"
  # 只剩邮件渠道、策略已删的情况按「关闭」处理（部署时会按需重建）
  [[ "${LIVE_SELF_MON}" == "off" ]] && LIVE_OPS_EMAIL=""

  # 3. Billing 预算（无 billing.viewer / 未绑结算账号 → 未知）
  LIVE_BILLING=unknown LIVE_BILLING_ACCOUNT="" LIVE_BUDGET_UNITS="" LIVE_BUDGET_CURRENCY=""
  LIVE_BILLING_ACCOUNT=$(gcloud billing projects describe "${PROJECT_ID}" \
    --format="value(billingAccountName)" 2>/dev/null | sed 's|billingAccounts/||' || true)
  if [[ -n "${LIVE_BILLING_ACCOUNT}" ]]; then
    local budget_line=""
    rc=0
    budget_line=$(gcloud billing budgets list --billing-account="${LIVE_BILLING_ACCOUNT}" \
      --filter="displayName='$(billing_budget_display_name)'" \
      --format="value(amount.specifiedAmount.units,amount.specifiedAmount.currencyCode)" 2>/dev/null | head -1) || rc=$?
    if (( rc == 0 )); then
      if [[ -n "${budget_line}" ]]; then
        LIVE_BILLING=on
        IFS=$'\t' read -r LIVE_BUDGET_UNITS LIVE_BUDGET_CURRENCY <<<"${budget_line}"
      else
        LIVE_BILLING=off
      fi
    fi
  fi

  # 4. SCC 导出（组织级；无组织 = 不可用 = 关闭；无权限 = 未知）
  LIVE_SCC=unknown LIVE_SCC_NOTE="" LIVE_ORG_ID=""
  LIVE_ORG_ID=$(gcloud projects get-ancestors "${PROJECT_ID}" \
    --format="csv[no-heading](id,type)" 2>/dev/null \
    | awk -F, '$2=="organization"{print $1}' | head -1) || true
  if [[ -z "${LIVE_ORG_ID}" ]]; then
    LIVE_SCC=off LIVE_SCC_NOTE="项目不隶属于组织或无权读取祖先链，SCC 不可用"
  elif gcloud scc notifications describe "${SCC_NOTIFICATION_ID}" --organization="${LIVE_ORG_ID}" \
         --format="value(name)" >/dev/null 2>&1; then
    LIVE_SCC=on
  elif gcloud scc notifications list --organization="${LIVE_ORG_ID}" --format="value(name)" >/dev/null 2>&1; then
    LIVE_SCC=off
  else
    LIVE_SCC_NOTE="无权读取组织 ${LIVE_ORG_ID} 的 SCC 通知配置"
  fi
  return 0
}

# Terraform 模式下「未知」的现状不能随便当成关闭：apply 会把 state 里的资源删掉。
# 先用本机上次部署生成的 terraform/terraform.tfvars 兜底（只读其中的布尔 / 数字 / 邮箱，不含密文）。
_tfvar() {  # _tfvar 名称 → 输出值（去引号），无则空
  local f="${REPO_ROOT}/terraform/terraform.tfvars"
  [[ -f "${f}" ]] || return 0
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?([^\"#]*)\"?.*$/\1/p" "${f}" \
    | head -1 | sed -E 's/[[:space:]]+$//'
}
apply_tfvars_fallback() {
  local v
  if [[ "${LIVE_BILLING:-unknown}" == "unknown" ]]; then
    case "$(_tfvar enable_billing)" in
      true)  LIVE_BILLING=on; v="$(_tfvar billing_amount)"; LIVE_BUDGET_UNITS="${v:-${LIVE_BUDGET_UNITS:-}}" ;;
      false) LIVE_BILLING=off ;;
    esac
  fi
  if [[ "${LIVE_SCC:-unknown}" == "unknown" ]]; then
    case "$(_tfvar enable_scc)" in true) LIVE_SCC=on ;; false) LIVE_SCC=off ;; esac
  fi
  if [[ "${LIVE_PSH:-unknown}" == "unknown" ]]; then
    case "$(_tfvar enable_psh)" in true) LIVE_PSH=on ;; false) LIVE_PSH=off ;; esac
  fi
  if [[ "${LIVE_DEFAULT_ALERTS:-unknown}" == "unknown" ]]; then
    case "$(_tfvar enable_default_alerts)" in true) LIVE_DEFAULT_ALERTS=on ;; false) LIVE_DEFAULT_ALERTS=off ;; esac
  fi
  if [[ "${LIVE_SELF_MON:-unknown}" == "unknown" || ( "${LIVE_SELF_MON}" != "off" && -z "${LIVE_OPS_EMAIL:-}" ) ]]; then
    if grep -qE '^[[:space:]]*ops_email[[:space:]]*=' "${REPO_ROOT}/terraform/terraform.tfvars" 2>/dev/null; then
      LIVE_OPS_EMAIL="$(_tfvar ops_email)"
      if [[ -n "${LIVE_OPS_EMAIL}" ]]; then LIVE_SELF_MON=on; else LIVE_SELF_MON=off; fi
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 可选数据源 / 告警策略开关的「重跑不回退」（由 resolve_runtime_config 在函数已存在时调用）
#
# ENABLE_PSH / ENABLE_DEFAULT_ALERTS / ENABLE_SCC / ENABLE_BILLING / BUDGET_AMOUNT / OPS_EMAIL
# 未提供（unset；显式设为空也算提供）时沿用 load_live_resources 读到的线上现状：
#   on / partial → Y；off → N；
#   unknown：gcloud 模式 → 保持不动（传 N：部署脚本只 upsert，不会删除；OPS_EMAIL 则置
#            OPS_EMAIL_UNKNOWN_KEEP=true，自监控步骤不登记跳过）；
#            terraform 模式 → --yes 下 die（apply 会删 state 里的资源），交互模式下标记为必须作答，
#            由 prompt_optional_sources 询问（无默认值）。
# 交互模式下 prompt_optional_sources 以沿用值作为回车默认值。
# ---------------------------------------------------------------------------
OPTIONAL_INHERITED_VARS=" "
OPTIONAL_MUST_ASK_VARS=" "
OPTIONAL_UNKNOWN_KEPT=()
_optional_unknown() {  # _optional_unknown 变量名 显示名 模式
  local var=$1 label=$2 mode=$3
  if [[ "${mode}" == "terraform" ]]; then
    if [[ "${ASSUME_YES:-false}" == "true" ]]; then
      local how="y|n"; [[ "${var}" == "OPS_EMAIL" ]] && how="<邮箱>（或 OPS_EMAIL= 表示关闭）"
      die "无法读取「${label}」的线上现状（权限不足？）。Terraform 模式下请显式设置 ${var}=${how} 后重跑 —— 否则 apply 可能误删已有资源"
    fi
    OPTIONAL_MUST_ASK_VARS+="${var} "
  else
    if [[ "${var}" == "OPS_EMAIL" ]]; then
      OPS_EMAIL=""; OPS_EMAIL_UNKNOWN_KEEP=true; export OPS_EMAIL_UNKNOWN_KEEP
    else
      printf -v "${var}" '%s' "N"
    fi
    OPTIONAL_UNKNOWN_KEPT+=("${label}")
  fi
}
_inherit_toggle() {  # _inherit_toggle 变量名 线上状态 显示名 模式
  local var=$1 state=$2 label=$3 mode=$4
  [[ -z "${!var+x}" ]] || return 0
  case "${state}" in
    on|partial) printf -v "${var}" '%s' "Y"; OPTIONAL_INHERITED_VARS+="${var} "; RUNTIME_INHERITED+=("${var}=Y") ;;
    off)        printf -v "${var}" '%s' "N"; OPTIONAL_INHERITED_VARS+="${var} "; RUNTIME_INHERITED+=("${var}=N") ;;
    *)          _optional_unknown "${var}" "${label}" "${mode}" ;;
  esac
}
_inherit_optional_sources() {
  local mode=$1
  if [[ -n "${ENABLE_PSH+x}" && -n "${ENABLE_DEFAULT_ALERTS+x}" && -n "${ENABLE_SCC+x}" \
        && -n "${ENABLE_BILLING+x}" && -n "${OPS_EMAIL+x}" && -n "${BUDGET_AMOUNT+x}" ]]; then
    return 0   # 全部显式提供：不必再读线上现状
  fi
  load_live_resources
  [[ "${mode}" == "terraform" ]] && apply_tfvars_fallback
  _inherit_toggle ENABLE_PSH "${LIVE_PSH}" "PSH 告警策略" "${mode}"
  _inherit_toggle ENABLE_DEFAULT_ALERTS "${LIVE_DEFAULT_ALERTS}" "推荐默认告警包" "${mode}"
  _inherit_toggle ENABLE_SCC "${LIVE_SCC}" "SCC 导出" "${mode}"
  _inherit_toggle ENABLE_BILLING "${LIVE_BILLING}" "Billing 预算" "${mode}"
  if [[ -z "${BUDGET_AMOUNT+x}" && "${ENABLE_BILLING:-N}" =~ ^[Yy]$ && "${LIVE_BILLING}" == "on" && -n "${LIVE_BUDGET_UNITS:-}" ]]; then
    if [[ "${mode}" == "terraform" ]]; then
      BUDGET_AMOUNT="${LIVE_BUDGET_UNITS}"
    else
      BUDGET_AMOUNT="${LIVE_BUDGET_UNITS}${LIVE_BUDGET_CURRENCY:-USD}"
    fi
    OPTIONAL_INHERITED_VARS+="BUDGET_AMOUNT "; RUNTIME_INHERITED+=("BUDGET_AMOUNT=${BUDGET_AMOUNT}")
  fi
  if [[ -z "${OPS_EMAIL+x}" ]]; then
    case "${LIVE_SELF_MON}" in
      on|partial)
        if [[ -n "${LIVE_OPS_EMAIL:-}" ]]; then
          OPS_EMAIL="${LIVE_OPS_EMAIL}"; OPTIONAL_INHERITED_VARS+="OPS_EMAIL "; RUNTIME_INHERITED+=("OPS_EMAIL=${OPS_EMAIL}")
        else
          _optional_unknown OPS_EMAIL "自监控收件邮箱 OPS_EMAIL" "${mode}"
        fi ;;
      off) OPS_EMAIL=""; OPTIONAL_INHERITED_VARS+="OPS_EMAIL "; RUNTIME_INHERITED+=("OPS_EMAIL=（关闭）") ;;
      *)   _optional_unknown OPS_EMAIL "自监控收件邮箱 OPS_EMAIL" "${mode}" ;;
    esac
  fi
  export ENABLE_PSH ENABLE_DEFAULT_ALERTS ENABLE_SCC ENABLE_BILLING
  [[ -n "${OPS_EMAIL+x}" ]] && export OPS_EMAIL
  [[ -n "${BUDGET_AMOUNT+x}" ]] && export BUDGET_AMOUNT
  return 0
}
_optional_is_inherited() { [[ "${OPTIONAL_INHERITED_VARS}" == *" $1 "* ]]; }
_optional_must_ask()     { [[ "${OPTIONAL_MUST_ASK_VARS}" == *" $1 "* ]]; }

# ---------------------------------------------------------------------------
# 重跑部署不回退线上配置（两条部署脚本在 select_project 之后、prompt_channel_credentials 之前调用）
#
# 规则（环境变量优先，未提供时）：
#   NOTIFY_CHANNEL / MIN_SEVERITY / LOG_LEVEL / MAX_INSTANCES / CONFIG_REVISION → 函数已存在时沿用线上值，否则取默认；
#   KILL_SWITCH / PAUSE_MODE → 仍复位为 false（文档既有语义：重跑部署 = 解除急停/暂停），但线上为 true 时醒目 WARNING。
#   ENABLE_PSH / ENABLE_DEFAULT_ALERTS / ENABLE_SCC / ENABLE_BILLING / BUDGET_AMOUNT / OPS_EMAIL
#     → 沿用线上现状，见 _inherit_optional_sources（未知现状的处理按部署模式区分）。
# MAX_SENDS_PER_MINUTE 的沿用在 inherit_live_send_rate（渠道确定之后）里做。
# 函数不存在（首次部署）时什么都不沿用，行为与旧版逐字一致。
# 用法：resolve_runtime_config REGION gcloud|terraform
# ---------------------------------------------------------------------------
resolve_runtime_config() {
  local region="${1:-${REGION:-}}" mode="${2:-gcloud}"
  RUNTIME_INHERITED=()
  # 显式提供的 SOURCE_MIN_SEVERITY 无论首次部署还是重跑都先校验 + 规范化：
  # 非法值进了函数 env 会让实例启动即 ConfigError（Pub/Sub 无限重试 → DLQ）。
  if [[ "${HUB_SOURCE_PROJECTS+x}" ]]; then
    if [[ -n "${HUB_SOURCE_PROJECTS}" ]]; then
      HUB_SOURCE_PROJECTS="$(normalize_hub_source_projects "${HUB_SOURCE_PROJECTS}")"         || die "HUB_SOURCE_PROJECTS 格式无效"
    fi
  fi
  if [[ "${HUB_SCOPE+x}" ]]; then
    if [[ -n "${HUB_SCOPE}" ]]; then
      HUB_SCOPE="$(normalize_hub_scope "${HUB_SCOPE}")"         || die "HUB_SCOPE 格式无效"
    fi
  fi
  if [[ -n "${SOURCE_MIN_SEVERITY:-}" ]]; then
    SOURCE_MIN_SEVERITY="$(normalize_source_min_severity "${SOURCE_MIN_SEVERITY}")" \
      || die "SOURCE_MIN_SEVERITY 格式无效（应形如 monitoring=HIGH;billing=OFF），未做任何修改"
  fi
  load_live_function_config "${region}"
  if [[ "${LIVE_FUNCTION_STATE}" == "present" ]]; then
    _effective_live_values
    if [[ -z "${NOTIFY_CHANNEL:-}" ]]; then
      NOTIFY_CHANNEL="${LIVE_NOTIFY_CHANNEL_EFF}"; RUNTIME_INHERITED+=("NOTIFY_CHANNEL=${NOTIFY_CHANNEL}")
    fi
    if [[ -z "${SOURCE_MIN_SEVERITY+x}" ]]; then
      SOURCE_MIN_SEVERITY="${LIVE_SOURCE_MIN_SEVERITY_EFF}"
      # 只有非空时才列入 inherited，空代表保持「无过滤规则」并沿用
      [[ -n "${SOURCE_MIN_SEVERITY}" ]] && RUNTIME_INHERITED+=("SOURCE_MIN_SEVERITY=${SOURCE_MIN_SEVERITY}")
    fi
    if [[ -z "${HUB_SOURCE_PROJECTS+x}" ]]; then
      HUB_SOURCE_PROJECTS="${LIVE_HUB_SOURCE_PROJECTS:-}"
      [[ -n "${HUB_SOURCE_PROJECTS}" ]] && RUNTIME_INHERITED+=("HUB_SOURCE_PROJECTS=${HUB_SOURCE_PROJECTS}")
    fi
    if [[ -z "${HUB_SCOPE+x}" ]]; then
      HUB_SCOPE="${LIVE_HUB_SCOPE:-}"
      [[ -n "${HUB_SCOPE}" ]] && RUNTIME_INHERITED+=("HUB_SCOPE=${HUB_SCOPE}")
    fi
    if [[ -z "${MIN_SEVERITY:-}" ]]; then
      MIN_SEVERITY="${LIVE_MIN_SEVERITY_EFF}"; RUNTIME_INHERITED+=("MIN_SEVERITY=${MIN_SEVERITY}")
    fi
    if [[ -z "${LOG_LEVEL:-}" ]]; then
      LOG_LEVEL="${LIVE_LOG_LEVEL_EFF}"; RUNTIME_INHERITED+=("LOG_LEVEL=${LOG_LEVEL}")
    fi
    if [[ "${MAX_INSTANCES_EXPLICIT:-false}" != "true" && -n "${LIVE_MAX_INSTANCES}" ]]; then
      MAX_INSTANCES="${LIVE_MAX_INSTANCES}"; RUNTIME_INHERITED+=("MAX_INSTANCES=${MAX_INSTANCES}")
    fi
    if [[ -z "${CONFIG_REVISION+x}" && -n "${LIVE_CONFIG_REVISION}" ]]; then
      CONFIG_REVISION="${LIVE_CONFIG_REVISION}"
    fi

    _inherit_optional_sources "${mode}"
    local sw
    for sw in KILL_SWITCH PAUSE_MODE; do
      local live_var="LIVE_${sw}_EFF"
      if [[ -z "${!sw:-}" && "${!live_var}" == "true" ]]; then
        echo "" >&2
        log_warn "══════ 线上 ${sw}=true，本次部署未显式提供 ${sw}，将【复位为 false】══════"
        if [[ "${sw}" == "KILL_SWITCH" ]]; then
          echo "    急停将被解除：部署完成后告警会重新开始投递。若要保持急停，请设置 KILL_SWITCH=true 后重跑" >&2
        else
          echo "    暂停将被解除：堆积在订阅中的消息会开始重投。若要保持暂停，请设置 PAUSE_MODE=true 后重跑" >&2
        fi
        echo "" >&2
      fi
    done
  fi
  MIN_SEVERITY="$(tr '[:lower:]' '[:upper:]' <<<"${MIN_SEVERITY:-MEDIUM}")"
  LOG_LEVEL="$(tr '[:lower:]' '[:upper:]' <<<"${LOG_LEVEL:-INFO}")"
  _in_list "${MIN_SEVERITY}" "${VALID_MIN_SEVERITIES[@]}" || \
    die "MIN_SEVERITY=${MIN_SEVERITY} 无效：只能是 ${VALID_MIN_SEVERITIES[*]}"
  _in_list "${LOG_LEVEL}" "${VALID_LOG_LEVELS[@]}" || \
    die "LOG_LEVEL=${LOG_LEVEL} 无效：只能是 ${VALID_LOG_LEVELS[*]}"
  KILL_SWITCH="$(normalize_bool "${KILL_SWITCH:-false}")" || die "KILL_SWITCH 无效：只能是 true / false"
  PAUSE_MODE="$(normalize_bool "${PAUSE_MODE:-false}")" || die "PAUSE_MODE 无效：只能是 true / false"
  CONFIG_REVISION="${CONFIG_REVISION:-}"

  # 进 --set-env-vars 的值不能含逗号 / 等号 / 空白，否则会把后面的变量切坏
  [[ -z "${CONFIG_REVISION}" || "${CONFIG_REVISION}" =~ ^[A-Za-z0-9._:-]{1,64}$ ]] || \
    die "CONFIG_REVISION=${CONFIG_REVISION} 无效：只允许字母、数字与 . _ : -（最长 64）"
  if (( ${#RUNTIME_INHERITED[@]} > 0 )); then
    log_info "沿用线上配置：${RUNTIME_INHERITED[*]}（显式设置同名环境变量可覆盖）"
  fi
  if (( ${#OPTIONAL_UNKNOWN_KEPT[@]} > 0 )); then
    log_warn "无法读取线上现状、本次保持不动（不创建也不删除）：${OPTIONAL_UNKNOWN_KEPT[*]}；如需变更请显式设置对应环境变量"
  fi
  if [[ "${KILL_SWITCH}" == "true" || "${PAUSE_MODE}" == "true" ]]; then
    log_warn "本次部署 KILL_SWITCH=${KILL_SWITCH} / PAUSE_MODE=${PAUSE_MODE}：函数不会投递任何告警，部署末尾的连通性自检必然失败"
  fi
  export NOTIFY_CHANNEL MIN_SEVERITY LOG_LEVEL MAX_INSTANCES KILL_SWITCH PAUSE_MODE CONFIG_REVISION
}

# 渠道确定后、validate_channel_rate_limit 之前调用：同渠道且未显式设置速率时沿用线上值。
# 线上值等于渠道默认值时不设置（保持「未显式」语义，Terraform 路径就不会多写一行 tfvars）。
inherit_live_send_rate() {
  [[ "${LIVE_FUNCTION_STATE:-}" == "present" ]] || return 0
  [[ -z "${MAX_SENDS_PER_MINUTE:-}" ]] || return 0
  [[ -n "${LIVE_MAX_SENDS_PER_MINUTE:-}" ]] || return 0
  [[ "${NOTIFY_CHANNEL:-feishu}" == "${LIVE_NOTIFY_CHANNEL_EFF:-feishu}" ]] || return 0
  local def
  def=$(channel_default_rate "${NOTIFY_CHANNEL:-feishu}" 2>/dev/null) || return 0
  if [[ "${LIVE_MAX_SENDS_PER_MINUTE}" != "${def}" ]]; then
    MAX_SENDS_PER_MINUTE="${LIVE_MAX_SENDS_PER_MINUTE}"
    log_info "沿用线上配置：MAX_SENDS_PER_MINUTE=${MAX_SENDS_PER_MINUTE}"
  fi
  return 0
}

# KEEP_EXISTING_SECRETS=true 时的前置校验：本渠道每个 Secret 都存在且至少有一个 ENABLED 版本。
verify_channel_secrets_present() {
  local s v missing=()
  for s in "${CHANNEL_SECRET_NAMES[@]}"; do
    v=$(gcloud secrets versions list "${s}" --filter="state=ENABLED" --limit=1 \
      --format="value(name)" 2>/dev/null || true)
    [[ -n "${v}" ]] || missing+=("${s}")
  done
  if (( ${#missing[@]} > 0 )); then
    local hint
    case "${NOTIFY_CHANNEL}" in
      feishu)   hint="FEISHU_WEBHOOK / FEISHU_SECRET" ;;
      wecom)    hint="WECOM_WEBHOOK" ;;
      dingtalk) hint="DINGTALK_WEBHOOK / DINGTALK_SECRET" ;;
    esac
    die "KEEP_EXISTING_SECRETS=true，但${CHANNEL_LABEL}渠道的 Secret 不存在或没有已启用版本：${missing[*]}（项目 ${PROJECT_ID:-?}）
   沿用一个不存在的 Secret 会让新 revision 启动即失败。请改为输入新凭据（unset KEEP_EXISTING_SECRETS，并提供 ${hint}）"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 精确删除（gcloud 路径的「开 → 关」与 teardown 共用）。只按本仓库固定的 displayName /
# 资源名精确匹配；带 userLabels.managed-by=terraform 的策略一律跳过。失败不中断，
# 计入 REMOVE_FAILURES 供调用方汇报。
# ---------------------------------------------------------------------------
REMOVE_FAILURES=0

remove_alert_policies_by_display_names() {
  local filter="" name policy managed_by
  for name in "$@"; do
    filter+="${filter:+ OR }displayName=\"${name}\""
  done
  while IFS=$'\t' read -r policy managed_by || [[ -n "${policy:-}" ]]; do
    [[ -n "${policy}" ]] || continue
    if [[ "${managed_by}" == "terraform" ]]; then
      log_info "跳过 Terraform 托管的策略 ${policy##*/}（请用 terraform destroy）"
      continue
    fi
    if gcloud beta monitoring policies delete "${policy}" --quiet >/dev/null 2>&1; then
      log_info "已删除告警策略 ${policy##*/}"
    else
      REMOVE_FAILURES=$(( REMOVE_FAILURES + 1 ))
      log_warn "删除告警策略 ${policy##*/} 失败（权限不足？），请手工确认"
    fi
  done < <(gcloud beta monitoring policies list \
    --filter="${filter}" \
    --format="value(name,userLabels.managed-by)" 2>/dev/null || true)
}

remove_notification_channels_by_display_names() {
  local filter="" name channels="" channel
  for name in "$@"; do
    filter+="${filter:+ OR }displayName=\"${name}\""
  done
  # 字面量必须用双引号：notificationChannels 的 filter 语法不接受单引号（会 INVALID_ARGUMENT
  # 并被 2>/dev/null 吞掉，表现为「一个都删不掉却不报错」）。
  if ! channels=$(gcloud beta monitoring channels list \
         --filter="${filter}" --format="value(name)" 2>/dev/null); then
    log_warn "查询 Notification Channel 失败，可能有渠道未被清理，请手工确认"
    REMOVE_FAILURES=$(( REMOVE_FAILURES + 1 ))
  fi
  while read -r channel; do
    [[ -n "${channel}" ]] || continue
    if gcloud beta monitoring channels delete "${channel}" --quiet --force >/dev/null 2>&1; then
      log_info "已删除 Notification Channel ${channel##*/}"
    else
      REMOVE_FAILURES=$(( REMOVE_FAILURES + 1 ))
      log_warn "删除 Notification Channel ${channel##*/} 失败，请手工确认"
    fi
  done <<<"${channels}"
}

# PSH 两类策略（连同旧版遗留的两条）
remove_psh_policies() {
  remove_alert_policies_by_display_names "${PSH_POLICY_DISPLAY_NAMES[@]}" "${LEGACY_PSH_POLICY_DISPLAY_NAMES[@]}"
}

remove_default_alert_policies() {
  local names=() spec
  for spec in "${DEFAULT_ALERT_POLICY_SPECS[@]}"; do names+=("${spec#*|}"); done
  remove_alert_policies_by_display_names "${names[@]}"
}

# 自监控：两条策略 + 邮件渠道（先删策略：渠道仍被策略引用时 delete 需要 --force）
remove_self_monitoring() {
  remove_alert_policies_by_display_names "${SELF_MONITORING_POLICY_DISPLAY_NAMES[@]}"
  remove_notification_channels_by_display_names "${OPS_EMAIL_CHANNEL_DISPLAY_NAME}"
}

remove_billing_budget() {
  local account budget
  account=$(gcloud billing projects describe "${PROJECT_ID}" \
    --format="value(billingAccountName)" 2>/dev/null | sed 's|billingAccounts/||' || true)
  [[ -n "${account}" ]] || return 0
  budget=$(gcloud billing budgets list --billing-account="${account}" \
    --filter="displayName='$(billing_budget_display_name)'" \
    --format="value(name)" 2>/dev/null | head -1 || true)
  [[ -n "${budget}" ]] || return 0
  if gcloud billing budgets delete "${budget##*/}" --billing-account="${account}" --quiet >/dev/null 2>&1; then
    log_info "已删除 Billing 预算 $(billing_budget_display_name)"
  else
    REMOVE_FAILURES=$(( REMOVE_FAILURES + 1 ))
    log_warn "删除 Billing 预算失败（需 roles/billing.costsManager），请手工确认"
  fi
}

# 用法：remove_scc_export [verify_topic]
#   verify_topic=true 时，只有导出配置确实指向本项目的 topic 才删（configure 用：SCC 导出是
#   组织级资源，同组织另一个项目也可能用了同一个 ID）；teardown 保持原有行为不校验。
remove_scc_export() {
  local verify="${1:-false}" org topic
  org=$(gcloud projects get-ancestors "${PROJECT_ID}" \
    --format="csv[no-heading](id,type)" 2>/dev/null \
    | awk -F, '$2=="organization"{print $1}' | head -1) || true
  [[ -n "${org}" ]] || return 0
  if [[ "${verify}" == "true" ]]; then
    topic=$(gcloud scc notifications describe "${SCC_NOTIFICATION_ID}" --organization="${org}" \
      --format="value(pubsubTopic)" 2>/dev/null || true)
    if [[ -n "${topic}" && "${topic}" != "projects/${PROJECT_ID}/topics/${TOPIC_NAME}" ]]; then
      log_warn "SCC 导出 ${SCC_NOTIFICATION_ID} 指向 ${topic}（不是本项目的 topic），不删除"
      return 0
    fi
  fi
  if gcloud scc notifications delete "${SCC_NOTIFICATION_ID}" --organization="${org}" --quiet >/dev/null 2>&1; then
    log_info "已删除 SCC 导出配置 ${SCC_NOTIFICATION_ID}（org ${org}）"
  else
    log_info "SCC 导出配置不存在或无权限，跳过"
  fi
}


# ---------------------------------------------------------------------------
# Hub 模式常量与函数
# ---------------------------------------------------------------------------

# 多项目汇聚：源项目 / 聚合 sink 的日志过滤条件。唯一真相源是 templates/hub-sink-filter.txt，
# Terraform（terraform/sources.tf 的 local.hub_sink_filter）读同一个文件，两条路径逐字一致。
# 审计与系统事件一律用 LOG_ID()：路由到 Hub 的日志保留源项目的 logName，写死项目的 logName 匹配不到。
HUB_SINK_FILTER="$(cat "${REPO_ROOT}/templates/hub-sink-filter.txt" 2>/dev/null || true)"

normalize_hub_source_projects() {
  local raw="$1"
  local output=""
  local item proj_id proj_num
  if [[ -z "${raw}" ]]; then
    return 0
  fi

  # 1. 拆分并验证
  IFS=';' read -ra ITEMS <<< "${raw}"
  local ids=()
  local nums=()
  
  for item in "${ITEMS[@]}"; do
    item="${item//[[:space:]]/}"
    [[ -z "${item}" ]] && continue
    if [[ "${item}" == *"="* ]]; then
      proj_id="${item%%=*}"
      proj_num="${item#*=}"
    else
      proj_id="${item}"
      proj_num=""
    fi
    
    if [[ ! "${proj_id}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || [[ -n "${proj_num}" && ! "${proj_num}" =~ ^[0-9]+$ ]]; then
      log_error "无效的源项目: ${item}（应为 项目ID 或 项目ID=项目编号）"
      return 1
    fi
    if [[ "${proj_id}" == "${PROJECT_ID}" ]]; then
      log_warn "HUB_SOURCE_PROJECTS 包含 Hub 自身，已剔除"
      continue
    fi
    
    if [[ -z "${proj_num}" ]]; then
      proj_num=$(gcloud projects describe "${proj_id}" --format='value(projectNumber)' 2>/dev/null || true)
      if [[ -z "${proj_num}" ]]; then
        log_error "无法获取源项目 ${proj_id} 的编号，请检查权限或项目是否存在"
        return 1
      fi
    fi
    
    # 去重
    local dup=false
    for exist_id in "${ids[@]:-}"; do
      if [[ "${exist_id}" == "${proj_id}" ]]; then
        dup=true
        break
      fi
    done
    if [[ "${dup}" == "false" ]]; then
      ids+=("${proj_id}")
      nums+=("${proj_num}")
    fi
  done
  
  # 2. 排序并组装
  local sorted_indices=($(for i in "${!ids[@]}"; do echo "${ids[$i]} $i"; done | sort -k1,1 | awk '{print $2}'))
  for i in "${sorted_indices[@]}"; do
    output+="${output:+;}${ids[$i]}=${nums[$i]}"
  done
  
  echo "${output}"
}

normalize_hub_scope() {
  local raw="$1"
  if [[ -z "${raw}" ]]; then
    return 0
  fi
  if [[ ! "${raw}" =~ ^(folders|organizations)/[0-9]+$ ]]; then
    log_error "无效的 HUB_SCOPE 格式: ${raw} (应为 folders/123 或 organizations/456)"
    return 1
  fi
  echo "${raw}"
}

preflight_source_project() {
  local src="$1"
  local missing=()
  local required_perms=(
    "monitoring.notificationChannels.create"
    "logging.sinks.create"
    "serviceusage.services.enable"
    "monitoring.alertPolicies.update"
    "resourcemanager.projects.get"
  )
  
  local response
  response=$(curl -s -X POST -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    -H "Content-Type: application/json" \
    -d "{\"permissions\":[$(printf '"%s",' "${required_perms[@]}" | sed 's/,$//')]}" \
    "https://cloudresourcemanager.googleapis.com/v1/projects/${src}:testIamPermissions" 2>/dev/null || true)
    
  for perm in "${required_perms[@]}"; do
    if ! echo "${response}" | grep -q "\"${perm}\""; then
      missing+=("${perm}")
    fi
  done
  
  if (( ${#missing[@]} > 0 )); then
    log_error "源项目 ${src} 缺失以下权限，导致无法创建汇聚资源："
    for perm in "${missing[@]}"; do
      echo "  - ${perm}"
    done
    echo ""
    echo "请联系 ${src} 的项目管理员，为您授予包含上述权限的角色（推荐角色：roles/monitoring.editor, roles/logging.configWriter, roles/serviceusage.serviceUsageAdmin），或请其直接执行："
    local member="${DEPLOYER_MEMBER:-}"
    if [[ -z "${member}" ]]; then
      member="user:$(gcloud config get-value account 2>/dev/null)"
    fi
    echo "  gcloud projects add-iam-policy-binding ${src} --member=\"${member}\" --role=\"roles/monitoring.editor\""
    echo "  gcloud projects add-iam-policy-binding ${src} --member=\"${member}\" --role=\"roles/logging.configWriter\""
    echo "  gcloud projects add-iam-policy-binding ${src} --member=\"${member}\" --role=\"roles/serviceusage.serviceUsageAdmin\""
    return 1
  fi
  return 0
}

# 源项目是否在汇聚范围（folders/N 或 organizations/N）之内：祖先链里含该文件夹 / 组织。
# 读不到祖先链时按「不在范围内」处理 —— 保留项目级 sink，最坏是重复收日志，绝不静默断流
hub_project_in_scope() {
  local hps_src="$1" hps_scope="$2" hps_type hps_id
  [[ -n "${hps_scope}" ]] || return 1
  hps_id="${hps_scope##*/}"
  [[ "${hps_scope%%/*}" == "folders" ]] && hps_type="folder" || hps_type="organization"
  gcloud projects get-ancestors "${hps_src}" --format="csv[no-heading](id,type)" 2>/dev/null \
    | tr -d '\r' | grep -qx "${hps_id},${hps_type}"
}
# 打印 HUB_SOURCE_PROJECTS（id=number;...）中位于范围内的项目 ID，每行一个
hub_projects_in_scope() {
  local hpis_raw="$1" hpis_scope="$2" hpis_item
  local -a hpis_items=()
  [[ -n "${hpis_raw}" && -n "${hpis_scope}" ]] || return 0
  IFS=';' read -ra hpis_items <<<"${hpis_raw}"
  for hpis_item in "${hpis_items[@]}"; do
    if hub_project_in_scope "${hpis_item%%=*}" "${hpis_scope}"; then echo "${hpis_item%%=*}"; fi
  done
  return 0
}

# 源项目是否已被本 Hub 的 Metrics Scope 监控（scope 名可能是项目编号或项目 ID）
source_in_hub_metrics_scope() {
  local src="$1" hub_num names
  hub_num="${HUB_PROJECT_NUMBER:-}"
  if [[ -z "${hub_num}" ]]; then
    hub_num=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)" 2>/dev/null || true)
    HUB_PROJECT_NUMBER="${hub_num}"
  fi
  names=$(gcloud beta monitoring metrics-scopes list "projects/${src}" --format="value(metricsScopes[].name)" 2>/dev/null || true)
  tr ';' '\n' <<<"${names}" | grep -qE "^locations/global/metricsScopes/(${PROJECT_ID}${hub_num:+|${hub_num}})\$"
}

connect_source_project() {
  local src="$1"
  local src_num="$2"
  
  log_info "正在连接源项目: ${src} ..."
  
  # S1: 启用 API
  # pubsub：源项目 Monitoring 往 Hub topic 发通知需要源项目自身启用 Pub/Sub API（否则 PERMISSION_DENIED）
  if ! gcloud services enable monitoring.googleapis.com logging.googleapis.com servicehealth.googleapis.com pubsub.googleapis.com --project="${src}" --quiet >/dev/null 2>&1; then
    log_warn "源项目 ${src} 启用 API 失败，将跳过"
    record_skip "源项目 ${src} 启用 API" "功能严重受限" "gcloud services enable monitoring.googleapis.com logging.googleapis.com servicehealth.googleapis.com pubsub.googleapis.com --project=${src}"
    return 1
  fi
  
  # S2: Monitoring 服务代理
  if ! gcloud beta services identity create --service=monitoring.googleapis.com --project="${src}" --quiet >/dev/null 2>&1; then
    log_warn "源项目 ${src} 创建 Monitoring 服务代理失败，将跳过"
    record_skip "源项目 ${src} 创建 Monitoring 服务代理" "无法授权发送" "gcloud beta services identity create --service=monitoring.googleapis.com --project=${src}"
    return 1
  fi
  
  # S3: Pub/Sub 通知渠道
  local channel_display_name="GCP Alerts Hub → ${PROJECT_ID}"
  local channel_name=""
  channel_name=$(gcloud beta monitoring channels list \
    --project="${src}" \
    --filter="displayName=\"${channel_display_name}\" AND type=\"pubsub\"" \
    --format="value(name)" 2>/dev/null | head -1 || true)
    
  if [[ -z "${channel_name}" ]]; then
    channel_name=$(gcloud beta monitoring channels create \
      --project="${src}" \
      --display-name="${channel_display_name}" \
      --type=pubsub \
      --channel-labels="topic=projects/${PROJECT_ID}/topics/${TOPIC_NAME}" \
      --user-labels="gcp-alerts-hub=${PROJECT_ID}" \
      --format="value(name)" 2>/dev/null || true)
    if [[ -z "${channel_name}" ]]; then
      log_warn "源项目 ${src} 创建 Notification Channel 失败，将跳过"
      record_skip "源项目 ${src} 创建渠道" "告警策略无法路由到 Hub" "gcloud beta monitoring channels create --project=${src} --display-name=\"${channel_display_name}\" --type=pubsub --channel-labels=\"topic=projects/${PROJECT_ID}/topics/${TOPIC_NAME}\" --user-labels=\"gcp-alerts-hub=${PROJECT_ID}\""
      return 1
    fi
  else
    # 更新现有渠道，确保 label 指向最新的 topic
    gcloud beta monitoring channels update "${channel_name}" \
      --project="${src}" \
      --channel-labels="topic=projects/${PROJECT_ID}/topics/${TOPIC_NAME}" \
      --user-labels="gcp-alerts-hub=${PROJECT_ID}" --quiet >/dev/null 2>&1 || true
  fi
  
  # S4: topic IAM
  local sa="service-${src_num}@gcp-sa-monitoring-notification.iam.gserviceaccount.com"
  if ! soft_step_retry 12 5 "源项目 ${src} 绑定 topic IAM" "告警因无发布权限而丢弃" "gcloud pubsub topics add-iam-policy-binding ${TOPIC_NAME} --project=${PROJECT_ID} --member=serviceAccount:${sa} --role=roles/pubsub.publisher" -- gcloud pubsub topics add-iam-policy-binding "${TOPIC_NAME}" --project="${PROJECT_ID}" --member="serviceAccount:${sa}" --role="roles/pubsub.publisher"; then
    log_warn "源项目 ${src} 绑定 topic IAM 失败，将跳过"
    record_skip "源项目 ${src} 绑定 topic IAM" "告警投递将被拒绝" "gcloud pubsub topics add-iam-policy-binding \"${TOPIC_NAME}\" --project=\"${PROJECT_ID}\" --member=\"serviceAccount:${sa}\" --role=\"roles/pubsub.publisher\""
    # 不要 return 0 终止，继续尝试下面的，毕竟这是一个组合
  fi
  
  # S5: 项目级日志 sink —— 未设范围，或本项目不在范围内（范围内的由聚合 sink 覆盖，避免重复收日志）
  if ! hub_project_in_scope "${src}" "${HUB_SCOPE:-}"; then
    local sink_name="gcp-alerts-hub-to-${PROJECT_ID}"
    sink_name="${sink_name:0:100}"
    local writer_identity=""
    writer_identity=$(gcloud logging sinks describe "${sink_name}" --project="${src}" --format="value(writerIdentity)" 2>/dev/null || true)
    
    if [[ -z "${writer_identity}" ]]; then
      writer_identity=$(gcloud logging sinks create "${sink_name}" "logging.googleapis.com/projects/${PROJECT_ID}" \
        --project="${src}" \
        --log-filter="${HUB_SINK_FILTER}" \
        --format="value(writerIdentity)" 2>/dev/null || true)
        
      if [[ -z "${writer_identity}" ]]; then
        log_warn "源项目 ${src} 创建 Logging Sink 失败"
        record_skip "源项目 ${src} 创建 Logging Sink" "审计告警无法收集" "gcloud logging sinks create \"${sink_name}\" \"logging.googleapis.com/projects/${PROJECT_ID}\" --project=\"${src}\" --log-filter='...' "
      fi
    else
      gcloud logging sinks update "${sink_name}" "logging.googleapis.com/projects/${PROJECT_ID}" \
        --project="${src}" \
        --log-filter="${HUB_SINK_FILTER}" \
        --quiet >/dev/null 2>&1 || true
    fi
    
    # S6: writer IAM
    if [[ -n "${writer_identity}" ]]; then
      if ! soft_step_retry 12 5 "绑定 Logging Writer IAM" "日志无法写入 Hub" "gcloud projects add-iam-policy-binding ${PROJECT_ID} --member=${writer_identity} --role=roles/logging.logWriter" -- gcloud projects add-iam-policy-binding "${PROJECT_ID}" --member="${writer_identity}" --role="roles/logging.logWriter" --condition=None; then
        log_warn "源项目 ${src} 绑定 Logging Writer IAM 失败"
        record_skip "源项目 ${src} 绑定 Logging Writer IAM" "日志由于无权限将被 Hub 拒绝接收" "gcloud projects add-iam-policy-binding \"${PROJECT_ID}\" --member=\"${writer_identity}\" --role=\"roles/logging.logWriter\""
      fi
    fi
  fi
  
  # S7: Metrics Scope
  # metrics-scopes list 返回「监控该项目的全部 scope」（嵌套在 metricsScopes[] 下，名称用项目编号；
  # 项目自身的 scope 恒在其中，且一个项目可同时属于多个 scope）→ 只判断本 Hub 是否在列，不存在「被别的 scope 占用」
  if source_in_hub_metrics_scope "${src}"; then
    log_info "源项目 ${src} 已加入本 Hub 的 Metrics Scope"
  else
    if ! gcloud beta monitoring metrics-scopes create "projects/${src}" --project="${PROJECT_ID}" --quiet >/dev/null 2>&1; then
      log_warn "源项目 ${src} 关联 Metrics Scope 失败（缺少 monitoring.metricsScopes.link 权限）"
      local member="${DEPLOYER_MEMBER:-}"
      [[ -z "${member}" ]] && member="user:$(gcloud config get-value account 2>/dev/null)"
      record_skip "源项目 ${src} 加入 Metrics Scope" "该项目的监控指标和告警策略无法在 Hub 统一查看" "gcloud projects add-iam-policy-binding ${src} --member=\"${member}\" --role=\"roles/monitoring.metricsScopesAdmin\" && gcloud beta monitoring metrics-scopes create projects/${src} --project=${PROJECT_ID}"
    fi
  fi
  
  log_info "源项目 ${src} 接入完成"
}

disconnect_source_project() {
  local src="$1"
  local src_num="$2"
  
  log_info "正在断开源项目: ${src} ..."
  
  local channel_display_name="GCP Alerts Hub → ${PROJECT_ID}"
  local channel_name=""
  channel_name=$(gcloud beta monitoring channels list \
    --project="${src}" \
    --filter="displayName=\"${channel_display_name}\" AND userLabels.gcp-alerts-hub=\"${PROJECT_ID}\"" \
    --format="value(name)" 2>/dev/null | head -1 || true)
    
  if [[ -n "${channel_name}" ]]; then
    # 解绑所有使用该 channel 的策略
    local policies
    policies=$(gcloud beta monitoring policies list \
      --project="${src}" \
      --filter="notificationChannels:\"${channel_name}\"" \
      --format="value(name)" 2>/dev/null || true)
    for policy in $policies; do
      gcloud beta monitoring policies update "${policy}" \
        --project="${src}" \
        --remove-notification-channels="${channel_name}" \
        --quiet >/dev/null 2>&1 || true
    done
    
    # S3
    gcloud beta monitoring channels delete "${channel_name}" --project="${src}" --force --quiet >/dev/null 2>&1 || true
  fi
  
  # S4
  local sa="service-${src_num}@gcp-sa-monitoring-notification.iam.gserviceaccount.com"
  gcloud pubsub topics remove-iam-policy-binding "${TOPIC_NAME}" \
    --project="${PROJECT_ID}" \
    --member="serviceAccount:${sa}" \
    --role="roles/pubsub.publisher" \
    --condition=None --quiet >/dev/null 2>&1 || true
    
  # S5, S6
  local sink_name="gcp-alerts-hub-to-${PROJECT_ID}"
  sink_name="${sink_name:0:100}"
  local writer_identity=""
  writer_identity=$(gcloud logging sinks describe "${sink_name}" --project="${src}" --format="value(writerIdentity)" 2>/dev/null || true)
  if [[ -n "${writer_identity}" ]]; then
    gcloud logging sinks delete "${sink_name}" --project="${src}" --quiet >/dev/null 2>&1 || true
    gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
      --member="${writer_identity}" \
      --role="roles/logging.logWriter" \
      --condition=None --quiet >/dev/null 2>&1 || true
  fi
  
  # S7
  gcloud beta monitoring metrics-scopes delete "projects/${src}" --project="${PROJECT_ID}" --quiet >/dev/null 2>&1 || true
}

# Hub 侧回灌 sink：路由进 Hub 的源项目审计日志会被 Hub 的 _Default sink 按 LOG_ID 排除而丢弃，
# 日志型告警只评估 _Default 桶 → 把「非本项目」的审计日志写回 _Default 桶（与 TF hub_routed_audit 对等）
HUB_ROUTED_AUDIT_SINK="gcp-alerts-hub-routed-audit"
ensure_hub_routed_audit_sink() {
  local filter dest
  filter="(LOG_ID(\"cloudaudit.googleapis.com/activity\") OR LOG_ID(\"cloudaudit.googleapis.com/system_event\")) AND NOT logName:\"projects/${PROJECT_ID}/\""
  dest="logging.googleapis.com/projects/${PROJECT_ID}/locations/global/buckets/_Default"
  if gcloud logging sinks describe "${HUB_ROUTED_AUDIT_SINK}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud logging sinks update "${HUB_ROUTED_AUDIT_SINK}" "${dest}" --log-filter="${filter}" --project="${PROJECT_ID}" --quiet >/dev/null 2>&1 \
      || { record_skip "Hub 回灌审计日志 sink" "源项目的高危 IAM / SA 密钥 / 宿主机维护告警不会触发" "gcloud logging sinks update ${HUB_ROUTED_AUDIT_SINK} ${dest} --log-filter='${filter}' --project=${PROJECT_ID}"; return 1; }
  else
    gcloud logging sinks create "${HUB_ROUTED_AUDIT_SINK}" "${dest}" --log-filter="${filter}" --project="${PROJECT_ID}" --quiet >/dev/null 2>&1 \
      || { record_skip "Hub 回灌审计日志 sink" "源项目的高危 IAM / SA 密钥 / 宿主机维护告警不会触发" "gcloud logging sinks create ${HUB_ROUTED_AUDIT_SINK} ${dest} --log-filter='${filter}' --project=${PROJECT_ID}"; return 1; }
  fi
  log_info "Hub 回灌审计日志 sink 已就绪（${HUB_ROUTED_AUDIT_SINK} → _Default 桶）"
}
remove_hub_routed_audit_sink() {
  gcloud logging sinks delete "${HUB_ROUTED_AUDIT_SINK}" --project="${PROJECT_ID}" --quiet >/dev/null 2>&1 || true
}

ensure_hub_scope_sink() {
  local scope="$1"
  local sink_name="gcp-alerts-hub-to-${PROJECT_ID}"
  sink_name="${sink_name:0:100}"
  
  local scope_type="${scope%%/*}"  # folders or organizations
  local scope_id="${scope##*/}"
  local writer_identity=""
  
  if [[ "${scope_type}" == "folders" ]]; then
    writer_identity=$(gcloud logging sinks describe "${sink_name}" --folder="${scope_id}" --format="value(writerIdentity)" 2>/dev/null || true)
  else
    writer_identity=$(gcloud logging sinks describe "${sink_name}" --organization="${scope_id}" --format="value(writerIdentity)" 2>/dev/null || true)
  fi
  
  if [[ -z "${writer_identity}" ]]; then
    local create_cmd="gcloud logging sinks create \"${sink_name}\" \"logging.googleapis.com/projects/${PROJECT_ID}\" --${scope_type%s}=\"${scope_id}\" --include-children --log-filter='...' --format=\"value(writerIdentity)\""
    if [[ "${scope_type}" == "folders" ]]; then
      writer_identity=$(gcloud logging sinks create "${sink_name}" "logging.googleapis.com/projects/${PROJECT_ID}" \
        --folder="${scope_id}" \
        --include-children \
        --log-filter="${HUB_SINK_FILTER}" \
        --format="value(writerIdentity)" 2>/dev/null || true)
    else
      writer_identity=$(gcloud logging sinks create "${sink_name}" "logging.googleapis.com/projects/${PROJECT_ID}" \
        --organization="${scope_id}" \
        --include-children \
        --log-filter="${HUB_SINK_FILTER}" \
        --format="value(writerIdentity)" 2>/dev/null || true)
    fi
    if [[ -z "${writer_identity}" ]]; then
      log_warn "创建聚合 Logging Sink 失败"
      record_skip "创建聚合 Logging Sink" "高危 IAM 与 SA 密钥创建等审计告警无法收集" "${create_cmd}"
      return 0
    fi
  else
    if [[ "${scope_type}" == "folders" ]]; then
      gcloud logging sinks update "${sink_name}" "logging.googleapis.com/projects/${PROJECT_ID}" \
        --folder="${scope_id}" \
        --include-children \
        --log-filter="${HUB_SINK_FILTER}" \
        --quiet >/dev/null 2>&1 || true
    else
      gcloud logging sinks update "${sink_name}" "logging.googleapis.com/projects/${PROJECT_ID}" \
        --organization="${scope_id}" \
        --include-children \
        --log-filter="${HUB_SINK_FILTER}" \
        --quiet >/dev/null 2>&1 || true
    fi
  fi
  
  if [[ -n "${writer_identity}" ]]; then
    if ! soft_step_retry 12 5 "绑定 Logging Writer IAM" "日志无法写入 Hub" "gcloud projects add-iam-policy-binding ${PROJECT_ID} --member=${writer_identity} --role=roles/logging.logWriter" -- gcloud projects add-iam-policy-binding "${PROJECT_ID}" --member="${writer_identity}" --role="roles/logging.logWriter" --condition=None; then
      log_warn "聚合 Logging Writer 授权失败"
      record_skip "源项目 ${src} 绑定 Logging Writer IAM" "日志由于无权限将被 Hub 拒绝接收" "gcloud projects add-iam-policy-binding \"${PROJECT_ID}\" --member=\"${writer_identity}\" --role=\"roles/logging.logWriter\""
    fi
  fi
}

remove_hub_scope_sink() {
  local scope="$1"
  [[ -z "${scope}" ]] && return 0
  
  local sink_name="gcp-alerts-hub-to-${PROJECT_ID}"
  sink_name="${sink_name:0:100}"
  local scope_type="${scope%%/*}"
  local scope_id="${scope##*/}"
  local writer_identity=""
  
  if [[ "${scope_type}" == "folders" ]]; then
    writer_identity=$(gcloud logging sinks describe "${sink_name}" --folder="${scope_id}" --format="value(writerIdentity)" 2>/dev/null || true)
  else
    writer_identity=$(gcloud logging sinks describe "${sink_name}" --organization="${scope_id}" --format="value(writerIdentity)" 2>/dev/null || true)
  fi
  
  if [[ "${scope_type}" == "folders" ]]; then
    gcloud logging sinks delete "${sink_name}" --folder="${scope_id}" --quiet >/dev/null 2>&1 || true
  else
    gcloud logging sinks delete "${sink_name}" --organization="${scope_id}" --quiet >/dev/null 2>&1 || true
  fi
  if [[ -n "${writer_identity}" ]]; then
    gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
      --member="${writer_identity}" \
      --role="roles/logging.logWriter" \
      --condition=None --quiet >/dev/null 2>&1 || true
  fi
}

# 把线上源项目集合（LIVE_HUB_SOURCE_PROJECTS / LIVE_HUB_SCOPE）同步为目标（HUB_SOURCE_PROJECTS / HUB_SCOPE）。
#   移除的项目 → disconnect；目标里的全部项目 → connect（幂等，重跑即自愈）；
#   范围 无→有：删保留项目的项目级 sink（改由聚合 sink 收日志）；有→无：connect 会补建项目级 sink。
reconcile_hub_sources() {
  local old_raw="${LIVE_HUB_SOURCE_PROJECTS:-}" new_raw="${HUB_SOURCE_PROJECTS:-}"
  local old_scope="${LIVE_HUB_SCOPE:-}" new_scope="${HUB_SCOPE:-}"
  local -a old_items=() new_items=() added=() removed=() incomplete=()
  local item id
  [[ -n "${old_raw}" ]] && IFS=';' read -ra old_items <<< "${old_raw}"
  [[ -n "${new_raw}" ]] && IFS=';' read -ra new_items <<< "${new_raw}"

  for item in "${old_items[@]}"; do
    [[ ";${new_raw};" == *";${item%%=*}="* ]] || removed+=("${item}")
  done
  for item in "${new_items[@]}"; do
    [[ ";${old_raw};" == *";${item%%=*}="* ]] || added+=("${item}")
  done

  if [[ "${old_scope}" != "${new_scope}" ]]; then
    [[ -n "${old_scope}" ]] && remove_hub_scope_sink "${old_scope}"
    [[ -n "${new_scope}" ]] && ensure_hub_scope_sink "${new_scope}"
  fi
  # 设置了范围：只删「范围内」源项目的项目级 sink（会与聚合 sink 重复）；范围外的保留，否则其日志静默断流
  if [[ -n "${new_scope}" ]]; then
    for item in "${new_items[@]}"; do
      if hub_project_in_scope "${item%%=*}" "${new_scope}"; then
        _remove_project_hub_sink "${item%%=*}"
      fi
    done
  fi

  for item in "${removed[@]}"; do
    disconnect_source_project "${item%%=*}" "${item#*=}" || incomplete+=("${item%%=*}(断开)")
  done
  for item in "${new_items[@]}"; do
    connect_source_project "${item%%=*}" "${item#*=}" || incomplete+=("${item%%=*}")
  done

  if (( ${#new_items[@]} > 0 )) || [[ -n "${new_scope}" ]]; then
    ensure_hub_routed_audit_sink || incomplete+=("Hub 回灌 sink")
  elif (( ${#old_items[@]} > 0 )) || [[ -n "${old_scope}" ]]; then
    remove_hub_routed_audit_sink
  fi

  if (( ${#new_items[@]} > 0 || ${#removed[@]} > 0 )) || [[ "${old_scope}" != "${new_scope}" ]]; then
    echo "========= Hub 源项目同步 ========="
    echo "  汇聚范围: ${new_scope:-（未设置，逐项目 sink）}"
    echo "  源项目数: ${#new_items[@]}"
    (( ${#added[@]} > 0 ))      && echo "  新增: $(printf '%s ' "${added[@]%%=*}")"
    (( ${#removed[@]} > 0 ))    && echo "  移除: $(printf '%s ' "${removed[@]%%=*}")"
    (( ${#incomplete[@]} > 0 )) && echo "  ⚠️ 未完成: $(printf '%s ' "${incomplete[@]}")（详见上方跳过项与汇总）"
    echo "=================================="
  fi
  return 0
}

# 删除源项目里本 Hub 的项目级 sink 及其在 Hub 上的 logWriter 授权（不存在则无事发生）
_remove_project_hub_sink() {
  local src=$1 sink_name="gcp-alerts-hub-to-${PROJECT_ID}" writer
  sink_name="${sink_name:0:100}"
  writer=$(gcloud logging sinks describe "${sink_name}" --project="${src}" --format="value(writerIdentity)" 2>/dev/null || true)
  [[ -z "${writer}" ]] && return 0
  gcloud logging sinks delete "${sink_name}" --project="${src}" --quiet >/dev/null 2>&1 \
    || record_skip "删除源项目 ${src} 的日志 sink ${sink_name}" "与聚合 sink 重复收日志（PSH/审计告警可能重复）" \
         "gcloud logging sinks delete ${sink_name} --project=${src}"
  gcloud projects remove-iam-policy-binding "${PROJECT_ID}" --member="${writer}" --role="roles/logging.logWriter" \
    --condition=None --quiet >/dev/null 2>&1 || true
}

list_scope_projects() {
  local scope="$1"
  [[ -z "${scope}" ]] && return 0
  
  local scope_type="${scope%%/*}"
  local scope_id="${scope##*/}"
  
  if [[ "${scope_type}" == "organizations" ]]; then
    # 列出组织下所有 ACTIVE 项目（不带 filter=parent 会搜全组织）
    gcloud projects list --filter="lifecycleState=ACTIVE AND parent.id=${scope_id} AND parent.type=organization" --format="value(projectId,projectNumber)" 2>/dev/null | awk '{print $1"="$2}'
    
    # 递归查找所有文件夹并列出其中的项目
    local folders
    folders=$(gcloud resource-manager folders list --organization="${scope_id}" --format="value(name)" 2>/dev/null || true)
    for folder in ${folders}; do
      list_scope_projects "${folder}"
    done
  else
    # 列出当前文件夹下的项目
    gcloud projects list --filter="lifecycleState=ACTIVE AND parent.id=${scope_id} AND parent.type=folder" --format="value(projectId,projectNumber)" 2>/dev/null | awk '{print $1"="$2}'
    
    # 递归查找子文件夹
    local folders
    folders=$(gcloud resource-manager folders list --folder="${scope_id}" --format="value(name)" 2>/dev/null || true)
    for folder in ${folders}; do
      list_scope_projects "${folder}"
    done
  fi
}

list_source_policies() {
  local src="$1"
  local channel_display_name="GCP Alerts Hub → ${PROJECT_ID}"
  local channel_name=""
  channel_name=$(gcloud beta monitoring channels list \
    --project="${src}" \
    --filter="displayName=\"${channel_display_name}\" AND userLabels.gcp-alerts-hub=\"${PROJECT_ID}\"" \
    --format="value(name)" 2>/dev/null | head -1 || true)
    
  # value() 以制表符分隔字段；displayName 可含空格，必须按 \t 切分（不能用 awk 默认空白切分）
  local p_name p_disp p_en p_chans bound
  gcloud beta monitoring policies list --project="${src}" --format="value(name,displayName,enabled,notificationChannels)" 2>/dev/null | \
  while IFS=$'\t' read -r p_name p_disp p_en p_chans; do
    [[ -n "${p_name}" ]] || continue
    bound="N"
    if [[ -n "${channel_name}" && "${p_chans}" == *"${channel_name}"* ]]; then
      bound="Y"
    fi
    printf '%s\t%s\t%s\t%s\n' "${p_name}" "${p_disp}" "${p_en}" "${bound}"
  done
}

bind_policies_to_hub() {
  local src="$1"
  shift
  local policies=("$@")
  
  local channel_display_name="GCP Alerts Hub → ${PROJECT_ID}"
  local channel_name=""
  channel_name=$(gcloud beta monitoring channels list \
    --project="${src}" \
    --filter="displayName=\"${channel_display_name}\" AND userLabels.gcp-alerts-hub=\"${PROJECT_ID}\"" \
    --format="value(name)" 2>/dev/null | head -1 || true)
    
  if [[ -z "${channel_name}" ]]; then
    log_error "在 ${src} 中找不到本 Hub 的通知渠道，请先确保该项目已接入。"
    return 1
  fi
  
  local p rc=0 err
  for p in "${policies[@]}"; do
    if ! err=$(gcloud beta monitoring policies update "${p}" \
      --project="${src}" \
      --add-notification-channels="${channel_name}" \
      --quiet 2>&1 >/dev/null); then
      log_error "策略 ${p} 追加 Hub 渠道失败：${err}"
      rc=1
    fi
  done
  return "${rc}"
}

unbind_policies_from_hub() {
  local src="$1"
  shift
  local policies=("$@")
  
  local channel_display_name="GCP Alerts Hub → ${PROJECT_ID}"
  local channel_name=""
  channel_name=$(gcloud beta monitoring channels list \
    --project="${src}" \
    --filter="displayName=\"${channel_display_name}\" AND userLabels.gcp-alerts-hub=\"${PROJECT_ID}\"" \
    --format="value(name)" 2>/dev/null | head -1 || true)
    
  [[ -z "${channel_name}" ]] && return 0
  
  local p rc=0 err
  for p in "${policies[@]}"; do
    if ! err=$(gcloud beta monitoring policies update "${p}" \
      --project="${src}" \
      --remove-notification-channels="${channel_name}" \
      --quiet 2>&1 >/dev/null); then
      log_error "策略 ${p} 移除 Hub 渠道失败：${err}"
      rc=1
    fi
  done
  return "${rc}"
}

hub_health_check() {
  echo "正在检查 Hub 连接状态..."
  local raw="${HUB_SOURCE_PROJECTS:-}"
  local scope="${HUB_SCOPE:-}"
  
  if [[ -z "${raw}" ]]; then
    echo "未配置任何源项目 (非 Hub 模式)。"
    return 0
  fi
  
  if [[ -n "${scope}" ]]; then
    echo "配置了范围: ${scope}"
    local sink_name="gcp-alerts-hub-to-${PROJECT_ID}"
    sink_name="${sink_name:0:100}"
    local scope_type="${scope%%/*}"
    local scope_id="${scope##*/}"
    local writer_identity=""
    if [[ "${scope_type}" == "folders" ]]; then
      writer_identity=$(gcloud logging sinks describe "${sink_name}" --folder="${scope_id}" --format="value(writerIdentity)" 2>/dev/null || true)
    else
      writer_identity=$(gcloud logging sinks describe "${sink_name}" --organization="${scope_id}" --format="value(writerIdentity)" 2>/dev/null || true)
    fi
    if [[ -n "${writer_identity}" ]]; then
      echo "  [✅] 聚合 Logging Sink 存在 (${writer_identity})"
    else
      echo "  [❌] 聚合 Logging Sink 缺失"
    fi
  fi
  
  if gcloud logging sinks describe "${HUB_ROUTED_AUDIT_SINK}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "  [✅] Hub 回灌审计日志 sink 存在（${HUB_ROUTED_AUDIT_SINK}）"
  else
    echo "  [❌] Hub 回灌审计日志 sink 缺失：源项目的高危 IAM / SA 密钥 / 宿主机维护告警不会触发"
  fi

  IFS=';' read -ra items <<< "${raw}"
  for item in "${items[@]}"; do
    local src="${item%%=*}"
    local src_num="${item#*=}"
    
    echo "源项目: ${src} (${src_num})"
    
    # S1
    local enabled_apis missing_apis="" api
    enabled_apis=$(gcloud services list --project="${src}" --enabled --format="value(config.name)" 2>/dev/null || true)
    for api in monitoring.googleapis.com logging.googleapis.com servicehealth.googleapis.com pubsub.googleapis.com; do
      grep -qx "${api}" <<<"${enabled_apis}" || missing_apis+=" ${api}"
    done
    if [[ -z "${missing_apis}" ]]; then
      echo "  [✅] API 状态 (monitoring / logging / servicehealth / pubsub 均已启用)"
    else
      echo "  [❌] API 未启用:${missing_apis}"
    fi
    
    # S3
    local channel_display_name="GCP Alerts Hub → ${PROJECT_ID}"
    local channel_name=""
    channel_name=$(gcloud beta monitoring channels list \
      --project="${src}" \
      --filter="displayName=\"${channel_display_name}\" AND userLabels.gcp-alerts-hub=\"${PROJECT_ID}\"" \
      --format="value(name)" 2>/dev/null | head -1 || true)
    if [[ -n "${channel_name}" ]]; then
      echo "  [✅] Pub/Sub 通知渠道存在"
    else
      echo "  [❌] Pub/Sub 通知渠道缺失"
    fi
    
    # S4 (Topic IAM)
    local sa="service-${src_num}@gcp-sa-monitoring-notification.iam.gserviceaccount.com"
    if gcloud pubsub topics get-iam-policy "${TOPIC_NAME}" --project="${PROJECT_ID}" --format="json" 2>/dev/null | grep -q "${sa}"; then
      echo "  [✅] Topic IAM 绑定存在"
    else
      echo "  [❌] Topic IAM 绑定缺失"
    fi
    
    # S5, S6
    if [[ -z "${scope}" ]]; then
      local sink_name="gcp-alerts-hub-to-${PROJECT_ID}"
      sink_name="${sink_name:0:100}"
      local writer_identity=""
      writer_identity=$(gcloud logging sinks describe "${sink_name}" --project="${src}" --format="value(writerIdentity)" 2>/dev/null || true)
      if [[ -n "${writer_identity}" ]]; then
        echo "  [✅] 日志 Sink 存在"
        if gcloud projects get-iam-policy "${PROJECT_ID}" --format="json" 2>/dev/null | grep -q "${writer_identity}"; then
          echo "  [✅] 日志 Sink Writer IAM 绑定存在"
        else
          echo "  [❌] 日志 Sink Writer IAM 绑定缺失"
        fi
      else
        echo "  [❌] 日志 Sink 缺失"
      fi
    fi
    
    # S7
    if source_in_hub_metrics_scope "${src}"; then
      echo "  [✅] Metrics Scope 已关联"
    else
      echo "  [❌] Metrics Scope 未关联"
    fi
    
    # 统计绑定策略数
    if [[ -n "${channel_name}" ]]; then
      local count
      count=$(gcloud beta monitoring policies list --project="${src}" --filter="notificationChannels:\"${channel_name}\"" --format="value(name)" 2>/dev/null | wc -l || true)
      echo "  - 已绑定告警策略数: ${count}"
    else
      echo "  - 已绑定告警策略数: 0 (因渠道缺失)"
    fi
  done
}
