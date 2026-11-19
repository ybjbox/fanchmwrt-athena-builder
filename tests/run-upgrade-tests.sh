#!/usr/bin/env bash
#
# run-upgrade-tests.sh — patch-upgrade.sh 的回归测试
# 用法：bash tests/run-upgrade-tests.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
SCRIPT="$KIT/scripts/patch-upgrade.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT
PASS=0; FAIL=0; CODE=0; OUT=""

ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s%s\n' "$1" "${2:+（$2）}"; FAIL=$((FAIL+1)); }

expect_code() {
  if [ "$CODE" = "$2" ]; then ok "$1 (exit $CODE)"; else bad "$1" "want $2, got $CODE"; printf '%s\n' "$OUT" | sed 's/^/        /'; fi
}
expect_contains() {
  case "$OUT" in *"$2"*) ok "$1" ;; *) bad "$1" "未包含「$2」" ;; esac
}

# 上游 openwrt 的 platform_copy_config 原文（Tab 缩进，逐字）
EXPECT='platform_copy_config() {
	case "$(board_name)" in
	jdcloud,re-cs-02|\
	jdcloud,re-cs-07|\
	jdcloud,re-ss-01|\
	link,nn6000-v1|\
	link,nn6000-v2)
		emmc_copy_config
		;;
	esac
}'

PLAT_REL="target/linux/qualcommax/ipq60xx/base-files/lib/upgrade/platform.sh"
EMMC_REL="package/base-files/files/lib/upgrade/emmc.sh"

# 造一棵最小源码树：platform.sh 有 platform_do_upgrade，emmc.sh 有 emmc_copy_config
make_tree() { # <目录> [不带末尾换行]
  local t="$1"
  mkdir -p "$t/$(dirname "$PLAT_REL")" "$t/$(dirname "$EMMC_REL")"
  cat > "$t/$PLAT_REL" <<'PLAT'
#!/bin/sh
. /lib/functions.sh
include /lib/upgrade

platform_check_image() {
	return 0
}

platform_do_upgrade() {
	case "$(board_name)" in
	jdcloud,re-cs-02)
		emmc_do_upgrade "$1"
		;;
	*)
		default_do_upgrade "$1"
		;;
	esac
}
PLAT
  cat > "$t/$EMMC_REL" <<'EMMC'
#!/bin/sh

emmc_copy_config() {
	if [ "$EMMC_DATA_DEV" ]; then
		dd if="$UPGRADE_BACKUP" of="$EMMC_DATA_DEV" bs=512
	fi
}

emmc_do_upgrade() {
	emmc_upgrade_tar $1
}
EMMC
  [ "${2:-}" = "nonl" ] && printf '%s' "$(cat "$t/$PLAT_REL")" > "$t/$PLAT_REL"
  return 0
}

run() { OUT="$(bash "$SCRIPT" "$@" 2>&1)"; CODE=$?; }

echo "== U1 正常补丁：函数补上且原有内容不动 =="
T="$WORK/good"; make_tree "$T"
cp "$T/$PLAT_REL" "$WORK/before.sh"
BEFORE_SIZE="$(wc -c < "$WORK/before.sh")"
BEFORE_SUM="$(cksum < "$WORK/before.sh")"
run "$T"
expect_code "补丁成功" 0
expect_contains "报告已补" "已补 platform_copy_config"
if grep -q '^platform_copy_config()' "$T/$PLAT_REL"; then ok "函数已存在"; else bad "函数缺失"; fi
if awk '/^platform_copy_config\(\)/,/^}/' "$T/$PLAT_REL" | grep -q 'emmc_copy_config'; then ok "调用了 emmc_copy_config"; else bad "未调用落地函数"; fi
# 原文件内容必须逐字保留在开头（只允许末尾追加）
if [ "$(head -c "$BEFORE_SIZE" "$T/$PLAT_REL" | cksum)" = "$BEFORE_SUM" ]; then
  ok "原有内容逐字未变"
