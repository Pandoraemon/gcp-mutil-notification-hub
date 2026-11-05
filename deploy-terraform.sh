#!/bin/bash
# Terraform 生产部署路径：约 15 分钟，产出可版本化、可 destroy 的完整基础设施。
#
# 与 gcloud 路径功能对等（同样的 topic / DLQ / 函数配置 / 四大数据源），
# 差别只在生命周期管理方式，见 docs/deployment-comparison.md。
set -euo pipefail

cd "$(dirname "$0")"
source lib/common.sh

REGION="asia-east1"
ASSUME_YES=false
PROJECT_FLAG=""

usage() {
  cat <<'USAGE'
用法: ./deploy-terraform.sh [选项]
  --project=ID      部署到指定项目（不传则交互式选择，见下）
  --region=REGION   部署区域（默认 asia-east1）
  --yes             跳过确认提示并对 terraform apply 自动批准（CI 用）
  --help, -h        显示此帮助

项目选择:
  优先级 --project 参数 > PROJECT_ID 环境变量 > 交互式选择 > gcloud 默认项目。
  交互模式下会列出当前账号可见的项目供选择；--yes 模式下必须显式指定项目。
  选定的项目只在本次运行内生效，不会改写你的 gcloud 默认配置。
  注意：切换项目等于切换 tfstate bucket（<项目>-gcp-feishu-tfstate），
  两个项目各自持有独立的 state，互不影响。

环境变量:
  PROJECT_ID                       目标项目（等价于 --project）
  NOTIFY_CHANNEL                   通知渠道：feishu | wecom | dingtalk（默认 feishu；交互模式下菜单选择），
                                   写入 tfvars 的 notify_channel
  FEISHU_WEBHOOK / FEISHU_SECRET   NOTIFY_CHANNEL=feishu 时的飞书/Lark 凭据（密钥未开启签名校验时填 NONE）
  WECOM_WEBHOOK                    NOTIFY_CHANNEL=wecom 时的企业微信群机器人 Webhook（无签名）
  DINGTALK_WEBHOOK / DINGTALK_SECRET
                                   NOTIFY_CHANNEL=dingtalk 时的钉钉凭据（推荐加签，填 SEC 开头的密钥；
                                   未开启加签填 NONE，此时若用自定义关键词，关键词须为「GCP告警」）
  MAX_SENDS_PER_MINUTE             每实例每分钟发送上限；不设置则 tfvars 不写，由 Terraform 按渠道推导
                                   （飞书 40 / 企业微信 8 / 钉钉 8）；须满足 速率 × MAX_INSTANCES ≤ 80 / 16 / 16
  MAX_INSTANCES                    函数最大实例数（默认 2），写入 tfvars 的 max_instances
  MIN_SEVERITY / LOG_LEVEL         最低转发级别（默认 MEDIUM）/ 日志级别（默认 INFO），写入 tfvars 的 min_severity / log_level
  SOURCE_MIN_SEVERITY              按来源最低转发级别，格式 key=VALUE;...（如 monitoring=HIGH;billing=OFF）
  KILL_SWITCH / PAUSE_MODE         急停 / 暂停开关 true | false（未提供时复位为 false），写入 tfvars 的 kill_switch / pause_mode
  CONFIG_REVISION                  配置修订号，写入 tfvars 的 config_revision（scripts/configure.sh 每次应用时更新，强制拉新 revision）
  KEEP_EXISTING_SECRETS=true       沿用 Secret Manager 中本渠道的现有凭据（不输入、不追加新版本；会校验 Secret 存在且有启用版本）
  TF_APPLY_CONFIRM=interactive     与 --yes 同用时：其余提示照常跳过，但在 terraform plan 之后仍停下要求输入 yes
                                   （scripts/configure.sh 交互模式使用；取消时退出码 3）。默认 auto
  SECRET_WEBHOOK_NAME / SECRET_SIGN_NAME
                                   飞书 Secret 名（默认 feishu-default-webhook / feishu-default-secret）
  SECRET_WECOM_WEBHOOK_NAME        企业微信 Secret 名（默认 wecom-default-webhook）
  SECRET_DINGTALK_WEBHOOK_NAME / SECRET_DINGTALK_SIGN_NAME
                                   钉钉 Secret 名（默认 dingtalk-default-webhook / dingtalk-default-secret）
  ENABLE_PSH                       是否部署默认 PSH 官方两类告警策略集（Y/n，默认 Y）
  ENABLE_DEFAULT_ALERTS            是否部署推荐默认监控告警包（GCE/配额/LB&NAT/GKE&SQL/IAM审计，y/N，默认 N）
  ENABLE_SCC / ENABLE_BILLING      非交互模式下的可选数据源开关（y/N，默认 N）
  BUDGET_AMOUNT                    启用 Billing 时的月度预算金额数字（默认 100）
  BILLING_ACCOUNT_ID               结算账号（形如 01ABCD-2345EF-6789AB）。不设置时用 gcloud 读取，读不到再用本机
                                   terraform.tfvars 原有的 billing_account_id；仍读不到且线上已有预算（或沿用线上）时中止，
                                   绝不写 enable_billing=false 去删除已有预算
  OPS_EMAIL                        自监控告警（永久发送失败 / DLQ 积压）的邮件收件人，写入 tfvars 的 ops_email；空则跳过并登记
  DEPLOYER_MEMBER                  覆盖补救提示中的 --member（默认按 gcloud 当前账号自动解析为 user:/serviceAccount:）

重跑不回退线上配置:
  函数已存在时，未显式提供的 NOTIFY_CHANNEL / MIN_SEVERITY / LOG_LEVEL / MAX_SENDS_PER_MINUTE（同渠道）/
  MAX_INSTANCES / CONFIG_REVISION / ENABLE_PSH / ENABLE_DEFAULT_ALERTS / ENABLE_SCC / ENABLE_BILLING /
  BUDGET_AMOUNT / OPS_EMAIL 沿用线上现值（读不到时先用本机 terraform.tfvars 兜底；仍未知则 --yes 下报错要求
  显式提供、交互模式下询问 —— 以免 apply 误删资源）；KILL_SWITCH / PAUSE_MODE 未提供时复位为 false（线上为 true 时 WARNING）。
  交互式修改全部配置请用 ./scripts/configure.sh。

密钥所有权:
  Secret 的【值】由本脚本用 gcloud 写入，Terraform 只用 data 源只读引用并授予 accessor。
  这样密文不会进入 tfstate 与 tfvars。
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

require_commands gcloud terraform

# 必须在生成 backend.tf 之前确定项目：state bucket 名由项目 ID 派生，
# 选错项目会让 terraform 接管另一份 state。
select_project "${PROJECT_FLAG}"
BUCKET_NAME="${PROJECT_ID}-gcp-feishu-tfstate"
# 补救提示里的 --member 用运行时解析出的部署者身份（可用 DEPLOYER_MEMBER 覆盖）
resolve_deployer_member

echo "==== GCP 告警转发（飞书 / 企业微信 / 钉钉）- Terraform 生产部署 ===="
echo "项目 ID: ${PROJECT_ID} / 区域: ${REGION} / 部署者: ${DEPLOYER_MEMBER}"
echo "Terraform State Bucket: ${BUCKET_NAME}"
echo ""

# 0.5 运行时配置：未显式提供的项沿用线上现值，KILL_SWITCH / PAUSE_MODE 复位为 false（与 gcloud 路径同一实现）
resolve_runtime_config "${REGION}" terraform

# 1. 交互式输入（渠道三选一，与 gcloud 路径共用同一份实现与校验；KEEP_EXISTING_SECRETS=true 时只校验现有 Secret）
prompt_channel_credentials
# 同渠道且未显式设置速率时沿用线上值；速率上限校验与 Terraform precondition 同口径，提前拦，避免 plan 才报错
inherit_live_send_rate
validate_channel_rate_limit
prompt_optional_sources

# 1.5 部署者权限预检（只读）。Terraform 路径缺权限是 apply 硬失败 + 半成品 state，
#     比 gcloud 路径的 soft_step 降级更痛，更值得在动手前先查一遍。
preflight_deployer_permissions
preflight_hub_scope_permissions || die "汇聚范围权限不足，未做任何修改。补齐权限后重跑"

# 2. 启用 API + 服务代理
check_and_enable_apis
ensure_service_agents

# 2.5 构建身份
# 必须在 terraform apply 之前。Terraform 创建 Gen2 函数同样要过 Cloud Build，
# 而全新项目的默认 compute SA 不带 cloudbuild.builds.builder ——
# 缺这一条时 apply 会【硬失败中断】并留下半成品 state，实测报错：
#   Error: Build failed with status: FAILURE. Could not build the function
#   due to a missing permission on the build service account.
# 注意顺序：该 SA 随 cloudbuild/run 等 API 首次启用而创建，
# 所以这一步必须排在 check_and_enable_apis 之后，否则会查无此 SA。
ensure_build_sa_role "${PROJECT_ID}"

# 3. 创建 Terraform State Bucket（幂等）
if ! gcloud storage buckets describe "gs://${BUCKET_NAME}" >/dev/null 2>&1; then
  echo "创建 Terraform State Bucket..."
  gcloud storage buckets create "gs://${BUCKET_NAME}" \
    --project="${PROJECT_ID}" --location="${REGION}" \
    --uniform-bucket-level-access --public-access-prevention
  gcloud storage buckets update "gs://${BUCKET_NAME}" --versioning
  log_ok "State Bucket 创建成功（已启用版本控制 + UBLA + 公开访问阻止）"
else
  log_ok "State Bucket 已存在"
fi

# 4. 生成 backend.tf
cat > terraform/backend.tf <<EOF
# 本文件由 deploy-terraform.sh 自动生成，请勿手工编辑（已在 .gitignore 中忽略）。
terraform {
  backend "gcs" {
    bucket = "${BUCKET_NAME}"
    prefix = "terraform/state"
  }
}
EOF

# 5. Secret Manager —— 由脚本（而非 Terraform）拥有
#    密钥【值】必须由脚本管理：若交给 Terraform，明文会落进 tfstate。
#    Terraform 侧只用 data 源只读引用 + 授予 accessor（见 terraform/secrets.tf）。
#    upsert_secret 保证重跑换新 webhook 时追加新版本，而不是静默保留旧值。
#    只写所选渠道的 Secret（与 gcloud 路径同一个 upsert_channel_secrets）。
echo "配置 Secret Manager（${CHANNEL_LABEL}）..."
upsert_channel_secrets

# 6. 生成 terraform.tfvars（不含任何密文，只含 secret 名称引用）
to_bool() { [[ "$1" =~ ^[Yy]$ ]] && echo true || echo false; }

BILLING_ACCOUNT=""
if [[ "${ENABLE_BILLING}" =~ ^[Yy]$ ]]; then
  # 结算账号来源优先级：BILLING_ACCOUNT_ID 环境变量 > gcloud 实时读取 > 本机 terraform.tfvars 原有的 billing_account_id。
  BILLING_ACCOUNT_SOURCE=""
  if [[ -n "${BILLING_ACCOUNT_ID:-}" ]]; then
    BILLING_ACCOUNT="${BILLING_ACCOUNT_ID#billingAccounts/}"; BILLING_ACCOUNT_SOURCE="环境变量 BILLING_ACCOUNT_ID"
  else
    # `|| true` 不可省：pipefail 在 $() 内同样生效，无 billing.viewer 时会无声硬退出，
    # 下面的 record_skip 永远到不了（与 deploy-gcloud.sh 同一处坑）。
    BILLING_ACCOUNT=$(gcloud billing projects describe "${PROJECT_ID}" \
      --format="value(billingAccountName)" 2>/dev/null | sed 's|billingAccounts/||' || true)
    if [[ -z "${BILLING_ACCOUNT}" ]]; then
      BILLING_ACCOUNT="$(_tfvar billing_account_id)"
      [[ -n "${BILLING_ACCOUNT}" ]] && BILLING_ACCOUNT_SOURCE="本机 terraform/terraform.tfvars 原有的 billing_account_id"
    fi
  fi
  [[ -z "${BILLING_ACCOUNT}" || "${BILLING_ACCOUNT}" =~ ^[A-Za-z0-9]{6}-[A-Za-z0-9]{6}-[A-Za-z0-9]{6}$ ]] || \
    die "结算账号 ${BILLING_ACCOUNT}（来自${BILLING_ACCOUNT_SOURCE:-gcloud}）格式无效：应形如 01ABCD-2345EF-6789AB"
  [[ -n "${BILLING_ACCOUNT_SOURCE}" && -n "${BILLING_ACCOUNT}" ]] && \
    log_info "Billing：结算账号取自${BILLING_ACCOUNT_SOURCE}（${BILLING_ACCOUNT}）"
  if [[ -z "${BILLING_ACCOUNT}" ]]; then
    # 读不到结算账号时【不能】一律降级成 enable_billing=false：Terraform 下那等于在 apply 里
    # 静默删除 state 中已有的预算。只有「用户显式要开 + 已确认线上本来就没有预算」才允许降级；
    # 首次部署（函数不存在）没有线上预算可删，保持旧行为。
    if [[ "${LIVE_FUNCTION_STATE:-}" == "present" && -z "${LIVE_BILLING:-}" ]]; then
      load_live_resources      # 部署者显式给全了可选开关时 resolve_runtime_config 不会读现状，这里补读
      apply_tfvars_fallback
    fi
    BILLING_LIVE_STATE="${LIVE_BILLING:-off}"
    [[ "${LIVE_FUNCTION_STATE:-}" == "present" ]] || BILLING_LIVE_STATE=off
    if _optional_is_inherited ENABLE_BILLING || [[ "${BILLING_LIVE_STATE}" != "off" ]]; then
      die "Billing 预算已启用（$( _optional_is_inherited ENABLE_BILLING && echo "沿用线上现状" || echo "线上预算现状：${BILLING_LIVE_STATE}")），但读不到项目的结算账号。
   此时若继续，Terraform 会写入 enable_billing=false 并在 apply 中【删除已有预算】，因此中止（未做任何修改）。
   补救（三选一）：
     1) 授权后重跑：gcloud projects add-iam-policy-binding ${PROJECT_ID} --member=\"${DEPLOYER_MEMBER}\" --role=roles/billing.viewer
        （管理预算还需结算账号上的 roles/billing.costsManager：gcloud billing accounts add-iam-policy-binding <结算账号> --member=\"${DEPLOYER_MEMBER}\" --role=roles/billing.costsManager）
     2) 显式提供结算账号：BILLING_ACCOUNT_ID=01ABCD-2345EF-6789AB ./deploy-terraform.sh ...
     3) 确实要关闭预算告警：ENABLE_BILLING=N ./deploy-terraform.sh ...（apply 会删除预算）"
    fi
    record_skip "启用 Terraform 的 Billing 模块" "预算超支不会转发到${CHANNEL_LABEL}" \
      "gcloud projects add-iam-policy-binding ${PROJECT_ID} --member=\"${DEPLOYER_MEMBER}\" --role=roles/billing.viewer（或设置 BILLING_ACCOUNT_ID=<结算账号>）"
    ENABLE_BILLING=N
  fi
