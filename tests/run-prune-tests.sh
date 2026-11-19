#!/usr/bin/env bash
#
# run-prune-tests.sh — prune-defaults.sh 的回归测试
# 用法：bash tests/run-prune-tests.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
SCRIPT="$KIT/scripts/prune-defaults.sh"

WORK="$(mktemp -d)"
PASS=0; FAIL=0; CODE=0; OUT=""

ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s%s\n' "$1" "${2:+（$2）}"; FAIL=$((FAIL+1)); }

expect_code() {
  if [ "$CODE" = "$2" ]; then ok "$1 (exit $CODE)"; else bad "$1" "want $2, got $CODE"; printf '%s\n' "$OUT" | sed 's/^/        /'; fi
}
expect_contains() {
  case "$OUT" in *"$2"*) ok "$1" ;; *) bad "$1" "未包含 $2" ;; esac
}
expect_pkg() { # <文件> <包名> <应在?>
  if grep -qE "^[[:space:]]*$2[[:space:]]*(\\\\|$)" "$1"; then
    [ "$3" = "1" ] && ok "$2 保留" || bad "$2 应被删除"
  else
    [ "$3" = "1" ] && bad "$2 应保留" || ok "$2 已删除"
  fi
}

make_mk() { # <目录> <最后一行的包名>
  mkdir -p "$1/include"
  cat > "$1/include/target.mk" <<EOF
DEFAULT_PACKAGES:=\\
	base-files \\
	libc \\
	dropbear

DEFAULT_PACKAGES.router:=\\
	dnsmasq-full \\
	luci-app-upnp \\
	luci-app-wol \\
	luci-app-wol-extra \\
	luci-app-ddns \\
	luci-app-autoreboot \\
	$2
EOF
}

run() { OUT="$(bash "$SCRIPT" "$@" 2>&1)"; CODE=$?; }

echo "== P1 默认名单：只删 wol 与 ddns =="
T="$WORK/good"; make_mk "$T" "ip-full"
BEFORE="$(wc -l < "$T/include/target.mk")"
run "$T"
expect_code "删除成功" 0
expect_contains "报告移除了 luci-app-wol" "移除默认包: luci-app-wol"
expect_contains "报告移除了 luci-app-ddns" "移除默认包: luci-app-ddns"
expect_pkg "$T/include/target.mk" "luci-app-wol" 0
expect_pkg "$T/include/target.mk" "luci-app-ddns" 0
expect_pkg "$T/include/target.mk" "luci-app-wol-extra" 1
expect_pkg "$T/include/target.mk" "luci-app-upnp" 1
expect_pkg "$T/include/target.mk" "luci-app-autoreboot" 1
expect_pkg "$T/include/target.mk" "ip-full" 1
if grep -q '^DEFAULT_PACKAGES.router' "$T/include/target.mk"; then ok "段头完好"; else bad "段头丢失"; fi
AFTER="$(wc -l < "$T/include/target.mk")"
if [ "$((BEFORE - AFTER))" = "2" ]; then ok "行数正好少 2"; else bad "行数变化异常" "$BEFORE -> $AFTER"; fi

echo "== P2 幂等：再跑一次不动文件 =="
SUM1="$(cksum < "$T/include/target.mk")"
run "$T"
expect_code "重复执行仍成功" 0
expect_contains "提示已是精简状态" "已是精简状态"
SUM2="$(cksum < "$T/include/target.mk")"
if [ "$SUM1" = "$SUM2" ]; then ok "文件内容未变"; else bad "文件被重复修改"; fi

echo "== P3 自定义名单：只删 upnp =="
T3="$WORK/custom"; make_mk "$T3" "ip-full"
OUT="$(PRUNE_PACKAGES="luci-app-upnp" bash "$SCRIPT" "$T3" 2>&1)"; CODE=$?
expect_code "自定义名单执行成功" 0
expect_pkg "$T3/include/target.mk" "luci-app-upnp" 0
expect_pkg "$T3/include/target.mk" "luci-app-wol" 1
expect_pkg "$T3/include/target.mk" "luci-app-ddns" 1

echo "== P4 目标是列表最后一项：拒绝并保持原样 =="
T4="$WORK/tail"; make_mk "$T4" "luci-app-wol"
SUM1="$(cksum < "$T4/include/target.mk")"
run "$T4"
expect_code "拒绝执行" 1
expect_contains "提示最后一项" "最后一项"
SUM2="$(cksum < "$T4/include/target.mk")"
if [ "$SUM1" = "$SUM2" ]; then ok "文件未被改动"; else bad "文件被改了"; fi

echo "== P5 源码树路径不对 =="
run "$WORK/no-such-tree"
expect_code "缺文件返回 1" 1
expect_contains "提示找不到" "找不到"

echo "== P6 文件里没有 DEFAULT_PACKAGES =="
T6="$WORK/noseg"; mkdir -p "$T6/include"
printf 'include $(TOPDIR)/rules.mk\n' > "$T6/include/target.mk"
run "$T6"
expect_code "结构变化返回 1" 1
expect_contains "提示上游结构可能变了" "上游结构可能变了"

echo "== P7 全新树里已无目标包：判为上游自愈并记录漂移 =="
# 模拟上游自己把 wol / ddns 从默认列表删掉了：没有执行标记（不是我们删的），
# 列表里也没有这两个包。以前这种情况只打「已是精简状态」，等于上游修好了
# 也没人知道；现在必须报出来。
T7="$WORK/upstream-fixed"; mkdir -p "$T7/include"
cat > "$T7/include/target.mk" <<'MK'
DEFAULT_PACKAGES:=\
	base-files \
	libc \
	dropbear

DEFAULT_PACKAGES.router:=\
	ip-full
MK
run "$T7"
expect_code "仍成功" 0
expect_contains "判为上游已自愈" "上游已自愈"
if grep -q 'prune:luci-app-wol' "$T7/.upstream-drift" 2>/dev/null; then ok "写入 wol 漂移记录"; else bad "未写 wol 漂移记录"; fi
if grep -q 'prune:luci-app-ddns' "$T7/.upstream-drift" 2>/dev/null; then ok "写入 ddns 漂移记录"; else bad "未写 ddns 漂移记录"; fi

echo
printf '结果: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
