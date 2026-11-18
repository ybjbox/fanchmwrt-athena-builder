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
expect_line() { # desc exact-line：用于清单类输出，避免子串误判
  if printf '%s\n' "$OUT" | grep -qxF "$2"; then
    printf '  PASS  %s\n' "$1"; PASS=$((PASS+1))
  else
    printf '  FAIL  %s（清单里没有整行: %s）\n' "$1" "$2"; FAIL=$((FAIL+1))
  fi
}

echo "== C1 当前基线（旧仓同款，去掉 bandix 与主题）=="
run "$GEN" --features "$FEATURES"
expect_code "生成成功" 0
expect_not "片段不含目标行（目标选择由流水线基线负责，重复写入会重置设备）" "CONFIG_TARGET_qualcommax=y"
expect_has "无线 board file 显式选中" "CONFIG_PACKAGE_ipq-wifi-jdcloud_re-cs-02=y"
expect_has "QCN9074 固件显式选中" "CONFIG_PACKAGE_ath11k-firmware-qcn9074=y"
expect_has "ath11k PCI 驱动显式选中" "CONFIG_PACKAGE_kmod-ath11k-pci=y"
expect_has "点阵屏驱动普通直选" "CONFIG_PACKAGE_luci-app-athena-led=y"
expect_not "athena-custom 包不再装入（首启脚本改由 base-files 注入）" "CONFIG_PACKAGE_athena-custom=y"
expect_has "工具在" "CONFIG_PACKAGE_htop=y"
expect_has "zram 内核选项在" "CONFIG_KERNEL_ZRAM_BACKEND_LZ4=y"
expect_has "启用 ccache 编译加速" "CONFIG_CCACHE=y"
# CCACHE 的选项定义是 `bool "Use ccache" if DEVEL`：DEVEL 没开，这一行会被
# make defconfig 当未知符号静默丢弃，编译照常成功但全程不走缓存（2026-11-17 查清）。
expect_has "ccache 依赖的 DEVEL 一并写入" "CONFIG_DEVEL=y"
expect_has "策略性禁用 OAF" "# CONFIG_PACKAGE_luci-app-oaf is not set"
expect_has "OpenClash 已启用" "CONFIG_PACKAGE_luci-app-openclash=y"
expect_not "autoreboot 不再由开关表携带（源码默认包已带）" "CONFIG_PACKAGE_luci-app-autoreboot=y"
expect_has "网页终端已启用" "CONFIG_PACKAGE_luci-app-ttyd=y"
expect_has "网页终端本体在" "CONFIG_PACKAGE_ttyd=y"
expect_has "网页终端中文包在" "CONFIG_PACKAGE_luci-i18n-ttyd-zh-cn=y"
expect_has "mosdns 带 geoip" "CONFIG_PACKAGE_v2ray-geoip=y"
expect_has "mosdns 带 geosite" "CONFIG_PACKAGE_v2ray-geosite=y"
expect_not "不再输出无效的 v2ray-geodata" "CONFIG_PACKAGE_v2ray-geodata=y"

# ybjbox 软件源的网址现在登记在 dhcp_comment 行，被 dhcp_comment / clash_cleaner /
# cf_ipcheck 三行引用。网址一旦被删，gen-config.sh 会在完整性检查里 die，这里守住。
run "$GEN" --features "$FEATURES" --list-feeds
expect_code "列软件源成功" 0
expect_has "ybjbox 网址登记仍在" "ybjbox=https://github.com/ybjbox/openwrt-packages.git"
expect_not "bandix 已关闭（fwx 自带统计）" "CONFIG_PACKAGE_luci-app-bandix=y"
expect_not "第三方主题已关闭" "CONFIG_PACKAGE_luci-theme-aurora=y"
run "$GEN" --features "$FEATURES" --list-clones
expect_not "bandix 不再 clone" "openwrt-bandix"

echo "== C2 关掉 OpenClash：包与 clone 一起消失 =="
sed 's/^| openclash | 1 |/| openclash | 0 |/' "$FEATURES" > "$WORK/f2.md"
run "$GEN" --features "$WORK/f2.md"
expect_code "仍能生成" 0
expect_not "包已取消" "CONFIG_PACKAGE_luci-app-openclash=y"
run "$GEN" --features "$WORK/f2.md" --list-clones
expect_not "clone 清单不含 OpenClash" "OpenClash"
expect_has "其它 clone 不受影响" "luci-app-athena-led"

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
sed 's/^| lucky | 1 |/| lucky | 2 |/' "$FEATURES" > "$WORK/f5.md"
run "$GEN" --features "$WORK/f5.md" --check
expect_code "非法启用值被拒" 2
expect_has "报错指出列值" "必须是 0 或 1"