fi

ORG_ID=""
if [[ "${ENABLE_SCC}" =~ ^[Yy]$ ]]; then
  # gcloud projects get-ancestors 【不支持 --filter】（传了会报 unrecognized arguments，
  # 在这里的命令替换赋值下 set -e 会直接终止脚本）。与 deploy-gcloud.sh 同一写法：
  # 拿 csv 沿祖先链挑出 type=organization 那一行；|| true 兜住无组织的情况。
  ORG_ID=$(gcloud projects get-ancestors "${PROJECT_ID}" \
    --format="csv[no-heading](id,type)" 2>/dev/null \
    | awk -F, '$2=="organization"{print $1}' | head -1) || true
  if [[ -z "${ORG_ID}" ]]; then
    record_skip "启用 Terraform 的 SCC 模块" "安全发现不会转发到${CHANNEL_LABEL}" \
      "项目不隶属于任何组织，SCC 本就不可用 —— 无需处理"
    ENABLE_SCC=N
  fi
fi

# 自监控告警（永久发送失败 / DLQ 积压 → 邮件）由 .tf 实现，这里只透传收件人。
# 空值允许：Terraform 侧据此跳过创建，但本脚本要如实登记，不能让"没人收告警"静默过去。
if [[ -z "${OPS_EMAIL:-}" ]]; then
  record_skip "自监控告警（永久发送失败 / DLQ 积压）" \
    "IM 链路自身故障时【无人知晓】：webhook 失效、消息进 DLQ 都只会留在日志里" \
    "重跑本脚本并在提示处填写运维邮箱（或预置环境变量 OPS_EMAIL=ops@example.com）"
