#!/usr/bin/env bash
#
# run-all.sh — 测试统一入口
#
# 用法：
#   bash tests/run-all.sh              # 全量（提交前 / check-config）
#   bash tests/run-all.sh --tier p0    # 构建门禁（只跑「坏了会编出坏固件」的）
#
# 两级的分界（2026-11-19 定）
# ------------------------
# p0：首启脚本（会覆盖配置/断网）、默认包精简（包会偷偷回来）、升级补丁
#     （勾了保留配置却丢）、配置生成器门禁（设备漂移 / ccache 失效 / uhttpd 被关）
#     —— 这些坏了，编出来的固件不能用。
# all：再加上生成器契约与解析器用例、版本锁、发布说明生成。
#     —— 这些坏了说明工具有问题，但不至于让固件变砖。
#
# 构建里跑 p0（约 1 分钟），改完配置先在 check-config 里跑 all（约 2 分钟）。
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TIER=all
while [ $# -gt 0 ]; do
  case "$1" in
    --tier)   TIER="${2:-all}"; shift 2 ;;
    --tier=*) TIER="${1#*=}"; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

FAIL=0
suite() {
  echo
  echo "######## $1 ########"
  bash "$HERE/$1" "${@:2}"
  if [ $? -ne 0 ]; then
    echo "[tests] $1 失败"
    FAIL=1
  fi
}

suite run-config-tests.sh $( [ "$TIER" = "p0" ] && echo "--tier p0" )
suite run-prune-tests.sh
suite run-upgrade-tests.sh
if [ "$TIER" != "p0" ]; then
  suite run-lock-tests.sh
  suite run-tests.sh
  suite run-drift-tests.sh
fi
suite run-defaults-tests.sh

echo
if [ "$FAIL" -eq 0 ]; then
  echo "[tests] tier=$TIER 全部通过"
else
  echo "[tests] tier=$TIER 有失败"
fi
exit $FAIL