echo "== C6 数据错误：未知来源前缀 =="
sed 's#git:https://github.com/gdy666/luci-app-lucky#svn:https://github.com/gdy666/luci-app-lucky#' "$FEATURES" > "$WORK/f6.md"
run "$GEN" --features "$WORK/f6.md" --check
expect_code "未知来源被拒" 2
expect_has "报错指出支持的来源" "可用的写法：git:网址、gitdir:网址#分支/子目录、feed:名字=网址"

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
expect_has "提示可能被存成 Tab" "没有从"

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

echo "== C14 安全底线：不得静默关掉 uhttpd =="
# luci-light 硬依赖 uhttpd，写 not set 会被 select 覆盖；一旦真被关掉，
# 刷完就没有 web 界面了（只能 SSH）。这里守住"绝不输出该行"。
run "$GEN" --features "$FEATURES"
expect_code "生成成功" 0
expect_not "未关掉 uhttpd" "# CONFIG_PACKAGE_uhttpd is not set"
expect_has "quickfile 插件本身在" "CONFIG_PACKAGE_luci-app-quickfile=y"
expect_not "未引入 nginx（无法与 uhttpd 共存 80）" "CONFIG_PACKAGE_nginx=y"

echo "== C15 点名册自动派生：改开关，清单自动跟着变 =="
run "$GEN" --features "$FEATURES" --list-required
expect_code "派生清单生成成功" 0
BASE_N=$(printf '%s\n' "$OUT" | grep -c .)
expect_line "启用行的工具包在清单里" 'htop'

sed 's/^| logrotate | 1 |/| logrotate | 0 |/' "$FEATURES" > "$WORK/f15a.md"
run "$GEN" --features "$WORK/f15a.md" --list-required
expect_not "关掉 logrotate 后清单不再要求它" 'logrotate'
N_A=$(printf '%s\n' "$OUT" | grep -c .)
if [ "$N_A" -eq "$((BASE_N - 1))" ]; then
  printf '  PASS  关一个单包开关，清单恰好少 1 行\n'; PASS=$((PASS+1))
else
  printf '  FAIL  清单行数不对（基线 %s，关掉后 %s）\n' "$BASE_N" "$N_A"; FAIL=$((FAIL+1))
fi

sed 's/^| tools_base | 1 |/| tools_base | 0 |/' "$FEATURES" > "$WORK/f15b.md"
run "$GEN" --features "$WORK/f15b.md" --list-required
expect_not "关掉工具组后 htop 也不在清单" 'htop'
N_B=$(printf '%s\n' "$OUT" | grep -c .)
# 包数从表里现取，以后往 tools_base 增删包也不会让断言变假
TOOLS_N=$(sed -n 's/^| tools_base | [01] | [01] | \([^|]*\) |.*/\1/p' "$FEATURES" | wc -w | tr -d ' ')
if [ "$N_B" -eq "$((BASE_N - TOOLS_N))" ]; then
  printf '  PASS  关掉整行（%s 个包），清单恰好少 %s 行\n' "$TOOLS_N" "$TOOLS_N"; PASS=$((PASS+1))
else
  printf '  FAIL  多行包没有整行同步（基线 %s，关掉后 %s，期望 %s）\n' \
    "$BASE_N" "$N_B" "$((BASE_N - TOOLS_N))"; FAIL=$((FAIL+1))
fi

sed 's/^| bandix | 0 |/| bandix | 1 |/' "$FEATURES" > "$WORK/f15c.md"
run "$GEN" --features "$WORK/f15c.md" --list-required
expect_line "原本关闭的 bandix 打开后自动进清单" 'bandix'
expect_line "同一行的第二个包也自动进清单" 'luci-app-bandix'

