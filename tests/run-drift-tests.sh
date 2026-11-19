#!/usr/bin/env bash
#
# run-drift-tests.sh — check-upstream-drift.sh 的回归测试
# 用法：bash tests/run-drift-tests.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
SCRIPT="$KIT/scripts/check-upstream-drift.sh"
TITLE="$KIT/scripts/patch-luci-title.sh"
HDR_REL="package/fcm/luci-theme-fanchmwrt/ucode/template/themes/fanchmwrt/header.ut"

WORK="$(mktemp -d)"
PASS=0; FAIL=0; CODE=0; OUT=""

ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s%s\n' "$1" "${2:+（$2）}"; FAIL=$((FAIL+1)); }
expect_code() {
  if [ "$CODE" = "$2" ]; then ok "$1 (exit $CODE)"; else bad "$1" "want $2, got $CODE"; printf '%s\n' "$OUT" | sed 's/^/        /'; fi
}
expect_contains() {
  case "$OUT" in *"$2"*) ok "$1" ;; *) bad "$1" "未包含「$2」" ;; esac
}

echo "== D1 没有漂移文件：报「无漂移」并成功 =="
OUT="$(bash "$SCRIPT" "$WORK/none" 2>&1)"; CODE=$?
expect_code "无漂移退出 0" 0
expect_contains "明确说未发现漂移" "未发现上游漂移"

echo "== D2 空目录也算无漂移（不是每个树都会写这个文件） =="
mkdir -p "$WORK/empty"
OUT="$(bash "$SCRIPT" "$WORK/empty" 2>&1)"; CODE=$?
expect_code "空目录退出 0" 0

echo "== D3 有漂移：逐条列出，默认仍退出 0（不拦构建） =="
mkdir -p "$WORK/one"
printf 'platform_copy_config\t上游已实现等价逻辑，可删 patch-upgrade.sh 的调用\n' > "$WORK/one/.upstream-drift"
printf 'prune:luci-app-wol\t上游 DEFAULT_PACKAGES 已不含 luci-app-wol\n' >> "$WORK/one/.upstream-drift"
OUT="$(bash "$SCRIPT" "$WORK/one" 2>&1)"; CODE=$?
expect_code "默认非阻塞" 0
expect_contains "报出数量" "发现 2 处上游漂移"
expect_contains "列出补丁名" "platform_copy_config"
expect_contains "列出说明" "上游已实现等价逻辑"
expect_contains "第二项也在" "prune:luci-app-wol"

echo "== D4 --strict：有漂移就退出 1（定时任务用） =="
OUT="$(bash "$SCRIPT" "$WORK/one" --strict 2>&1)"; CODE=$?
expect_code "strict 下有漂移退出 1" 1

echo "== D5 --strict：无漂移不误报 =="
OUT="$(bash "$SCRIPT" "$WORK/empty" --strict 2>&1)"; CODE=$?
expect_code "strict 下无漂移退出 0" 0

echo "== D6 --github-summary：写进构建摘要 =="
export GITHUB_STEP_SUMMARY="$WORK/summary.md"
: > "$GITHUB_STEP_SUMMARY"
OUT="$(bash "$SCRIPT" "$WORK/one" --github-summary 2>&1)"; CODE=$?
expect_code "带摘要仍退出 0" 0
if grep -q '上游漂移检查' "$GITHUB_STEP_SUMMARY" 2>/dev/null; then ok "摘要含标题"; else bad "摘要缺标题"; fi
if grep -q 'platform_copy_config' "$GITHUB_STEP_SUMMARY" 2>/dev/null; then ok "摘要含补丁名"; else bad "摘要缺补丁名"; fi
unset GITHUB_STEP_SUMMARY

echo "== D7 无漂移时的摘要也要留痕（证明检查跑过） =="
export GITHUB_STEP_SUMMARY="$WORK/summary2.md"
: > "$GITHUB_STEP_SUMMARY"
OUT="$(bash "$SCRIPT" "$WORK/empty" --github-summary 2>&1)"; CODE=$?
if grep -q '所有补丁仍然必要' "$GITHUB_STEP_SUMMARY" 2>/dev/null; then ok "摘要说明补丁仍必要"; else bad "摘要没留痕"; fi
unset GITHUB_STEP_SUMMARY

echo "== T1 模板仍是写死标题：替换并写执行标记 =="
make_hdr() { # <目录> <标题行内容>
  mkdir -p "$1/$(dirname "$HDR_REL")"
  printf '<html><head>\n\t\t%s\n</head></html>\n' "$2" > "$1/$HDR_REL"
}
make_hdr "$WORK/t1" '<title>FanchmWrt</title>'
OUT="$(bash "$TITLE" "$WORK/t1" 2>&1)"; CODE=$?
expect_code "替换成功" 0
if grep -q "striptags(boardinfo.hostname" "$WORK/t1/$HDR_REL"; then ok "标题已改为跟随 hostname"; else bad "标题未改"; fi
if [ -f "$WORK/t1/.patch-luci-title-applied" ]; then ok "写了执行标记"; else bad "缺执行标记"; fi
if [ -f "$WORK/t1/.upstream-drift" ]; then bad "不该记录漂移"; else ok "未误报漂移"; fi

echo "== T2 同一棵树重复执行：不误报为上游自愈 =="
OUT="$(bash "$TITLE" "$WORK/t1" 2>&1)"; CODE=$?
expect_code "重复执行成功" 0
expect_contains "识别为本补丁已执行过" "先前已执行过"
if [ -f "$WORK/t1/.upstream-drift" ]; then bad "重复执行误报漂移"; else ok "仍未误报漂移"; fi

echo "== T3 上游模板已自带 hostname：记录漂移 =="
make_hdr "$WORK/t3" "<title>{{ striptags(boardinfo.hostname ?? 'X') }}</title>"
OUT="$(bash "$TITLE" "$WORK/t3" 2>&1)"; CODE=$?
expect_code "成功" 0
expect_contains "识别为上游已改" "上游模板已自带"
if grep -q 'luci-title' "$WORK/t3/.upstream-drift" 2>/dev/null; then ok "记录漂移"; else bad "未记录漂移"; fi

echo "== T4 上游换了写法：告警且记录（以前是静默无变化） =="
make_hdr "$WORK/t4" '<title>Fanchm</title>'
OUT="$(bash "$TITLE" "$WORK/t4" 2>&1)"; CODE=$?
expect_code "不中断" 0
expect_contains "明确告警" "WARNING"
expect_contains "提示人工复核" "人工复核"
if grep -q 'luci-title' "$WORK/t4/.upstream-drift" 2>/dev/null; then ok "记录漂移"; else bad "未记录漂移"; fi

echo "== T5 主题模板不存在：跳过且不报错 =="
mkdir -p "$WORK/t5"
OUT="$(bash "$TITLE" "$WORK/t5" 2>&1)"; CODE=$?
expect_code "跳过但不失败" 0
expect_contains "说明跳过" "跳过"
if [ -f "$WORK/t5/.upstream-drift" ]; then bad "缺失文件不该记漂移"; else ok "未记漂移"; fi

echo
printf '结果: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
