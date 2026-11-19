#!/usr/bin/env bash
#
# check-upstream-drift.sh — 汇总「补丁已无必要」的报告
#
# 用法：
#   scripts/check-upstream-drift.sh openwrt
#   scripts/check-upstream-drift.sh openwrt --github-summary   # 写进 GitHub 构建摘要
#   scripts/check-upstream-drift.sh openwrt --strict           # 有漂移就退出 1（定时任务用）
#
# 为什么单独做一个脚本
# ------------------
# 我们对上游源码打的每一个补丁（platform_copy_config、默认包精简、主题标题）
# 都可能在将来被上游自己修好。修好之后补丁仍会「执行成功」，只是什么也没做，
# 于是你会一直带着一段无效代码，且误以为它在保护你。
#
# 各补丁脚本在发现「上游已自愈」时，往 <源码树>/.upstream-drift 追加一行
# 「补丁名<TAB>说明」。本脚本只做汇总与呈现，不重复判定逻辑。
#
# 构建里用非阻塞方式跑（continue-on-error），只提醒不拦构建 —— 上游修复是好事。
# 定时任务里加 --strict，让「上游修好了」主动找你。
#
# 退出码：0 无漂移或仅报告；1 有漂移且指定了 --strict。
#
set -Eeuo pipefail

TREE="${1:-openwrt}"
[ $# -gt 0 ] && shift

SUMMARY=0
STRICT=0
for a in "$@"; do
  case "$a" in
    --github-summary) SUMMARY=1 ;;
    --strict)         STRICT=1 ;;
    -h|--help)        sed -n '2,25p' "$0"; exit 0 ;;
    *) printf '[drift] 忽略未知参数：%s\n' "$a" >&2 ;;
  esac
done

FILE="$TREE/.upstream-drift"

if [ ! -s "$FILE" ]; then
  echo "[drift] 未发现上游漂移：所有补丁仍然必要"
  if [ "$SUMMARY" = 1 ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "## 上游漂移检查"
      echo
      echo "未发现漂移，所有补丁仍然必要。"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 0
fi

N="$(grep -c . "$FILE" 2>/dev/null || echo 0)"
echo "[drift] 发现 $N 处上游漂移（补丁已无必要，复核后可删除）："
while IFS="$(printf '\t')" read -r name desc; do
  [ -n "${name:-}" ] || continue
  printf '  - %s：%s\n' "$name" "$desc"
done < "$FILE"

if [ -n "${GITHUB_ACTIONS:-}" ]; then
  printf '::warning::上游漂移 %s 处，补丁已无必要，详见构建摘要\n' "$N"
fi

if [ "$SUMMARY" = 1 ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## 上游漂移检查"
    echo
    echo "发现 **$N** 处漂移：下列补丁的作用已被上游自己实现，复核后可删除对应调用。"
    echo
    echo "| 补丁 | 说明 |"
    echo "|---|---|"
    while IFS="$(printf '\t')" read -r name desc; do
      [ -n "${name:-}" ] || continue
      printf '| `%s` | %s |\n' "$name" "$desc"
    done < "$FILE"
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$STRICT" = 1 ]; then
  echo "[drift] --strict：有漂移，退出 1" >&2
  exit 1
fi
exit 0
