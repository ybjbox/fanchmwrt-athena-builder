#!/usr/bin/env bash
#
# patch-luci-title.sh — 让浏览器标签标题跟随主机名
#
# 用法：
#   scripts/patch-luci-title.sh openwrt
#
# 为什么需要
# ----------
# 主题把 <title>FanchmWrt</title> 写死在 header.ut 里，首启改 hostname 不会让
# 标签跟着变。改成读 boardinfo.hostname（首启设为 Athena），以后在网页里改
# 主机名，标签也同步。
#
# 必须在编译前改：CONFIG_LUCI_UTMIN=y 时 *.ut 会被 ucode -c 预编译成字节码，
# 装到设备上再 sed 会把模板的长度字段改坏，LuCI 直接白屏。
#
# 三态判定（2026-11-19）
# --------------------
#   模板里还是写死值        → 替换（正常路径）
#   模板已改成 hostname 写法 → 上游自愈，记录漂移，提示可移除本调用
#   两者都不是              → 上游换了写法，sed 会静默失效，告警并要求人工复核
# 第三种以前是静默无变化的，标签就这么一直不跟着改，最难发现。
#
# 退出码：0 完成（含「文件不存在」）；1 替换后自检失败。
#
set -Eeuo pipefail

TREE="${1:-openwrt}"
HEADER="$TREE/package/fcm/luci-theme-fanchmwrt/ucode/template/themes/fanchmwrt/header.ut"
DRIFT_FILE="${UPSTREAM_DRIFT_FILE:-$TREE/.upstream-drift}"
APPLIED_MARK="$TREE/.patch-luci-title-applied"

die() { printf '[title] ERROR: %s\n' "$*" >&2; exit 1; }
drift() { printf '%s\t%s\n' "$1" "$2" >> "$DRIFT_FILE"; }

if [ ! -f "$HEADER" ]; then
  # 主题包没装/没选中时属正常情况，不算漂移
  echo "[title] 找不到 $HEADER，跳过"
  exit 0
fi

if grep -q '<title>FanchmWrt</title>' "$HEADER"; then
  sed -i "s|<title>FanchmWrt</title>|<title>{{ striptags(boardinfo.hostname ?? 'Athena') }}</title>|" "$HEADER"
  grep -q "striptags(boardinfo.hostname" "$HEADER" \
    || die "替换后仍找不到 hostname 标题，$HEADER 可能被改坏"
  printf 'applied\n' > "$APPLIED_MARK"
  echo "[title] 标签标题已改为跟随 hostname"
elif grep -q "striptags(boardinfo.hostname" "$HEADER"; then
  # 有执行标记 = 同一棵树重复调用，不是上游自愈
  if [ -f "$APPLIED_MARK" ]; then
    echo "[title] 已是跟随 hostname（本补丁先前已执行过），跳过"
  else
    echo "[title] 上游模板已自带 hostname 标题"
    drift "luci-title" "主题模板已自带 hostname 标题，patch-luci-title.sh 的调用可移除"
  fi
else
  echo "[title] WARNING: 模板里找不到 <title>FanchmWrt</title>，标题不会被改，请人工复核" >&2
  drift "luci-title" "模板中找不到 FanchmWrt 标题，替换已失效，需人工复核"
fi
