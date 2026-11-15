#!/usr/bin/env bash
#
# verify-lock.sh — 对比当前源码树与 versions.lock，发现漂移立即失败
#
# 用法：
#   scripts/verify-lock.sh --tree . --lock versions.lock
#   scripts/verify-lock.sh --tree . --lock versions.lock --config .config
#
# 退出码：0 一致 / 1 有漂移或缺失 / 2 用法错误
#
set -Eeuo pipefail

TREE=""
LOCK=""
CONFIG=""
STRICT_EXTRA=0

die() { printf '[verify-lock] ERROR: %s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --tree)   [ $# -ge 2 ] || die "--tree 需要参数";   TREE="$2"; shift 2 ;;
    --lock)   [ $# -ge 2 ] || die "--lock 需要参数";   LOCK="$2"; shift 2 ;;
    --config) [ $# -ge 2 ] || die "--config 需要参数"; CONFIG="$2"; shift 2 ;;
    --strict-extra) STRICT_EXTRA=1; shift ;;
    -h|--help) echo "用法: verify-lock.sh --tree <tree> --lock <lockfile> [--config <.config>] [--strict-extra]"; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

[ -d "$TREE" ] || die "tree 不存在: $TREE"
[ -f "$LOCK" ] || die "lock 不存在: $LOCK"
CONFIG="${CONFIG:-$TREE/.config}"

sha256_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}' | sed 's/^\\//'; }
git_head() { git -C "$1" rev-parse HEAD 2>/dev/null || true; }

OK=0; DRIFT=0; MISS=0; EXTRA=0
DRIFT_LINES=()
MISS_LINES=()

section=""
meta_config=""

printf '[verify-lock] lock=%s\n' "$LOCK"

# 当前树里所有第三方 .git 目录（相对路径），用于发现"新增未入锁"
CURRENT_TP="$(
  if [ -d "$TREE/package" ]; then
    find "$TREE/package" -maxdepth 3 -type d -name .git 2>/dev/null \
      | sed "s#^$TREE/##; s#/.git\$##" | grep -v '^package/feeds/' | sort || true
  fi
)"
LOCKED_TP=""

while IFS=$'\t' read -r f1 f2 f3 f4 || [ -n "${f1:-}" ]; do
  case "$f1" in
    ''|'#'*) continue ;;
  esac
  case "$f1" in
    '['*']')
      section="${f1#[}"; section="${section%]}"
      continue
      ;;
  esac

  case "$section" in
    meta)
      case "$f1" in
        config_sha256) meta_config="$f2" ;;
        openwrt_version) meta_version="$f2" ;;
      esac
      ;;
    source)
      now="$(git_head "$TREE")"
      if [ "$now" = "$f4" ]; then
        OK=$((OK+1)); printf '  OK      source                 %s\n' "${f4:0:12}"
      else
        DRIFT=$((DRIFT+1))
        DRIFT_LINES+=("source|${f4}|${now:-missing}")
      fi
      ;;
    feeds)
      dir="$TREE/feeds/$f1"
      if [ ! -d "$dir" ]; then
        MISS=$((MISS+1)); MISS_LINES+=("$f1|$f4")
      else
        now="$(git_head "$dir")"
        if [ "$now" = "$f4" ]; then
          OK=$((OK+1)); printf '  OK      feeds/%-16s %s\n' "$f1" "${f4:0:12}"
        else
          DRIFT=$((DRIFT+1))
          DRIFT_LINES+=("feeds/$f1|${f4}|${now:-missing}")
        fi
      fi
      ;;
    thirdparty)
      LOCKED_TP+="$f1"$'\n'
      dir="$TREE/$f1"
      if [ ! -d "$dir/.git" ]; then
        MISS=$((MISS+1)); MISS_LINES+=("$f1|$f4")
      else
        now="$(git_head "$dir")"
        if [ "$now" = "$f4" ]; then
          OK=$((OK+1)); printf '  OK      %-22s %s\n' "$f1" "${f4:0:12}"
        else
          DRIFT=$((DRIFT+1))
          DRIFT_LINES+=("$f1|${f4}|${now:-missing}")
        fi
      fi
      ;;
  esac
done < "$LOCK"

# 配置指纹
if [ -n "$meta_config" ] && [ "$meta_config" != "none" ] && [ -f "$CONFIG" ]; then
  now_cfg="$(sha256_of "$CONFIG")"
  if [ "$now_cfg" = "$meta_config" ]; then
    printf '  OK      .config                %s\n' "${now_cfg:0:12}"
  else
    DRIFT=$((DRIFT+1))
    DRIFT_LINES+=(".config|${meta_config:0:12}|${now_cfg:0:12}")
  fi
fi

# 新增但未入锁的第三方包
if [ -n "$CURRENT_TP" ]; then
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case $'\n'"$LOCKED_TP" in
      *$'\n'"$p"$'\n'*) ;;
      *) EXTRA=$((EXTRA+1)); printf '  WARN    新增未入锁: %s\n' "$p" ;;
    esac
  done <<< "$CURRENT_TP"
fi

printf '\n'
if [ "$DRIFT" -eq 0 ] && [ "$MISS" -eq 0 ] && { [ "$EXTRA" -eq 0 ] || [ "$STRICT_EXTRA" -eq 0 ]; }; then
  printf '[verify-lock] RESULT: PASS（%d 项一致，%d 项新增未入锁）\n' "$OK" "$EXTRA"
  exit 0
fi

if [ "${#DRIFT_LINES[@]}" -gt 0 ]; then
  printf '[FAIL] 提交漂移\n'
  for l in "${DRIFT_LINES[@]}"; do
    IFS='|' read -r item want now <<< "$l"
    printf '  - %-24s lock=%s  now=%s\n' "$item" "${want:0:12}" "${now:0:12}"
  done
fi
if [ "${#MISS_LINES[@]}" -gt 0 ]; then
  printf '[FAIL] 源码树缺少条目\n'
  for l in "${MISS_LINES[@]}"; do
    IFS='|' read -r item want <<< "$l"
    printf '  - %-24s lock=%s\n' "$item" "${want:0:12}"
  done
fi
if [ "$EXTRA" -gt 0 ] && [ "$STRICT_EXTRA" -eq 1 ]; then
  printf '[FAIL] 存在未入锁的第三方包（--strict-extra）\n'
fi

printf '\n[verify-lock] RESULT: FAIL（%d 漂移 / %d 缺失 / %d 未入锁）\n' "$DRIFT" "$MISS" "$EXTRA"
exit 1
