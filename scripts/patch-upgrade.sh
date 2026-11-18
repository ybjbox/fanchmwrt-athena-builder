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

# 幂等：已经有就跳过。注意只认函数定义行，不认注释里的提及。
if grep -q '^platform_copy_config()' "$PLATFORM"; then
  info "已有 platform_copy_config，跳过"
  exit 0
fi

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

info "已补 platform_copy_config：$(basename "$(dirname "$PLATFORM")")/platform.sh"
info "生效顺序：本次编出的固件刷入后，下一次升级才会真正保留配置"
