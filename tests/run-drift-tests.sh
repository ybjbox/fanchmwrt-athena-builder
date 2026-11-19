#!/usr/bin/env bash
#
# run-drift-tests.sh — check-upstream-drift.sh 的回归测试
# 用法：bash tests/run-drift-tests.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
SCRIPT="$KIT/scripts/check-upstream-drift.sh"

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

echo
printf '结果: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