else
  bad "原文件被改动"
fi

echo "== U2 与上游逐字一致 =="
awk '/^platform_copy_config\(\)/,/^}/' "$T/$PLAT_REL" > "$WORK/got.txt"
printf '%s\n' "$EXPECT" > "$WORK/want.txt"
if diff -u "$WORK/want.txt" "$WORK/got.txt" > "$WORK/d.txt" 2>&1; then
  ok "函数体与上游完全一致"
else
  bad "函数体与上游不一致"; sed 's/^/        /' "$WORK/d.txt" | head -20
fi
if awk '/^platform_copy_config\(\)/,/^}/' "$T/$PLAT_REL" | grep -q "^	"; then
  ok "缩进是 Tab"
else
  bad "缩进不是 Tab（Makefile/上游风格不符）"
fi
for b in jdcloud,re-cs-02 jdcloud,re-cs-07 jdcloud,re-ss-01 link,nn6000-v1 link,nn6000-v2; do
  if grep -q "$b" "$T/$PLAT_REL"; then ok "板型 $b 在名单里"; else bad "板型 $b 缺失"; fi
done

echo "== U3 语法：补完能被 /bin/sh 解析 =="
if sh -n "$T/$PLAT_REL" 2>/dev/null; then ok "sh -n 通过"; else bad "sh -n 失败"; fi

echo "== U4 幂等：再跑一次不动文件 =="
SUM1="$(cksum < "$T/$PLAT_REL")"
run "$T"
expect_code "重复执行成功" 0
expect_contains "提示跳过" "已有 platform_copy_config"
SUM2="$(cksum < "$T/$PLAT_REL")"
if [ "$SUM1" = "$SUM2" ]; then ok "文件内容未变"; else bad "文件被重复修改"; fi
if [ "$(grep -c '^platform_copy_config()' "$T/$PLAT_REL")" = "1" ]; then ok "只有一份定义"; else bad "出现多份定义"; fi

echo "== U5 文件末尾没有换行：追加后不粘连 =="
T5="$WORK/nonl"; make_tree "$T5" nonl
printf '\n' > /dev/null
run "$T5"
expect_code "补丁成功" 0
if sh -n "$T5/$PLAT_REL" 2>/dev/null; then ok "追加后语法仍合法（未粘到最后一行）"; else bad "追加粘连导致语法错误"; fi
if grep -q '^platform_copy_config()' "$T5/$PLAT_REL"; then ok "函数在新行开始"; else bad "函数没另起一行"; fi

echo "== U6 源码树路径不对 =="
run "$WORK/no-such-tree"
expect_code "缺文件返回 1" 1
expect_contains "提示找不到" "找不到"

echo "== U7 platform.sh 里没有 platform_do_upgrade =="
T7="$WORK/noplat"; make_tree "$T7"
printf '#!/bin/sh\ncheck_image() { return 0; }\n' > "$T7/$PLAT_REL"
SUM1="$(cksum < "$T7/$PLAT_REL")"
run "$T7"
expect_code "拒绝执行" 1
expect_contains "提示上游结构可能变了" "上游结构可能变了"
if [ "$(cksum < "$T7/$PLAT_REL")" = "$SUM1" ]; then ok "文件未被改动"; else bad "文件被改了"; fi

echo "== U8 emmc.sh 缺 emmc_copy_config =="
T8="$WORK/noemmc"; make_tree "$T8"
printf '#!/bin/sh\nemmc_do_upgrade() { :; }\n' > "$T8/$EMMC_REL"
SUM1="$(cksum < "$T8/$PLAT_REL")"
run "$T8"
expect_code "拒绝执行" 1
expect_contains "提示会空转" "空转"
if [ "$(cksum < "$T8/$PLAT_REL")" = "$SUM1" ]; then ok "文件未被改动"; else bad "文件被改了"; fi

