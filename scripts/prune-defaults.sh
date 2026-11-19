#!/usr/bin/env bash
#
# prune-defaults.sh — 把不要的包从上游默认包列表里删掉
#
# 用法：
#   scripts/prune-defaults.sh openwrt
#   PRUNE_PACKAGES="luci-app-wol" scripts/prune-defaults.sh openwrt
#
# 为什么改源码，而不是在 .config 里写 =n：
#   这些包来自 include/target.mk 的 DEFAULT_PACKAGES.router，是 kconfig 里
#   "default y" 的源头。写 =n 只能压住一次，defconfig 换个顺序又会被拉回来；
#   直接从源头删除，依赖它的东西（etherwake、luci-i18n-*）也会跟着消失。
#
# 想恢复某个包：把它从 PRUNE 默认名单里去掉，并删掉
# configs/forbidden-packages.txt 里对应的拦截条目。
#
# 退出码：0 完成（含"本来就干净"）；1 环境不对或删除失败。
#
set -Eeuo pipefail

TREE="${1:-openwrt}"
MK="${TARGET_MK:-$TREE/include/target.mk}"
PRUNE="${PRUNE_PACKAGES:-luci-app-wol luci-app-ddns}"

die() { printf '[prune] ERROR: %s\n' "$*" >&2; exit 1; }

# 「补丁已无必要」的记录：由 scripts/check-upstream-drift.sh 汇总成构建摘要。
# CI 每次全新 clone，所以「列表里找不到某个包」只可能是上游自己删掉了。
DRIFT_FILE="${UPSTREAM_DRIFT_FILE:-$TREE/.upstream-drift}"
drift() { printf '%s\t%s\n' "$1" "$2" >> "$DRIFT_FILE"; }

[ -f "$MK" ] || die "找不到 $MK（源码树路径不对？）"
grep -q '^DEFAULT_PACKAGES' "$MK" || die "$MK 里没有 DEFAULT_PACKAGES，上游结构可能变了"

APPLIED_MARK="$TREE/.prune-defaults-applied"
REMOVED=0
for pkg in $PRUNE; do
  # 列表最后一项没有续行，删掉会让上一行的 "\" 悬空、Makefile 直接解析失败。
  # 这种情况不自动修，交给人工判断。
  if grep -qE "^[[:space:]]*${pkg}[[:space:]]*$" "$MK"; then
    die "$pkg 是默认列表的最后一项，自动删除会造成悬空续行，请人工确认"
  fi

  if grep -qE "^[[:space:]]*${pkg}[[:space:]]*\\\\$" "$MK"; then
    sed -i -E "/^[[:space:]]*${pkg}[[:space:]]*\\\\$/d" "$MK"
    echo "[prune] 移除默认包: $pkg"
    REMOVED=1
  elif [ -f "$APPLIED_MARK" ]; then
    # 本棵树先前已经删过，属于重复执行，不是上游自愈。
    echo "[prune] 已是精简状态（本补丁先前已执行过）: $pkg"
  else
    # 全新 clone 里已经没有这个包 = 上游自己删了。以前这里只打「已是精简状态」，
    # 跟「我之前删过」混为一谈，等于上游修好了也没人知道。
    echo "[prune] 列表中已无 $pkg（全新 clone 下说明上游已自愈）"
    drift "prune:$pkg" "上游 DEFAULT_PACKAGES 已不含 $pkg，本项精简逻辑可移除"
  fi
done
if [ "$REMOVED" = 1 ]; then printf 'applied\n' > "$APPLIED_MARK"; fi

# 收尾自检：删干净、且没把段头弄丢
for pkg in $PRUNE; do
  if grep -qE "^[[:space:]]*${pkg}([[:space:]]|$)" "$MK"; then
    die "$pkg 仍在 $MK 中，删除未生效"
  fi
done
for seg in DEFAULT_PACKAGES DEFAULT_PACKAGES.router; do
  grep -q "^${seg}" "$MK" || die "$MK 缺少 ${seg}，文件被改坏"
done

echo "[prune] 完成：默认包列表已不含 $(printf '%s' "$PRUNE" | tr ' ' '/')"