fi

cat > terraform/terraform.tfvars <<EOF
project_id            = "${PROJECT_ID}"
region                = "${REGION}"
enable_psh            = $(to_bool "${ENABLE_PSH:-Y}")
enable_default_alerts = $(to_bool "${ENABLE_DEFAULT_ALERTS:-N}")
enable_scc            = $(to_bool "${ENABLE_SCC}")
enable_billing        = $(to_bool "${ENABLE_BILLING}")

scc_organization_id = "${ORG_ID}"
billing_account_id  = "${BILLING_ACCOUNT}"
billing_amount      = "${BUDGET_AMOUNT:-100}"

# 自监控告警（永久发送失败 / DLQ 积压）的邮件收件人；空字符串表示不创建
ops_email = "${OPS_EMAIL:-}"

# 通知渠道（feishu | wecom | dingtalk），单平台三选一
notify_channel = "${NOTIFY_CHANNEL}"
max_instances  = ${MAX_INSTANCES}

$(if [[ "${MAX_SENDS_PER_MINUTE_EXPLICIT}" == "true" ]]; then
    echo "max_sends_per_minute = ${MAX_SENDS_PER_MINUTE}"
  else
    echo "# max_sends_per_minute 未设置：由 Terraform 按渠道推导（飞书 40 / 企业微信 8 / 钉钉 8）"
  fi)

