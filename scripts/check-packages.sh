#!/usr/bin/env bash
#
# check-packages.sh — 校验构建产物是否满足 required / forbidden 清单
#
# 用法：
#   scripts/check-packages.sh --config .config                 # 编译前：查符号
#   scripts/check-packages.sh --manifest bin/targets/*/*/*.manifest   # 编译后：查实际装了什么
#   scripts/check-packages.sh --config .config --manifest ...  # 两者都查
#
# 退出码：
#   0  通过
#   1  有阻断项（required 缺失 / block 名单命中）
#   2  用法或环境错误
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIST_DIR="${PACKAGE_LIST_DIR:-$REPO_ROOT/configs}"
REQUIRED_FILE="${PACKAGE_REQUIRED_FILE:-$LIST_DIR/required-packages.txt}"
FORBIDDEN_FILE="${PACKAGE_FORBIDDEN_FILE:-$LIST_DIR/forbidden-packages.txt}"

CONFIG_FILE=""
MANIFEST_FILE=""
FEATURES_FILE=""
STRICT=0

if [ -t 1 ]; then
  RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; DIM=$'\033[2m'; RST=$'\033[0m'
else
  RED=""; YEL=""; GRN=""; DIM=""; RST=""
fi

usage() {
  cat <<'EOF'
用法: check-packages.sh [--config <path>] [--manifest <path>] [--features <path>] [--list-dir <dir>] [--strict]

  --config     OpenWrt .config，编译前校验 CONFIG_PACKAGE_* 符号
  --manifest   固件 .manifest，编译后校验真实安装的包
  --features   features.md；把「启用行」的包名自动并入 required 清单，
               与 configs/required-packages.txt 里的固定底座包合并去重。
               改开关只需改这一处，不必再手改第二份点名册。
  --list-dir   清单目录，默认 <repo>/configs
  --strict     把 warn 级命中升级为失败
EOF
}

die() { printf '%s[check-packages] ERROR:%s %s\n' "$RED" "$RST" "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --config)   [ $# -ge 2 ] || die "--config 需要参数";   CONFIG_FILE="$2";   shift 2 ;;
    --manifest) [ $# -ge 2 ] || die "--manifest 需要参数"; MANIFEST_FILE="$2"; shift 2 ;;
    --features) [ $# -ge 2 ] || die "--features 需要参数"; FEATURES_FILE="$2"; shift 2 ;;
    --list-dir) [ $# -ge 2 ] || die "--list-dir 需要参数"; LIST_DIR="$2"; shift 2
                REQUIRED_FILE="$LIST_DIR/required-packages.txt"
                FORBIDDEN_FILE="$LIST_DIR/forbidden-packages.txt" ;;
    --strict)   STRICT=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "未知参数: $1" ;;
  esac
done

[ -n "$CONFIG_FILE" ] || [ -n "$MANIFEST_FILE" ] || die "至少需要 --config 或 --manifest"
if [ -n "$CONFIG_FILE" ]; then [ -f "$CONFIG_FILE" ] || die "找不到 config: $CONFIG_FILE"; fi
if [ -n "$MANIFEST_FILE" ]; then [ -f "$MANIFEST_FILE" ] || die "找不到 manifest: $MANIFEST_FILE"; fi
[ -f "$REQUIRED_FILE" ] || die "找不到 required 清单: $REQUIRED_FILE（可用 --list-dir 指定）"
[ -f "$FORBIDDEN_FILE" ] || die "找不到 forbidden 清单: $FORBIDDEN_FILE"
if [ -n "$FEATURES_FILE" ]; then
  [ -f "$FEATURES_FILE" ] || die "找不到 features 文件: $FEATURES_FILE"
  [ -f "$SCRIPT_DIR/gen-config.sh" ] || die "缺少 gen-config.sh（--features 需要它派生点名册）"
fi

# ---------- 读取清单 ----------

