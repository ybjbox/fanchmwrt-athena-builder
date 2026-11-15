#!/usr/bin/env bash
#
# gen-config.sh — 由 features.conf 生成 .config 片段 / clone 清单 / feed 清单
#
# 用法：
#   scripts/gen-config.sh --features configs/features.conf --out openwrt/.config.fragment
#   scripts/gen-config.sh --features configs/features.conf --list-clones    # dest<TAB>url
#   scripts/gen-config.sh --features configs/features.conf --list-feeds     # name=url
#   scripts/gen-config.sh --features configs/features.conf --check          # 只校验并汇总
#
# 退出码：0 成功 / 2 用法或数据错误
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FEATURES="$SCRIPT_DIR/../configs/features.conf"
MODE="emit"
OUT=""

die() { printf '[gen-config] ERROR: %s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --features) [ $# -ge 2 ] || die "--features 需要参数"; FEATURES="$2"; shift 2 ;;
    --out)      [ $# -ge 2 ] || die "--out 需要参数";      OUT="$2";      shift 2 ;;
    --list-clones) MODE="clones"; shift ;;
    --list-feeds)  MODE="feeds";  shift ;;
    --check)       MODE="check";  shift ;;
    -h|--help) echo "用法: gen-config.sh [--features <tsv>] [--out <file>|--list-clones|--list-feeds|--check]"; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

[ -f "$FEATURES" ] || die "找不到 features 文件: $FEATURES"

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

declare -A SEEN=()
declare -A PKGS=()
declare -A FEED_URLS=()
declare -A FEED_NEEDED=()
DEV_EXTRA=""
CLONES=""
ENABLED=0
DISABLED=0

lineno=0
while IFS= read -r raw || [ -n "$raw" ]; do
  lineno=$((lineno + 1))
  raw="${raw#$'\xef\xbb\xbf'}"          # 容忍编辑器写入的 UTF-8 BOM
  line="$(trim "$raw")"
  case "$line" in ''|'#'*) continue ;; esac
  case "$raw" in
    *"|"*) ;;
    *) die "第 $lineno 行：缺少分隔符 |（本文件是竖线分隔，不是 Tab 分隔；若从 Excel 导出过请改回来）" ;;
  esac

  IFS='|' read -r name en dev pkgs repo note <<< "$raw"
  name="$(trim "${name:-}")"; en="$(trim "${en:-}")"
  dev="$(trim "${dev:-}")";   pkgs="$(trim "${pkgs:-}")"
  repo="$(trim "${repo:-}")"

  [ -n "$name" ] || die "第 $lineno 行：名称为空"
  [ -z "${SEEN[$name]:-}" ] || die "第 $lineno 行：功能名重复（$name）"
  SEEN["$name"]=1

  case "$en" in
    0) DISABLED=$((DISABLED + 1)); IS_ON=0 ;;
    1) ENABLED=$((ENABLED + 1));   IS_ON=1 ;;
    *) die "第 $lineno 行（$name）：启用列必须是 0 或 1，实际是 '$en'" ;;
  esac

  case "$dev" in
    0|1) ;;
    *) die "第 $lineno 行（$name）：设备附加包列必须是 0 或 1" ;;
  esac
  if [ "$IS_ON" = "1" ] && [ "$dev" = "1" ] && [ -z "$pkgs" ]; then
    die "第 $lineno 行（$name）：标记为设备附加包但包列表为空"
  fi

  if [ "$IS_ON" = "1" ]; then
    for p in $pkgs; do
      PKGS["$p"]=1
    done
    if [ "$dev" = "1" ]; then
      DEV_EXTRA="$DEV_EXTRA $pkgs"
    fi
  fi

  # 语法校验对启停行都做：关着的行写错了，等打开时才炸更难受
  for token in $repo; do
    case "$token" in
      git:*)
        url="${token#git:}"
        [ -n "$url" ] || die "第 $lineno 行（$name）：git: 后面没有 URL"
        if [ "$IS_ON" = "1" ]; then
          dest="$(basename "${url%.git}")"
          CLONES+="$dest"$'\t'"$url"$'\n'
        fi
        ;;
      feed:*=*)
        if [ "$IS_ON" = "1" ]; then
          spec="${token#feed:}"
          FEED_URLS["${spec%%=*}"]="${spec#*=}"
          FEED_NEEDED["${spec%%=*}"]=1
        fi
        ;;
      feed:*)
        if [ "$IS_ON" = "1" ]; then
          FEED_NEEDED["${token#feed:}"]=1
        fi
        ;;
      *)
        die "第 $lineno 行（$name）：无法识别的来源 '$token'（只支持 git: 与 feed:）"
        ;;
    esac
  done
