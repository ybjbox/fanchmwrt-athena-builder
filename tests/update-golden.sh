#!/usr/bin/env bash
#
# update-golden.sh — 重新生成 tests/golden/config.txt
#
# 什么时候用：你有意改了 configs/features.md（增删功能、改包名），
# run-config-tests.sh 报「配置片段与基线不一致」时，先确认 diff 里的每一行
# 都是你想改的，再跑本脚本把基线更新过来。
#
# 用法：
#   bash tests/update-golden.sh
#   bash tests/update-golden.sh --check     # 只比对不写，返回 1 表示有差异
#
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
GEN="$KIT/scripts/gen-config.sh"
FEATURES="${FEATURES_FILE:-$KIT/configs/features.md}"
GOLDEN="$HERE/golden/config.txt"
NEW="$(mktemp)"

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

mkdir -p "$HERE/golden"
bash "$GEN" --features "$FEATURES" > "$NEW"

if [ -f "$GOLDEN" ] && cmp -s "$GOLDEN" "$NEW"; then
  echo "[golden] 与基线一致，无需更新（$(grep -c . "$NEW") 行）"
  exit 0
fi

if [ "$CHECK" = 1 ]; then
  echo "[golden] 与基线不一致：" >&2
  if [ -f "$GOLDEN" ]; then diff -u "$GOLDEN" "$NEW" >&2 || true; else echo "(基线不存在)" >&2; fi
  exit 1
fi

if [ -f "$GOLDEN" ]; then
  echo "[golden] 变更内容："
  diff -u "$GOLDEN" "$NEW" | head -40 || true
fi
cat "$NEW" > "$GOLDEN"
echo "[golden] 已更新 $GOLDEN（$(grep -c . "$GOLDEN") 行）"