# 运行时行为（未显式提供时沿用线上值；kill_switch / pause_mode 未提供时复位为 false）
log_level    = "${LOG_LEVEL}"
min_severity = "${MIN_SEVERITY}"
kill_switch  = ${KILL_SWITCH}
pause_mode   = ${PAUSE_MODE}
$(if [[ -n "${SOURCE_MIN_SEVERITY:-}" ]]; then
    echo ""
    echo "source_min_severity = {"
    IFS=";" read -r -a pairs <<<"${SOURCE_MIN_SEVERITY}"
    for pair in "${pairs[@]:-}"; do
      echo "  ${pair%%=*} = \"${pair#*=}\""
    done
    echo "}"
  fi)

# 配置修订号：scripts/configure.sh 每次应用时更新，强制函数拉新 revision；空字符串 = 不注入
config_revision = "${CONFIG_REVISION}"

# 仅记录 Secret 名称，密文由 Secret Manager 保管，不进入 tfstate
# （三个渠道的名字都写上；Terraform 只引用 notify_channel 对应的那一套）
feishu_default_webhook_secret   = "${SECRET_WEBHOOK_NAME}"
feishu_default_sign_secret      = "${SECRET_SIGN_NAME}"
wecom_default_webhook_secret    = "${SECRET_WECOM_WEBHOOK_NAME}"
dingtalk_default_webhook_secret = "${SECRET_DINGTALK_WEBHOOK_NAME}"
dingtalk_default_sign_secret    = "${SECRET_DINGTALK_SIGN_NAME}"
EOF
if [[ -n "${HUB_SOURCE_PROJECTS:-}" ]]; then
  tf_proj_list="["
  IFS=';' read -ra items <<< "${HUB_SOURCE_PROJECTS}"
  for item in "${items[@]}"; do
    src_id="${item%%=*}"
    tf_proj_list+="\"${src_id}\", "
  done
  tf_proj_list="${tf_proj_list%, }]"
  if [[ "${tf_proj_list}" == "]" ]]; then tf_proj_list="[]"; fi