trim() {
  local s="${1%%#*}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

REQUIRED=()
while IFS= read -r raw || [ -n "$raw" ]; do
  line="$(trim "$raw")"
  [ -n "$line" ] && REQUIRED+=("$line")
done < "$REQUIRED_FILE"
BASE_COUNT="${#REQUIRED[@]}"

# 由 features.md 的启用行自动派生其余包名，与固定底座包合并、去重、排序。
# 这样「关掉某开关」时点名册自动少几行，不会再出现「开关关了册子还写着」的假失败。
DERIVED_COUNT=0
if [ -n "$FEATURES_FILE" ]; then
  DERIVED="$(bash "$SCRIPT_DIR/gen-config.sh" --features "$FEATURES_FILE" --list-required)" \
    || die "由 features 派生点名册失败: $FEATURES_FILE"
  while IFS= read -r p; do
    [ -n "$p" ] && REQUIRED+=("$p")
  done <<< "$DERIVED"
  mapfile -t REQUIRED < <(printf '%s\n' "${REQUIRED[@]}" | awk 'NF && !seen[$0]++')
  DERIVED_COUNT=$(( ${#REQUIRED[@]} - BASE_COUNT ))
fi

BLOCK=()
WARN=()
section="block"
while IFS= read -r raw || [ -n "$raw" ]; do
  line="$(trim "$raw")"
  [ -z "$line" ] && continue
  case "$line" in
    "[block]") section="block"; continue ;;
    "[warn]")  section="warn";  continue ;;
  esac
  if [ "$section" = "block" ]; then BLOCK+=("$line"); else WARN+=("$line"); fi
done < "$FORBIDDEN_FILE"

# ---------- 匹配工具 ----------

# glob 风格匹配：name 命中任一 pattern 即成功
matches_any() {
  local name="$1"; shift
  local pat
  for pat in "$@"; do
    # shellcheck disable=SC2254  # 这里就是要 glob 展开
    case "$name" in $pat) return 0 ;; esac
  done
  return 1
}

# .config 中该包是否被选中（y 或 m），或出现在 DEVICE_PACKAGES 覆盖里
config_enabled() {
  local name="$1"
  grep -qxF "CONFIG_PACKAGE_${name}=y" "$CONFIG_FILE" && return 0
  grep -qxF "CONFIG_PACKAGE_${name}=m" "$CONFIG_FILE" && return 0
  if [ -n "${DEVICE_PKGS_TOKENS:-}" ]; then
    # shellcheck disable=SC2086
    case " $DEVICE_PKGS_TOKENS " in *" $name "*) return 0 ;; esac
  fi
  return 1
}

config_forbidden_hit() {
  local name="$1"
  grep -qxF "CONFIG_PACKAGE_${name}=y" "$CONFIG_FILE" && return 0
  grep -qxF "CONFIG_PACKAGE_${name}=m" "$CONFIG_FILE" && return 0
  return 1
}

manifest_has() {
  awk -v n="$1" '$1==n {found=1; exit} END{exit(found?0:1)}' "$MANIFEST_FILE"
}

# ---------- 检查 ----------

MISSING=()
BLOCKED=()
WARNED=()
REQ_OK=0