echo "== U9 emmc.sh 整个不存在 =="
T9="$WORK/nofile"; make_tree "$T9"
SUM1="$(cksum < "$T9/$PLAT_REL")"
OUT="$(UPGRADE_EMMC_SH="$WORK/no-such-emmc.sh" bash "$SCRIPT" "$T9" 2>&1)"; CODE=$?
expect_code "缺 emmc.sh 返回 1" 1
expect_contains "提示找不到" "找不到"
if [ "$(cksum < "$T9/$PLAT_REL")" = "$SUM1" ]; then ok "文件未被改动"; else bad "文件被改了"; fi

echo "== U10 自定义路径（测试注入用）=="
T10="$WORK/custom"; make_tree "$T10"
ALT="$WORK/alt-platform.sh"; cp "$T10/$PLAT_REL" "$ALT"
OUT="$(UPGRADE_PLATFORM_SH="$ALT" bash "$SCRIPT" "$T10" 2>&1)"; CODE=$?
expect_code "按自定义路径执行" 0
if grep -q '^platform_copy_config()' "$ALT"; then ok "改的是指定文件"; else bad "指定文件未改"; fi
if ! grep -q '^platform_copy_config()' "$T10/$PLAT_REL"; then ok "默认路径未被顺带修改"; else bad "默认路径被误改"; fi

echo "== U11 树里已有函数：直接跳过 =="
T11="$WORK/already"; make_tree "$T11"
{ cat "$T11/$PLAT_REL"; printf '\n%s\n' "$EXPECT"; } > "$WORK/tmp11"
cp "$WORK/tmp11" "$T11/$PLAT_REL"
SUM1="$(cksum < "$T11/$PLAT_REL")"
run "$T11"
expect_code "跳过并成功" 0
# 没有执行标记 + 函数已存在 = 上游自己补的（CI 每次全新 clone）
expect_contains "识别为上游已修复" "上游已自行实现"
expect_contains "提示补丁可移除" "可移除"
if grep -q 'platform_copy_config' "$T11/.upstream-drift" 2>/dev/null; then ok "写入漂移记录"; else bad "未写漂移记录"; fi
if [ "$(cksum < "$T11/$PLAT_REL")" = "$SUM1" ]; then ok "没有重复追加"; else bad "又追加了一份"; fi

echo "== U12 树里已有但实现不同：采上游版本并告警 =="
T12="$WORK/diffimpl"; make_tree "$T12"
{ cat "$T12/$PLAT_REL"; printf '\nplatform_copy_config() {\n\tcp "$UPGRADE_BACKUP" /tmp/never\n}\n'; } > "$WORK/tmp12"
cp "$WORK/tmp12" "$T12/$PLAT_REL"
SUM1="$(cksum < "$T12/$PLAT_REL")"
run "$T12"
expect_code "仍成功（不中断构建）" 0
expect_contains "识别为上游实现不同" "实现与预期不同"
expect_contains "要求人工复核" "人工复核"
if grep -q 'platform_copy_config' "$T12/.upstream-drift" 2>/dev/null; then ok "写入漂移记录"; else bad "未写漂移记录"; fi
if [ "$(cksum < "$T12/$PLAT_REL")" = "$SUM1" ]; then ok "未覆盖上游实现"; else bad "改动了上游文件"; fi

echo "== U13 树里别处已有定义：拒绝追加（防覆盖上游） =="
T13="$WORK/elsewhere"; make_tree "$T13"
mkdir -p "$T13/package/base-files/files/lib/upgrade"
printf '#!/bin/sh\nplatform_copy_config() {\n\temmc_copy_config\n}\n' \
  > "$T13/package/base-files/files/lib/upgrade/common-copy.sh"
run "$T13"
expect_code "拒绝执行" 1
expect_contains "提示会覆盖上游实现" "覆盖上游实现"
if grep -q '^platform_copy_config()' "$T13/$PLAT_REL"; then bad "仍然追加了重复定义"; else ok "未追加重复定义"; fi

echo
printf '结果: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
