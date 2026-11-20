#!/usr/bin/env bash
#
# patch-upgrade.sh — 给目标平台的升级脚本补上 platform_copy_config
#
# 用法：
#   scripts/patch-upgrade.sh openwrt
#   UPGRADE_PLATFORM_SH=/path/to/platform.sh scripts/patch-upgrade.sh
#
# 为什么需要这个补丁
# ------------------
# sysupgrade「保留配置」是三步：
#   1. /sbin/sysupgrade 把 /etc/config 等打成一个包（$UPGRADE_BACKUP，落在 /tmp）
#   2. 写完固件后，lib/upgrade/do_stage2 调 platform_copy_config 把这个包落地
#   3. 重启时 preinit 从 /sysupgrade.tgz 解包还原
#
# 第 2 步的调用带条件（见 lib/upgrade/do_stage2）：
#   if [ -n "$UPGRADE_BACKUP" ] && type 'platform_copy_config' >/dev/null 2>&1; then
#           platform_copy_config
#   fi
# 函数不存在就**静默跳过**：包被打出来放在 /tmp，然后随 reboot -f 一起蒸发。
# 网页上勾「保留配置」照常显示成功，重启后配置全无 —— 症状正如「没保留」。
#
# 现状
# ----
# FanchmWrt 的 target/linux/qualcommax/ipq60xx/base-files/lib/upgrade/platform.sh
# 缺这个函数；上游 openwrt 同名文件有，两份文件除这 12 行外完全一致。
# 所以这里按上游原文补，不自己发明实现。
#
# 落地的是 emmc.sh 里的 emmc_copy_config：它把包 dd 到 eMMC 的配置区
# （$EMMC_DATA_DEV，没有则接在 rootfs 之后）。jdcloud 各板走的正是
# emmc_do_upgrade，会 export 出这些 EMMC_* 变量，所以补上就能用。
#
# 生效顺序（重要）
# ----------------
# 执行 sysupgrade 的是**当前正在运行的固件**。所以：
#   旧固件 →（配置仍会丢）→ 带本补丁的固件 A →（配置保留）→ 固件 B
# 补丁只能让「以后」的升级生效，救不回刷 A 之前丢掉的配置。
#
# 退出码：0 完成（含「本来就有」）；1 环境不对或补完自检失败。
#
set -Eeuo pipefail

TREE="${1:-openwrt}"
PLATFORM="${UPGRADE_PLATFORM_SH:-$TREE/target/linux/qualcommax/ipq60xx/base-files/lib/upgrade/platform.sh}"
EMMC="${UPGRADE_EMMC_SH:-$TREE/package/base-files/files/lib/upgrade/emmc.sh}"

