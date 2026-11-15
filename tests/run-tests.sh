#!/usr/bin/env bash
#
# run-tests.sh — check-packages.sh 的回归测试
# 用法：bash tests/run-tests.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
CHECK="$KIT/scripts/check-packages.sh"
LISTS="$KIT/configs"
WORK="$(mktemp -d)"

PASS=0
FAIL=0
CODE=0
OUT=""

# 直接读清单文件，避免清单增长了而测试还拿着旧副本（会导致假通过）
mapfile -t REQUIRED_LIST < <(grep -vE '^[[:space:]]*(#|$)' "$LISTS/required-packages.txt")

fill_manifest() {
  local f="$1"; shift
  : > "$f"
  local i
  for i in $(seq 1 60); do
    printf 'filler-package-%02d - 1.0-r%d\n' "$i" "$i" >> "$f"
  done
  local p
  for p in "$@"; do printf '%s - 1.0.5-r1\n' "$p" >> "$f"; done
}

make_config() {
  local f="$1"; shift
  : > "$f"
  echo "CONFIG_TARGET_qualcommax=y" >> "$f"
  echo 'CONFIG_TARGET_DEVICE_PACKAGES_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02="luci-app-athena-led luci-i18n-athena-led-zh-cn"' >> "$f"
  local p
  for p in "$@"; do
    case "$p" in
      luci-app-athena-led) continue ;;
    esac
    printf 'CONFIG_PACKAGE_%s=y\n' "$p" >> "$f"
  done
}

# 执行被测脚本，结果写入 CODE / OUT
run_case() {
  OUT="$(bash "$CHECK" "$@" 2>&1)"
  CODE=$?
}

expect_code() { # desc want
  if [ "$CODE" = "$2" ]; then
    printf '  PASS  %s (exit %s)\n' "$1" "$CODE"
    PASS=$((PASS+1))
  else
    printf '  FAIL  %s (want %s, got %s)\n' "$1" "$2" "$CODE"
    printf '%s\n' "$OUT" | sed 's/^/        /'
    FAIL=$((FAIL+1))
  fi
}

expect_contains() { # desc needle
  case "$OUT" in
    *"$2"*) printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)) ;;
    *)      printf '  FAIL  %s（输出未包含: %s）\n' "$1" "$2"; FAIL=$((FAIL+1)) ;;
  esac
}

echo "== t1 config + manifest 全量齐全 → 应通过 =="
fill_manifest "$WORK/m1" "${REQUIRED_LIST[@]}"
make_config "$WORK/c1" "${REQUIRED_LIST[@]}"
run_case --config "$WORK/c1" --manifest "$WORK/m1"
expect_code "全绿" 0

echo "== t2 manifest 缺 luci-app-fwx-traffic-stat → 应失败 =="
missing_list=()
for p in "${REQUIRED_LIST[@]}"; do [ "$p" = "luci-app-fwx-traffic-stat" ] || missing_list+=("$p"); done
fill_manifest "$WORK/m2" "${missing_list[@]}"
run_case --manifest "$WORK/m2"
expect_code "缺必需包被拦下" 1
expect_contains "诊断点名缺失项" "luci-app-fwx-traffic-stat"

echo "== t3 含 qca-nss-dp（主线允许）→ 不应误报 =="
fill_manifest "$WORK/m3" "${REQUIRED_LIST[@]}" qca-nss-dp kmod-qca-nss-dp
run_case --manifest "$WORK/m3"
expect_code "qca-nss-dp 不触发 block" 0

echo "== t4 含 qca-nss-ecm → 应失败 =="
fill_manifest "$WORK/m4" "${REQUIRED_LIST[@]}" qca-nss-ecm
run_case --manifest "$WORK/m4"
expect_code "NSS 卸载栈被拦下" 1
expect_contains "诊断点名 qca-nss-ecm" "qca-nss-ecm"

echo "== t5 含 iptables → 默认告警，--strict 失败 =="
fill_manifest "$WORK/m5" "${REQUIRED_LIST[@]}" iptables
run_case --manifest "$WORK/m5"
expect_code "warn 级不阻断" 0
run_case --manifest "$WORK/m5" --strict
expect_code "strict 下升级为失败" 1

echo "== t6 .config 缺 fwxd → 应失败 =="
cfg_list=()
for p in "${REQUIRED_LIST[@]}"; do [ "$p" = "fwxd" ] || cfg_list+=("$p"); done
make_config "$WORK/c6" "${cfg_list[@]}"
run_case --config "$WORK/c6"
expect_code "config 缺符号被拦下" 1
expect_contains "指出是 config 层" "(config)"

echo "== t7 .config 仅靠 DEVICE_PACKAGES 提供 luci-app-athena-led → 应通过 =="
make_config "$WORK/c7" "${REQUIRED_LIST[@]}"
run_case --config "$WORK/c7"
expect_code "DEVICE_PACKAGES 追加项被识别" 0

echo "== t8 无参数 → 退出码 2 =="
run_case
expect_code "报用法错误" 2

echo
printf '结果: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
