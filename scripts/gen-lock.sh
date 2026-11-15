#!/usr/bin/env bash
#
# gen-lock.sh — 生成 versions.lock（源码、feed、第三方包、配置的统一指纹）
#
# 用法：
#   scripts/gen-lock.sh --tree . --out versions.lock
#   scripts/gen-lock.sh --tree . --out versions.lock --config .config
#
# 说明：需在 feeds update / feeds install 与第三方包 clone 之后运行，
#       这样 feeds/<name> 与 package/<pkg> 的 .git 才存在。
#
set -Eeuo pipefail

TREE=""
OUT=""
CONFIG=""

die() { printf '[gen-lock] ERROR: %s\n' "$*" >&2; exit 2; }
usage() { echo "用法: gen-lock.sh --tree <build-tree> --out <lockfile> [--config <.config>]"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --tree)   [ $# -ge 2 ] || die "--tree 需要参数";   TREE="$2"; shift 2 ;;
    --out)    [ $# -ge 2 ] || die "--out 需要参数";    OUT="$2";  shift 2 ;;
    --config) [ $# -ge 2 ] || die "--config 需要参数"; CONFIG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

[ -n "$TREE" ] || die "缺少 --tree"
[ -n "$OUT" ]  || die "缺少 --out"
[ -d "$TREE" ] || die "tree 不存在: $TREE"
[ -d "$TREE/.git" ] || die "tree 不是 git 仓库: $TREE"
CONFIG="${CONFIG:-$TREE/.config}"

sha256_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}' | sed 's/^\\//'; }
git_val() { git -C "$1" "${@:2}" 2>/dev/null || true; }

MAIN_URL="$(git_val "$TREE" config --get remote.origin.url)"
MAIN_REF="$(git_val "$TREE" rev-parse --abbrev-ref HEAD)"
MAIN_COMMIT="$(git_val "$TREE" rev-parse HEAD)"
[ -n "$MAIN_COMMIT" ] || die "无法读取主仓 commit"

OPENWRT_VERSION="$(cat "$TREE/version" 2>/dev/null || echo unknown)"
CONFIG_SHA=""
[ -f "$CONFIG" ] && CONFIG_SHA="$(sha256_of "$CONFIG")"
FEEDS_CONF_SHA="$(sha256_of "$TREE/feeds.conf.default")"

cfg_get() { sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$CONFIG" 2>/dev/null | head -1; }
BOARD="$(cfg_get CONFIG_TARGET_BOARD)"
SUBTARGET="$(cfg_get CONFIG_TARGET_SUBTARGET)"
PROFILE="$(cfg_get CONFIG_TARGET_PROFILE)"

FEED_ENTRIES=()
if [ -f "$TREE/feeds.conf.default" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      src-git\ *) ;;
      *) continue ;;
    esac
    read -r _kw name rest <<< "$line"
    [ -n "${name:-}" ] || continue
    url="$rest"; ref="-"; pin=""
    case "$rest" in
      *";"*) url="${rest%%;*}"; ref="${rest#*;}" ;;
    esac
    case "$ref" in
      *"^"*) pin="${ref#*^}"; ref="${ref%%^*}" ;;
    esac
    actual=""
    if [ -d "$TREE/feeds/$name/.git" ]; then
      actual="$(git_val "$TREE/feeds/$name" rev-parse HEAD)"
    fi
    [ -n "$actual" ] || actual="${pin:-missing}"
    FEED_ENTRIES+=("$(printf '%s\t%s\t%s\t%s' "$name" "$url" "${ref:--}" "$actual")")
  done < "$TREE/feeds.conf.default"
fi

TP_ENTRIES=()
if [ -d "$TREE/package" ]; then
  while IFS= read -r gitdir; do
    [ -n "$gitdir" ] || continue
    dir="$(dirname "$gitdir")"
    rel="${dir#"$TREE"/}"
    case "$rel" in package/feeds/*) continue ;; esac
    url="$(git_val "$dir" config --get remote.origin.url)"
    commit="$(git_val "$dir" rev-parse HEAD)"
    [ -n "$commit" ] || continue
    TP_ENTRIES+=("$(printf '%s\t%s\t-\t%s' "$rel" "${url:-unknown}" "$commit")")
  done < <(find "$TREE/package" -maxdepth 3 -type d -name .git 2>/dev/null | sort)
fi

{
  printf '# versions.lock — 由 gen-lock.sh 生成，请勿手改\n'
  printf '# 格式：item<TAB>url<TAB>ref<TAB>commit（section 头为 [name]）\n'
  printf '[meta]\n'
  printf 'generated_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'openwrt_version\t%s\n' "$OPENWRT_VERSION"
  printf 'target\t%s/%s\n' "${BOARD:-unknown}" "${SUBTARGET:-unknown}"
  printf 'profile\t%s\n' "${PROFILE:-unknown}"
  printf 'config_sha256\t%s\n' "${CONFIG_SHA:-none}"
  printf 'feeds_conf_sha256\t%s\n' "${FEEDS_CONF_SHA:-none}"
  printf '[source]\n'
  printf 'source\t%s\t%s\t%s\n' "${MAIN_URL:-unknown}" "${MAIN_REF:-detached}" "$MAIN_COMMIT"
  printf '[feeds]\n'
  if [ "${#FEED_ENTRIES[@]}" -gt 0 ]; then
    printf '%s\n' "${FEED_ENTRIES[@]}" | sort -k1,1
  fi
  printf '[thirdparty]\n'
  if [ "${#TP_ENTRIES[@]}" -gt 0 ]; then
    printf '%s\n' "${TP_ENTRIES[@]}" | sort -k1,1
  fi
} > "$OUT"

printf '[gen-lock] 写入 %s\n' "$OUT"
printf '  source    : %s @ %s\n' "${MAIN_REF:-detached}" "${MAIN_COMMIT:0:12}"
printf '  feeds     : %s 个\n' "${#FEED_ENTRIES[@]}"
printf '  thirdparty: %s 个\n' "${#TP_ENTRIES[@]}"
printf '  config    : %s\n' "${CONFIG_SHA:-none}"