die() { printf '[upgrade] ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '[upgrade] %s\n' "$*"; }
warn() {
  printf '[upgrade] WARNING: %s\n' "$*" >&2
  if [ -n "${GITHUB_ACTIONS:-}" ]; then printf '::warning::%s\n' "$*" >&2; fi
}

# 「补丁已无必要」的记录：由 scripts/check-upstream-drift.sh 汇总成构建摘要。
DRIFT_FILE="${UPSTREAM_DRIFT_FILE:-$TREE/.upstream-drift}"
drift() { printf '%s\t%s\n' "$1" "$2" >> "$DRIFT_FILE"; }

[ -f "$PLATFORM" ] || die "找不到 $PLATFORM（源码树路径不对？）"

# 前提一：这个文件得是目标平台的升级脚本，否则补错地方
grep -q '^platform_do_upgrade()' "$PLATFORM" \
  || die "$PLATFORM 里没有 platform_do_upgrade，不像目标平台升级脚本，上游结构可能变了"

# 前提二：落地函数必须存在，否则补了也是空转
if [ -f "$EMMC" ]; then
  grep -q '^emmc_copy_config()' "$EMMC" \
    || die "$EMMC 里没有 emmc_copy_config，补 platform_copy_config 也只会空转"
else
  die "找不到 $EMMC（没有 emmc_copy_config，补了也没用）"
fi

# 上游漂移探测（2026-11-19 补的盲区）
# ----------------------------------
# CI 每次都是全新 clone，所以走到「文件里已经有这个函数」，唯一可能来源就是
# 上游自己补的 —— 也就是说这条分支处理的正是「上游已修复」。不能只打一行
# info 就退出，否则补丁会静默空转，你永远不知道该删。分三态：
#   1. 已实现且调用 emmc_copy_config → 等价，提示可删补丁
#   2. 已实现但实现不同          → 采用上游版本，提示人工复核
#   3. 文件里没有                → 走下面的追加逻辑
APPLIED_MARK="$TREE/.patch-upgrade-applied"
if grep -q '^platform_copy_config()' "$PLATFORM"; then
  # 有执行标记 = 同一棵树里被重复调用（本地跑两次、或脚本被调了两遍），
  # 不是上游自愈，不该报漂移。
  if [ -f "$APPLIED_MARK" ]; then
    info "已有 platform_copy_config（本补丁先前已执行过），跳过"
    exit 0
  fi
  if awk '/^platform_copy_config\(\)/,/^}/' "$PLATFORM" | grep -q 'emmc_copy_config'; then
    warn "上游已自行实现 platform_copy_config（且调用 emmc_copy_config），本补丁可移除"
    drift "platform_copy_config" "上游已实现等价逻辑，可删 patch-upgrade.sh 的调用"
  else
    warn "上游已有 platform_copy_config 但未调用 emmc_copy_config，实现与预期不同：已采用上游版本，请人工复核"
    drift "platform_copy_config" "上游实现与预期不同，已采上游版本，需人工复核"
  fi
  exit 0
fi

# 上游也可能把实现搬到通用层（如 package/base-files 的公共脚本）。那种情况下
# 这里再追加一份就变成「覆盖」而不是「补充」：两份定义都会被 source，实际生效
# 哪一份取决于加载顺序，属于最难查的一类问题。
#
# 查重范围必须精确到「会和本文件同时被 source」的地方：
#   - package/base-files：通用层，任何 target 都会加载 → 必须查
#   - 本 subtarget 自己的目录（从 $PLATFORM 反推）→ 必须查
# 同平台的兄弟 subtarget（qualcommax 下的 ipq807x / ipq-wifi 等）不会与本文件
# 同时加载，2026-11-20 因为把它们也算进来，周构建被误判拦下（见 U14）。
SUB_ROOT="$(printf '%s' "$PLATFORM" | sed 's#/base-files/lib/upgrade/platform\.sh$##')"
for d in "$TREE/package/base-files" "$SUB_ROOT"; do
  [ -d "$d" ] || continue
  hit="$(grep -rl '^platform_copy_config()' "$d" 2>/dev/null | grep -v "^$PLATFORM$" || true)"
  if [ -n "$hit" ]; then
    die "同一加载范围内已有 platform_copy_config 定义：$hit（追加会覆盖上游实现，请人工复核）"
  fi
done

# 文件末尾没有换行时，直接追加会把新内容粘到最后一行上
if [ -n "$(tail -c 1 "$PLATFORM" 2>/dev/null)" ]; then
  printf '\n' >> "$PLATFORM"
fi

# 与 openwrt/openwrt 的 platform.sh 逐字一致（缩进是 Tab）
cat >> "$PLATFORM" <<'PATCH'

platform_copy_config() {
	case "$(board_name)" in
	jdcloud,re-cs-02|\
	jdcloud,re-cs-07|\
	jdcloud,re-ss-01|\
	link,nn6000-v1|\
	link,nn6000-v2)
		emmc_copy_config
		;;
	esac
}
PATCH

# 自检一：语法。这文件是 /bin/sh 跑的，语法错了整台机器就没法升级
sh -n "$PLATFORM" 2>/dev/null || {
  # 语法坏了不能把这版源码留在树里，否则构建出的固件一升级就炸
  die "$PLATFORM 补完之后 sh -n 不通过，请人工检查"
}

# 自检二：函数真的补上了，且调用了正确的落地函数
grep -q '^platform_copy_config()' "$PLATFORM" \
  || die "追加后仍找不到 platform_copy_config 定义"
awk '/^platform_copy_config\(\)/,/^}/' "$PLATFORM" | grep -q 'emmc_copy_config' \
  || die "platform_copy_config 里没有调用 emmc_copy_config"

# 自检三：只补了一次（防止重复执行叠出两份定义）
[ "$(grep -c '^platform_copy_config()' "$PLATFORM")" = "1" ] \
  || die "platform_copy_config 出现多次，请人工检查"

printf 'applied\n' > "$APPLIED_MARK"
info "已补 platform_copy_config：$(basename "$(dirname "$PLATFORM")")/platform.sh"
info "生效顺序：本次编出的固件刷入后，下一次升级才会真正保留配置"
