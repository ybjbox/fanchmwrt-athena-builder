#!/usr/bin/env bash
#
# run-config-tests.sh — features.md 与 gen-config.sh 的回归测试
# 用法：bash tests/run-config-tests.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
GEN="$KIT/scripts/gen-config.sh"
FEATURES="$KIT/configs/features.md"
WORK="$(mktemp -d)"

PASS=0; FAIL=0; CODE=0; OUT=""

run() { OUT="$(bash "$@" 2>&1)"; CODE=$?; }
expect_code() {
  if [ "$CODE" = "$2" ]; then printf '  PASS  %s (exit %s)\n' "$1" "$CODE"; PASS=$((PASS+1));
  else printf '  FAIL  %s (want %s, got %s)\n' "$1" "$2" "$CODE"; printf '%s\n' "$OUT" | sed 's/^/        /'; FAIL=$((FAIL+1)); fi
}
expect_has() {
  case "$OUT" in *"$2"*) printf '  PASS  %s\n' "$1"; PASS=$((PASS+1));;
    *) printf '  FAIL  %s（未包含: %s）\n' "$1" "$2"; FAIL=$((FAIL+1));; esac
}
expect_not() {
  case "$OUT" in *"$2"*) printf '  FAIL  %s（不应包含: %s）\n' "$1" "$2"; FAIL=$((FAIL+1));;
    *) printf '  PASS  %s\n' "$1"; PASS=$((PASS+1));; esac
}

echo "== C1 默认开关：核心包在、默认关闭项不在 =="
run "$GEN" --features "$FEATURES"
expect_code "生成成功" 0
expect_has "输出目标设备" "CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02=y"
expect_has "设备附加包含 athena-led" 'CONFIG_TARGET_DEVICE_PACKAGES_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02="luci-app-athena-led luci-i18n-athena-led-zh-cn"'
expect_has "个人包在" "CONFIG_PACKAGE_athena-custom=y"
expect_has "工具在" "CONFIG_PACKAGE_htop=y"
expect_has "zram 内核选项在" "CONFIG_KERNEL_ZRAM_BACKEND_LZ4=y"
expect_has "策略性禁用 OAF" "# CONFIG_PACKAGE_luci-app-oaf is not set"
expect_not "默认不含 OpenClash" "CONFIG_PACKAGE_luci-app-openclash=y"
expect_not "默认不含 bandix" "CONFIG_PACKAGE_bandix=y"

echo "== C2 打开 OpenClash：包与 clone 同时生效 =="
sed 's/^| openclash | 0 |/| openclash | 1 |/' "$FEATURES" > "$WORK/f2.md"
run "$GEN" --features "$WORK/f2.md"
expect_has "包已选" "CONFIG_PACKAGE_luci-app-openclash=y"
run "$GEN" --features "$WORK/f2.md" --list-clones
expect_has "clone 清单含 OpenClash" "OpenClash"
expect_has "clone 清单含 athena-led" "luci-app-athena-led"

echo "== C3 feed 清单去重 =="
run "$GEN" --features "$FEATURES" --list-feeds
expect_code "list-feeds 成功" 0
N=$(printf '%s\n' "$OUT" | grep -c '^ybjbox=')
if [ "$N" = "1" ]; then printf '  PASS  ybjbox 仅一条\n'; PASS=$((PASS+1)); else printf '  FAIL  ybjbox 出现 %s 次\n' "$N"; FAIL=$((FAIL+1)); fi

echo "== C4 数据错误：重名 =="
{ cat "$FEATURES"; echo "| athena_led | 1 | 0 | x | | dup |"; } > "$WORK/f4.md"
run "$GEN" --features "$WORK/f4.md" --check
expect_code "重名被拒" 2
expect_has "报错点名重名" "功能名重复"

echo "== C5 数据错误：启用列非 0/1 =="
sed 's/^| openclash | 0 |/| openclash | 2 |/' "$FEATURES" > "$WORK/f5.md"
run "$GEN" --features "$WORK/f5.md" --check
expect_code "非法启用值被拒" 2
expect_has "报错指出列值" "必须是 0 或 1"

echo "== C6 数据错误：未知来源前缀 =="
sed 's#git:https://github.com/gdy666/luci-app-lucky#svn:https://github.com/gdy666/luci-app-lucky#' "$FEATURES" > "$WORK/f6.md"
run "$GEN" --features "$WORK/f6.md" --check
expect_code "未知来源被拒" 2
expect_has "报错指出只支持 git/feed" "只支持 git: 与 feed:"

echo "== C7 --check 汇总 =="
run "$GEN" --features "$FEATURES" --check
expect_code "check 通过" 0
expect_has "输出启用计数" "功能项：启用"

echo "== C8 缺文件 → 退出 2 =="
run "$GEN" --features "$WORK/nope.md"
expect_code "缺文件报错" 2

echo "== C9 Markdown 专属：说明表格被忽略 =="
run "$GEN" --features "$FEATURES" --check
expect_code "含 2 列说明表仍能解析" 0
expect_not "不把说明表当数据行" "必须有 6 列"

echo "== C10 数据行少一列 → 报错并指行号 =="
cat > "$WORK/f10.md" <<'EOF'
| 名称 | 启用 | 设备附加包 | 包列表 | 来源 | 说明 |
|---|---|---|---|---|---|
| x | 1 | 0 | pkg-x | |
EOF
run "$GEN" --features "$WORK/f10.md" --check
expect_code "列数不足被拒" 2
expect_has "报错说明列数" "必须有 6 列"
expect_has "报错带行号" "第 3 行"

echo "== C11 无表格（如被 Excel 存成 Tab）→ 报错 =="
printf '名称\t启用\t设备附加包\t包列表\t来源\t说明\nx\t1\t0\tpkg-x\t\t备注\n' > "$WORK/f11.md"
run "$GEN" --features "$WORK/f11.md" --check
expect_code "无 6 列表格被拒" 2
expect_has "提示可能被存成 Tab" "未从"

echo "== C12 单元格内转义竖线 \\| 不破坏列数 =="
cat > "$WORK/f12.md" <<'EOF'
| 名称 | 启用 | 设备附加包 | 包列表 | 来源 | 说明 |
|---|---|---|---|---|---|
| x | 1 | 0 | pkg-x | | 左右 \| 竖线 |
EOF
run "$GEN" --features "$WORK/f12.md"
expect_code "转义竖线不报列错" 0
expect_has "同行的包仍被选中" "CONFIG_PACKAGE_pkg-x=y"
run "$GEN" --features "$WORK/f12.md" --check
expect_has "计数为 1 条" "启用 1，关闭 0"

echo "== C13 缺表头（只有数据行）→ 报错 =="
cat > "$WORK/f13.md" <<'EOF'
| x | 1 | 0 | pkg-x | | 备注 |
EOF
run "$GEN" --features "$WORK/f13.md" --check
expect_code "缺表头被拒" 2

echo
printf '结果: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