if [ -n "$CONFIG_FILE" ]; then
  DEVICE_PKGS_TOKENS="$(grep -E '^CONFIG_TARGET_DEVICE_PACKAGES_[^=]+="' "$CONFIG_FILE" 2>/dev/null \
    | sed -E 's/^[^"]*"//; s/"$//' | tr '\n' ' ' || true)"
  export DEVICE_PKGS_TOKENS

  for pkg in "${REQUIRED[@]+"${REQUIRED[@]}"}"; do
    if config_enabled "$pkg"; then
      REQ_OK=$((REQ_OK + 1))
    else
      MISSING+=("$pkg|config")
    fi
  done

  for pkg in "${BLOCK[@]+"${BLOCK[@]}"}"; do
    # block 名单里允许 glob，这里对 .config 做全量扫描
    while IFS= read -r sym; do
      [ -z "$sym" ] && continue
      if matches_any "$sym" "$pkg"; then BLOCKED+=("$sym|config"); fi
    done < <(grep -E '^CONFIG_PACKAGE_[^=]+=[ym]$' "$CONFIG_FILE" 2>/dev/null \
              | sed -E 's/^CONFIG_PACKAGE_([^=]+)=.*/\1/' || true)
  done

  for pkg in "${WARN[@]+"${WARN[@]}"}"; do
    while IFS= read -r sym; do
      [ -z "$sym" ] && continue
      if matches_any "$sym" "$pkg"; then WARNED+=("$sym|config"); fi
    done < <(grep -E '^CONFIG_PACKAGE_[^=]+=[ym]$' "$CONFIG_FILE" 2>/dev/null \
              | sed -E 's/^CONFIG_PACKAGE_([^=]+)=.*/\1/' || true)
  done
fi

MANIFEST_COUNT=0
if [ -n "$MANIFEST_FILE" ]; then
  MANIFEST_COUNT=$(awk 'NF>=1 && $1 !~ /^#/ {c++} END{print c+0}' "$MANIFEST_FILE")
  if [ "$MANIFEST_COUNT" -lt 40 ]; then
    die "manifest 只解析到 $MANIFEST_COUNT 个包，疑似文件不对（期望 100+）"
  fi

  for pkg in "${REQUIRED[@]+"${REQUIRED[@]}"}"; do
    manifest_has "$pkg" || MISSING+=("$pkg|manifest")
  done

  while IFS= read -r line; do
    name="${line%%[[:space:]]*}"
    [ -z "$name" ] && continue
    if matches_any "$name" "${BLOCK[@]+"${BLOCK[@]}"}"; then BLOCKED+=("$name|manifest"); fi
    if matches_any "$name" "${WARN[@]+"${WARN[@]}"}"; then WARNED+=("$name|manifest"); fi
  done < <(awk 'NF>=1 && $1 !~ /^#/ {print $1}' "$MANIFEST_FILE")
fi

# ---------- 去重 ----------
dedupe() {
  [ $# -eq 0 ] && return 0
  printf '%s\n' "$@" | sort -u
}

# ---------- 输出 ----------

printf '%s[check-packages]%s required=%d block=%d warn=%d\n' \
  "$DIM" "$RST" "${#REQUIRED[@]}" "${#BLOCK[@]}" "${#WARN[@]}"
printf '%s  required: 固定底座 %d 项 + 开关表自动派生 %d 项%s\n' "$DIM" "$BASE_COUNT" "$DERIVED_COUNT" "$RST"
[ -n "$FEATURES_FILE" ] && printf '%s  features: %s%s\n' "$DIM" "$FEATURES_FILE" "$RST"
[ -n "$CONFIG_FILE" ]   && printf '%s  config  : %s%s\n' "$DIM" "$CONFIG_FILE" "$RST"
[ -n "$MANIFEST_FILE" ] && printf '%s  manifest: %s (%d packages)%s\n' "$DIM" "$MANIFEST_FILE" "$MANIFEST_COUNT" "$RST"

FAILED=0

if [ "${#MISSING[@]}" -gt 0 ]; then
  FAILED=1
  printf '\n%s[FAIL] 缺少必需包%s\n' "$RED" "$RST"
  while IFS= read -r item; do
    printf '  - %s (%s)\n' "${item%%|*}" "${item##*|}"
  done < <(dedupe "${MISSING[@]}")
  printf '  %s→ config 层：检查 CONFIG_PACKAGE_*=y 是否被 defconfig 丢弃；manifest 层：查 feeds install 是否成功%s\n' "$DIM" "$RST"
fi

if [ "${#BLOCKED[@]}" -gt 0 ]; then
  FAILED=1
  printf '\n%s[FAIL] 命中禁用名单%s\n' "$RED" "$RST"
  while IFS= read -r item; do
    printf '  - %s (%s)\n' "${item%%|*}" "${item##*|}"
  done < <(dedupe "${BLOCKED[@]}")
  printf '  %s→ 这些包会破坏依赖树或让统计失真，必须从 .config / feeds 中移除%s\n' "$DIM" "$RST"
fi

if [ "${#WARNED[@]}" -gt 0 ]; then
  printf '\n%s[WARN] 命中风险名单%s\n' "$YEL" "$RST"
  while IFS= read -r item; do
    printf '  - %s (%s)\n' "${item%%|*}" "${item##*|}"
  done < <(dedupe "${WARNED[@]}")
  if [ "$STRICT" = "1" ]; then
    FAILED=1
    printf '  %s→ --strict 已开启，风险项按失败处理%s\n' "$DIM" "$RST"
  fi
fi

if [ "$FAILED" = "0" ]; then
  printf '\n%s[check-packages] RESULT: PASS%s（required %d 项全部满足）\n' "$GRN" "$RST" "${#REQUIRED[@]}"
  exit 0
fi

printf '\n%s[check-packages] RESULT: FAIL%s\n' "$RED" "$RST"
exit 1
