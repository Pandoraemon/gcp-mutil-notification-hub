#!/bin/bash
# 依赖更新自动化：升级 src/requirements.txt 中的锁定版本，并跑完整质量门禁。
#
# 为什么需要脚本而非手工改版本号：requirements.txt 里的每一行都是【已验证可部署】的
# 精确版本。手工升级容易漏跑 pip-audit 或漏跑测试，把一个有 CVE 或不兼容的版本
# 推上生产 —— 而 Cloud Functions 的构建失败要等到部署时才暴露。
set -euo pipefail

cd "$(dirname "$0")/.."
source lib/common.sh

CHECK_ONLY=false
VENV_DIR="${VENV_DIR:-.venv-deps}"

usage() {
  cat <<'USAGE'
用法: ./scripts/update-dependencies.sh [选项]
  --check     只检查（列出过期包 + pip-audit），不修改 requirements.txt
  --help, -h  显示此帮助

流程:
  1. 在临时虚拟环境中安装当前锁定版本；
  2. pip list --outdated 列出可升级项；
  3. 非 --check 模式下升级全部直接依赖并用 pip freeze 重新锁定；
  4. pip-audit 扫描已知漏洞（有高危项即失败）；
  5. 跑 pytest + ruff + pylint，全绿才认为升级可用。

注意: requirements.txt 必须保持【精确锁定 + 含传递依赖】，
      Cloud Functions 构建环境不做依赖解析仲裁，浮动版本会让两次部署产出不同镜像。
USAGE
}

for arg in "$@"; do
  case "${arg}" in
    --check)   CHECK_ONLY=true ;;
    --help|-h) usage; exit 0 ;;
    *)         echo "未知参数: ${arg}" >&2; usage; exit 1 ;;
  esac
done

require_commands python3

REQ_FILE="src/requirements.txt"
[[ -f "${REQ_FILE}" ]] || die "找不到 ${REQ_FILE}"

echo "==== 依赖更新 ===="
echo "锁定文件: ${REQ_FILE}"
echo ""

python3 -m venv "${VENV_DIR}"
PY="${VENV_DIR}/bin/python"
"${PY}" -m pip install --quiet --upgrade pip
"${PY}" -m pip install --quiet -r "${REQ_FILE}"
"${PY}" -m pip install --quiet pip-audit

echo "→ 当前可升级的包："
"${PY}" -m pip list --outdated --format=columns || true
echo ""

if [[ "${CHECK_ONLY}" == "true" ]]; then
  echo "→ 漏洞扫描（pip-audit）："
  "${PY}" -m pip_audit --strict || die "pip-audit 发现漏洞，请升级后重试"
  log_ok "检查完成（未修改任何文件）"
  exit 0
fi

echo "→ 升级直接依赖并重新锁定..."
# 只升级直接依赖，传递依赖由解析器决定后一并 freeze，
# 保证 requirements.txt 仍是完整的、可复现的锁定集合。
DIRECT_DEPS=(functions-framework cloudevents Jinja2 requests)
"${PY}" -m pip install --quiet --upgrade "${DIRECT_DEPS[@]}"

echo "→ 漏洞扫描（pip-audit）："
"${PY}" -m pip_audit --strict || die "pip-audit 发现漏洞，未写入 ${REQ_FILE}"

BACKUP="${REQ_FILE}.bak"
cp "${REQ_FILE}" "${BACKUP}"
# 剔除的是 pip-audit 自身及其传递依赖（不属于函数运行时）。
# 必须是 `^(name)==` 的【整名】精确匹配：原先的前缀匹配会把 tomli（命中 toml）、
# rich-*（命中 rich）、pipx（命中 pip）、booleanxyz（命中 boolean）这类真实依赖一并剔掉。
# 包名按 PEP 503 规范化比较（pip freeze 输出可能用 _ 或 - ）。名单范围与原先一致，只改匹配方式。
TOOLING_EXCLUDE_RE='^(pip|setuptools|wheel|pip[-_]audit|pip[-_]api|cyclonedx[-_]python[-_]lib|cyclonedx[-_]bom|packageurl[-_]python|boolean\.py|license[-_]expression|toml|cachecontrol|msgpack|markdown[-_]it[-_]py|mdurl|rich|pygments|platformdirs)=='
{
  echo "# Cloud Functions 运行时依赖 —— 精确锁定到已修补版本。"
  echo "# 由 scripts/update-dependencies.sh 生成于 $(date -u '+%Y-%m-%d')，请勿手工改版本号。"
  echo "# 升级流程：./scripts/update-dependencies.sh（含 pip-audit + 全量测试门禁）"
  "${PY}" -m pip freeze --exclude-editable | grep -viE "${TOOLING_EXCLUDE_RE}"
} > "${REQ_FILE}"

echo ""
echo "→ 变更："
diff -u "${BACKUP}" "${REQ_FILE}" || true
rm -f "${BACKUP}"

echo ""
echo "→ 质量门禁（pytest + ruff + pylint）..."
# 门禁必须在【刚升级的】${VENV_DIR} 里跑：升级与 freeze 发生在这里，
# 用项目里的旧 .venv 跑测试测的是旧版本，"全绿才认为升级可用"的前提就不成立。
GATE_PY="${PY}"
"${PY}" -m pip install --quiet pytest pytest-cov requests-mock ruff pylint
"${GATE_PY}" -m pytest --cov
"${GATE_PY}" -m ruff check .
"${GATE_PY}" -m pylint src

echo ""
log_ok "依赖已更新且门禁全绿。请提交 ${REQ_FILE} 并重新部署以生效。"
echo "   临时环境可删除: rm -rf ${VENV_DIR}"