fi
# 汇聚配置单独成组（前置空行），组内按 terraform fmt 规则对齐等号，保证生成的 tfvars 通过 fmt -check
if [[ -n "${HUB_SOURCE_PROJECTS:-}" || -n "${HUB_SCOPE:-}" ]]; then
  hub_tf_keys=() hub_tf_vals=()
  if [[ -n "${HUB_SOURCE_PROJECTS:-}" ]]; then hub_tf_keys+=(source_projects); hub_tf_vals+=("${tf_proj_list}"); fi
  if [[ -n "${HUB_SCOPE:-}" ]]; then
    hub_tf_keys+=(source_scope); hub_tf_vals+=("\"${HUB_SCOPE}\"")
    if [[ -n "${HUB_SOURCE_PROJECTS:-}" ]]; then
      # 范围内的源项目不建项目级 sink（聚合 sink 覆盖）；范围外的保留，避免其日志静默断流
      hub_in_scope_list="[$(hub_projects_in_scope "${HUB_SOURCE_PROJECTS}" "${HUB_SCOPE}" | sed 's/.*/"&"/' | paste -sd, - | sed 's/,/, /g')]"
      hub_tf_keys+=(source_projects_in_scope); hub_tf_vals+=("${hub_in_scope_list}")
    fi
  fi
  hub_tf_w=0
  for k in "${hub_tf_keys[@]}"; do (( ${#k} > hub_tf_w )) && hub_tf_w=${#k}; done
  echo "" >> terraform/terraform.tfvars
  for i in "${!hub_tf_keys[@]}"; do
    printf '%-*s = %s\n' "${hub_tf_w}" "${hub_tf_keys[$i]}" "${hub_tf_vals[$i]}" >> terraform/terraform.tfvars
  done
fi


# 7. Terraform Init & Apply
pushd terraform >/dev/null
# -reconfigure 不可省略：切换 --project 会让 backend bucket 从
# <旧项目>-gcp-feishu-tfstate 变成 <新项目>-gcp-feishu-tfstate，
# 此时 terraform init 会因 "Backend configuration changed" 中断并要求人工选择。
# 这里的语义明确是"用新项目自己的 state"，绝不是把旧 state 迁过去（那会让
# terraform 认为新项目里已存在旧项目的资源，随后 plan 出一堆错误的 destroy）。
terraform init -reconfigure -upgrade
# TF_APPLY_CONFIRM=interactive：--yes 跳过其余提示，但 plan 之后仍要人工确认（configure.sh 交互模式用）
TF_APPLY_CONFIRM="${TF_APPLY_CONFIRM:-auto}"
[[ "${TF_APPLY_CONFIRM}" == "auto" || "${TF_APPLY_CONFIRM}" == "interactive" ]] || \
  die "TF_APPLY_CONFIRM=${TF_APPLY_CONFIRM} 无效：只能是 auto / interactive"
TF_APPLY_LOG="$(mktemp)"
tf_plan_and_apply() {  # 返回 terraform apply 的退出码；用户在 plan 后取消时返回 10
  if [[ "${ASSUME_YES}" == "true" && "${TF_APPLY_CONFIRM}" != "interactive" ]]; then
    terraform plan -out=tfplan || return $?
    terraform apply -auto-approve tfplan 2>&1 | tee "${TF_APPLY_LOG}"
    return "${PIPESTATUS[0]}"
  fi
  echo ""
  log_warn "注意：下面 plan 中与本次修改无关的漂移（控制台手工改动、其它人的变更等）也会一并应用，请逐项核对后再确认"
  terraform plan -out=tfplan || return $?
  # 不默认 -auto-approve：生产部署应能看到变更集
  read -rp "以上变更集是否应用？(yes/NO): " CONFIRM || CONFIRM=""
  [[ "${CONFIRM}" == "yes" ]] || return 10
  terraform apply tfplan 2>&1 | tee "${TF_APPLY_LOG}"
  return "${PIPESTATUS[0]}"
}
TF_RC=0; tf_plan_and_apply || TF_RC=$?
# 新建的文件夹 / 组织 sink 的写入身份（service-folder-*@gcp-sa-logging）创建后需传播，
# 同一次 apply 里紧接着授 logWriter 会 400 "does not exist" → 等待后自动再 plan / apply 一次（gcloud 路径用 soft_step_retry 对等处理）
if [[ "${TF_RC}" != "0" && "${TF_RC}" != "10" ]] && grep -q 'gcp-sa-logging.iam.gserviceaccount.com does not exist' "${TF_APPLY_LOG}"; then
  log_warn "新建 sink 的写入身份尚未传播完成，60 秒后自动重试一次（只会应用剩余的变更）"
  sleep 60
  TF_RC=0; tf_plan_and_apply || TF_RC=$?
fi
rm -f tfplan "${TF_APPLY_LOG}"
if [[ "${TF_RC}" == "10" ]]; then
  echo "操作已取消"
  # 由 configure.sh 驱动时用独立退出码区分「用户取消」与「失败」；直接交互运行保持原退出码 0
  [[ "${TF_APPLY_CONFIRM}" == "interactive" ]] && exit 3
  exit 0
fi
[[ "${TF_RC}" == "0" ]] || die "terraform apply 失败（退出码 ${TF_RC}），见上方错误"

# 8. 自检
TF_TOPIC_NAME=$(terraform output -raw topic_name)
popd >/dev/null
SELF_TEST_OK=true
run_self_test "${PROJECT_ID}" "${TF_TOPIC_NAME}" || SELF_TEST_OK=false

# 9. 结论（与 gcloud 路径一致：有跳过项就不打印"部署完成"）
echo ""
if report_skips && [[ "${SELF_TEST_OK}" == "true" ]]; then
  log_ok "Terraform 部署完成"
  EXIT_CODE=0
elif [[ "${SELF_TEST_OK}" != "true" ]]; then
  log_error "Terraform apply 已完成，但自检未通过 —— 见上方错误与 docs/troubleshooting.md"
  EXIT_CODE=1
else
  log_warn "Terraform 部署以【不完整】状态结束：核心链路已建立，上列步骤被跳过"
  EXIT_CODE=2
fi

echo "   State 位置: gs://${BUCKET_NAME}/terraform/state/default.tfstate"
echo "   更新配置: 修改 terraform/terraform.tfvars 后重新运行此脚本"
echo "   完全卸载: cd terraform && terraform destroy"
exit "${EXIT_CODE}"