done < "$FEATURES"

# feed 完整性：被引用但没人声明 URL
for f in "${!FEED_NEEDED[@]}"; do
  [ -n "${FEED_URLS[$f]:-}" ] || die "feed '$f' 被引用但未声明 URL（写成 feed:$f=<url>）"
done

case "$MODE" in
  clones)
    [ -n "$CLONES" ] && printf '%s' "$CLONES" | sort -u
    exit 0
    ;;
  feeds)
    for f in $(printf '%s\n' "${!FEED_URLS[@]}" | sort); do
      printf '%s=%s\n' "$f" "${FEED_URLS[$f]}"
    done
    exit 0
    ;;
  check)
    printf '[gen-config] 功能项：启用 %d，关闭 %d，包 %d 个，设备附加包 %d 个\n' \
      "$ENABLED" "$DISABLED" "${#PKGS[@]}" "$(echo $DEV_EXTRA | wc -w | tr -d ' ')"
    printf '  git 源：%s 个\n' "$(printf '%s' "$CLONES" | grep -c . || true)"
    printf '  feed  ：%s 个\n' "${#FEED_URLS[@]}"
    exit 0
    ;;
esac

# ---------- 生成 .config 片段 ----------
emit() {
  printf '# 由 gen-config.sh 从 features.conf 生成 — 不要手改\n'
  printf 'CONFIG_TARGET_qualcommax=y\n'
  printf 'CONFIG_TARGET_qualcommax_ipq60xx=y\n'
  printf 'CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02=y\n'
  if [ -n "$DEV_EXTRA" ]; then
    local dev_sorted
    dev_sorted="$(echo $DEV_EXTRA | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//')"
    printf 'CONFIG_TARGET_DEVICE_PACKAGES_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02="%s"\n' "$dev_sorted"
  fi
  printf 'CONFIG_LUCI_LANG_zh_Hans=y\n'

  printf '# ---- 包 ----\n'
  if [ "${#PKGS[@]}" -gt 0 ]; then
    for p in $(printf '%s\n' "${!PKGS[@]}" | sort); do
      printf 'CONFIG_PACKAGE_%s=y\n' "$p"
    done
  fi

  if [ -n "${PKGS[zram-swap]:-}" ]; then
    printf '# zram 内核选项（与 zram-swap 绑定）\n'
    printf 'CONFIG_KERNEL_ZRAM_BACKEND_LZ4=y\n'
    printf 'CONFIG_KERNEL_ZRAM_DEF_COMP_LZ4=y\n'
  fi

  printf '# ---- 明确不选（策略，非功能开关）----\n'
  printf '# CONFIG_PACKAGE_luci-app-oaf is not set\n'
  printf '# CONFIG_PACKAGE_luci-app-appfilter is not set\n'
  printf '# CONFIG_PACKAGE_luci-app-sqm is not set\n'
  printf '# CONFIG_PACKAGE_sqm-scripts-nss is not set\n'
  printf '# CONFIG_NSS_FIRMWARE_VERSION_12_5 is not set\n'
  printf '# CONFIG_TESTING_KERNEL is not set\n'
}

if [ -n "$OUT" ]; then
  mkdir -p "$(dirname "$OUT")"
  emit > "$OUT"
  printf '[gen-config] 写入 %s（%d 个包，%d 个设备附加包）\n' "$OUT" "${#PKGS[@]}" "$(echo $DEV_EXTRA | wc -w | tr -d ' ')"
else
  emit
fi