echo "== C16 gitdir 单目录来源（不整仓拉）=="
# 真实开关表里已无 gitdir 行（autoreboot 确认是源码默认包，已删除），
# 机制本身仍要守，用临时表验证。
cat > "$WORK/f16.md" <<'EOF'
| 名称 | 启用 | 设备附加包 | 包列表 | 来源 | 说明 |
|---|---|---|---|---|---|
| sample | 1 | 0 | luci-app-sample | gitdir:https://github.com/immortalwrt/luci#master/applications/luci-app-sample | 测试用 |
EOF
run "$GEN" --features "$WORK/f16.md" --list-gitdirs
expect_code "gitdir 清单生成成功" 0
expect_has "目标目录名" "luci-app-sample"
expect_has "分支" "master"
expect_has "子目录" "applications/luci-app-sample"
expect_has "仓库" "immortalwrt/luci"
run "$GEN" --features "$WORK/f16.md" --list-clones
expect_not "没有把 ImmortalWrt 整仓 clone" "immortalwrt/luci"
sed 's/^| sample | 1 |/| sample | 0 |/' "$WORK/f16.md" > "$WORK/f16off.md"
run "$GEN" --features "$WORK/f16off.md" --list-gitdirs
expect_not "关掉后不再取该目录" "luci-app-sample"

echo "== C17 gitdir 写法错误要能拦住 =="
cat > "$WORK/f17a.md" <<'EOF'
| 名称 | 启用 | 设备附加包 | 包列表 | 来源 | 说明 |
|---|---|---|---|---|---|
| x | 1 | 0 | pkg-x | gitdir:https://example.com/r.git | 缺分支与子目录 |
EOF
run "$GEN" --features "$WORK/f17a.md" --check
expect_code "gitdir 缺路径被拒" 2
expect_has "报错指出正确写法" "gitdir: 需写成"

cat > "$WORK/f17b.md" <<'EOF'
| 名称 | 启用 | 设备附加包 | 包列表 | 来源 | 说明 |
|---|---|---|---|---|---|
| x | 1 | 0 | pkg-x | gitdir:https://example.com/r.git#master/../../etc | 越界 |
EOF
run "$GEN" --features "$WORK/f17b.md" --check
expect_code "子目录越界被拒" 2
expect_has "报错要求仓库内相对路径" "仓库内相对路径"

echo "== C18 Release 说明生成（刷机要点 / 功能清单 / 自动化读取区）=="
RN="$KIT/scripts/gen-release-notes.sh"
RT="$WORK/rn"; mkdir -p "$RT/dist/firmware"
head -c 2048 /dev/zero > "$RT/dist/firmware/openwrt-x-jdcloud_re-cs-02-squashfs-factory.bin"
head -c 2048 /dev/zero > "$RT/dist/firmware/openwrt-x-jdcloud_re-cs-02-squashfs-sysupgrade.bin"
head -c 2048 /dev/zero > "$RT/dist/firmware/openwrt-x-jdcloud_re-cs-02-initramfs-uImage.itb"
printf 'filler\n%.0s' $(seq 1 100) > "$RT/manifest"
printf 'config_sha256=abc123\nlock_sha256=def456\nartifact_count=3\ntotal_bytes=6144\n' > "$RT/dist/BOM.txt"
run "$RN" --dist "$RT/dist" --features "$FEATURES" --manifest "$RT/manifest" \
  --upstream 8f3a2b1c9d4e --upstream-ref fanchmwrt-26.11 --trigger schedule \
  --kernel 6.18.60 --out "$RT/notes.md"
expect_code "生成成功" 0
OUT="$(cat "$RT/notes.md")"
expect_not "不再罗列小分区 uboot / 分区余量" "小分区 uboot"
expect_not "不再罗列默认管理地址与密码说明" "默认管理地址"
expect_not "不再罗列定时重启说明" "定时重启不预置"
# 启用项数从表里现取：以后改开关不用同步改这句断言
ON_N=$(awk -F'|' 'NF>=7 && $3 ~ /^ *1 *$/ {c++} END{print c+0}' "$FEATURES")
expect_has "含启用功能清单" "启用 $ON_N 项"
expect_has "含刷机用途说明" "首次刷机"
expect_line "自动化读取区保留 upstream-commit（定时 gate 依赖）" "upstream-commit: 8f3a2b1c9d4e"
NROWS=$(printf '%s\n' "$OUT" | grep -c '^| `openwrt-x')
if [ "$NROWS" = "3" ]; then
  printf '  PASS  产物表 3 行各自独立（未粘连）\n'; PASS=$((PASS+1))
else
  printf '  FAIL  产物表行数异常：%s\n' "$NROWS"; FAIL=$((FAIL+1))
fi

mkdir -p "$RT/empty/dist/firmware"
run "$RN" --dist "$RT/empty/dist" --out "$RT/min.md"
expect_code "缺可选参数也能生成" 0
run "$RN" --dist "$RT/dist"
expect_code "缺 --out 被拒" 2

echo
printf '结果: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
