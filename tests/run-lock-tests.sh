#!/usr/bin/env bash
#
# run-lock-tests.sh — versions.lock 与产物哈希的回归测试
# 用法：bash tests/run-lock-tests.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
GEN="$KIT/scripts/gen-lock.sh"
VER="$KIT/scripts/verify-lock.sh"
HASH="$KIT/scripts/hash-artifacts.sh"

WORK="$(mktemp -d)"
TREE="$WORK/tree"
PASS=0; FAIL=0; CODE=0; OUT=""

g() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@"; }

expect_code() {
  if [ "$CODE" = "$2" ]; then
    printf '  PASS  %s (exit %s)\n' "$1" "$CODE"; PASS=$((PASS+1))
  else
    printf '  FAIL  %s (want %s, got %s)\n' "$1" "$2" "$CODE"
    printf '%s\n' "$OUT" | sed 's/^/        /'; FAIL=$((FAIL+1))
  fi
}
expect_contains() {
  case "$OUT" in
    *"$2"*) printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)) ;;
    *) printf '  FAIL  %s（未包含 %s）\n' "$1" "$2"; FAIL=$((FAIL+1)) ;;
  esac
}
run() { OUT="$(bash "$@" 2>&1)"; CODE=$?; }

# ---------- 造一棵假源码树 ----------
mkdir -p "$TREE"
cd "$TREE" || exit 1
g init -q .
printf 'OpenWrt v25.12.6\n' > version
printf 'CONFIG_TARGET_BOARD="qualcommax"\nCONFIG_TARGET_SUBTARGET="ipq60xx"\nCONFIG_TARGET_PROFILE="DEVICE_jdcloud_re-cs-02"\nCONFIG_PACKAGE_fwxd=y\n' > .config
printf 'src-git packages https://git.openwrt.org/feed/packages.git^093d551675b1119a06ef224d419905e8d6b2af1a\n' > feeds.conf.default
git add -A && g commit -qm "init tree"

mkdir -p feeds/packages && (cd feeds/packages && g init -q . && echo a > f && git add -A && g commit -qm "feed a")
mkdir -p package/mypkg && (cd package/mypkg && g init -q . && echo a > f && git add -A && g commit -qm "pkg a")

echo "== L1 生成 lock =="
run "$GEN" --tree "$TREE" --out "$WORK/versions.lock"
expect_code "gen-lock 成功" 0
OUT="$(cat "$WORK/versions.lock")"
expect_contains "含 [meta]" "[meta]"
expect_contains "含 [source]" "[source]"
expect_contains "含 [feeds]" "[feeds]"
expect_contains "含 [thirdparty]" "[thirdparty]"
expect_contains "记录了我的第三方包" "package/mypkg"

echo "== L2 未改动时校验应通过 =="
run "$VER" --tree "$TREE" --lock "$WORK/versions.lock"
expect_code "verify 通过" 0
expect_contains "报告 PASS" "RESULT: PASS"

echo "== L3 第三方包新增提交 → 应失败并点名 =="
(cd "$TREE/package/mypkg" && echo b >> f && git add -A && g commit -qm "pkg b")
run "$VER" --tree "$TREE" --lock "$WORK/versions.lock"
expect_code "检出漂移" 1
expect_contains "点名 package/mypkg" "package/mypkg"

echo "== L4 新增未入锁的包 → 默认告警，strict 失败 =="
mkdir -p "$TREE/package/newpkg" && (cd "$TREE/package/newpkg" && g init -q . && echo n > f && git add -A && g commit -qm "new pkg")
(cd "$TREE/package/mypkg" && g checkout -q HEAD~1)
run "$VER" --tree "$TREE" --lock "$WORK/versions.lock"
expect_code "未入锁仅告警" 0
expect_contains "提示新增未入锁" "新增未入锁"
run "$VER" --tree "$TREE" --lock "$WORK/versions.lock" --strict-extra
expect_code "strict-extra 失败" 1

echo "== L5 生成产物哈希 =="
mkdir -p "$TREE/bin/targets/qualcommax/ipq60xx"
printf 'firmware-bytes' > "$TREE/bin/targets/qualcommax/ipq60xx/a-squashfs-sysupgrade.bin"
printf 'manifest-bytes' > "$TREE/bin/targets/qualcommax/ipq60xx/a.manifest"
run "$HASH" --tree "$TREE" --out "$WORK/dist" --lock "$WORK/versions.lock"
expect_code "hash 成功" 0
SUMLINES=$(wc -l < "$WORK/dist/SHA256SUMS" | tr -d ' ')
if [ "$SUMLINES" = "2" ]; then printf '  PASS  SHA256SUMS 行数=2\n'; PASS=$((PASS+1)); else printf '  FAIL  SHA256SUMS 行数=%s\n' "$SUMLINES"; FAIL=$((FAIL+1)); fi
OUT="$(cat "$WORK/dist/BOM.txt")"
expect_contains "BOM 记录源码 commit" "source_commit="
expect_contains "BOM 记录产物数" "artifact_count=2"
if [ -s "$WORK/dist/build-info.json" ] && command -v python3 >/dev/null 2>&1; then
  if python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$WORK/dist/build-info.json" 2>/dev/null; then
    printf '  PASS  build-info.json 可解析\n'; PASS=$((PASS+1))
  else
    printf '  FAIL  build-info.json 不是合法 JSON\n'; FAIL=$((FAIL+1))
  fi
fi

echo "== L6 重跑哈希 → SHA256SUMS 必须逐字节一致 =="
cp "$WORK/dist/SHA256SUMS" "$WORK/dist/SHA256SUMS.first"
sleep 1
run "$HASH" --tree "$TREE" --out "$WORK/dist" --lock "$WORK/versions.lock"
if cmp -s "$WORK/dist/SHA256SUMS.first" "$WORK/dist/SHA256SUMS"; then
  printf '  PASS  产物哈希确定性\n'; PASS=$((PASS+1))
else
  printf '  FAIL  SHA256SUMS 两次不一致\n'; FAIL=$((FAIL+1))
fi

echo "== L7 无产物时 hash 应失败 =="
mkdir -p "$WORK/empty/bin/targets"
run "$HASH" --tree "$WORK/empty" --out "$WORK/dist2"
expect_code "无产物返回 1" 1

echo "== L8 参数缺失 → 退出码 2 =="
run "$GEN"
expect_code "gen-lock 缺参数" 2
run "$VER" --tree "$TREE"
expect_code "verify-lock 缺 lock" 2

echo
printf '结果: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
