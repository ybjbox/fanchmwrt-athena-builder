#!/usr/bin/env bash
#
# diy.sh — 单线构建的全部定制
#
# 用法：scripts/diy.sh <build-tree>
#   例：scripts/diy.sh openwrt
#
# 开关全部来自 configs/features.md（Markdown 表格）：改那里，这里自动跟随。
# 不做 feed 替换、不改内核补丁——那是旧仓 Roc-script.sh 的主要复杂度来源。
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FEATURES="${FEATURES_FILE:-$REPO_DIR/configs/features.md}"
GEN="$SCRIPT_DIR/gen-config.sh"

TREE="${1:-openwrt}"
die() { printf '[diy] ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "$TREE" ] || die "源码树不存在: $TREE"
[ -f "$TREE/feeds.conf.default" ] || die "$TREE 不像 OpenWrt 源码树"
[ -f "$GEN" ] || die "缺少 gen-config.sh"

cd "$TREE"

# ── 1. feed ──
while IFS='=' read -r name url; do
  [ -n "${name:-}" ] || continue
  if grep -q "^src-git ${name} " feeds.conf.default; then
    echo "[diy] feed 已存在: $name"
  else
    echo "src-git ${name} ${url}" >> feeds.conf.default
    echo "[diy] 追加 feed: $name -> $url"
  fi
done < <(bash "$GEN" --features "$FEATURES" --list-feeds)

# ── 2. 第三方包 ──
while IFS=$'\t' read -r dest url; do
  [ -n "${dest:-}" ] || continue
  if [ -d "package/$dest" ]; then
    echo "[diy] 已存在，跳过: $dest"
    continue
  fi
  git clone --depth=1 "$url" "package/$dest"
  echo "[diy] clone: $dest"
done < <(bash "$GEN" --features "$FEATURES" --list-clones)

# ── 3. 单目录来源：只取大仓里的一个子目录，不整仓拉 ──
# 稀疏检出（--filter=blob:none --sparse）只拉元数据 + 目标目录的文件，
# 避免把别的发行版上百个同名 LuCI 包当成第二个软件源注册进来。
while IFS=$'\t' read -r dest url ref subdir; do
  [ -n "${dest:-}" ] || continue
  if [ -d "package/$dest" ]; then
    echo "[diy] 已存在，跳过: $dest"
    continue
  fi
  tmp="$(mktemp -d)"
  git clone --depth=1 --filter=blob:none --sparse --branch "$ref" "$url" "$tmp/src"
  git -C "$tmp/src" sparse-checkout set "$subdir"
  [ -d "$tmp/src/$subdir" ] || { echo "[diy] ERROR: 仓库里没有子目录: $subdir" >&2; exit 1; }
  cp -a "$tmp/src/$subdir" "package/$dest"
  rm -rf "$tmp"

  # 仓内写法是相对路径 include ../../luci.mk；放到 package/ 下就指错了。
  # 改指 FanchmWrt 自带的官方 luci feed（feeds.conf.default 里就是它）。
  sed -i 's#include ../../luci.mk#include $(TOPDIR)/feeds/luci/luci.mk#' "package/$dest/Makefile"
  grep -qF 'include $(TOPDIR)/feeds/luci/luci.mk' "package/$dest/Makefile" \
    || { echo "[diy] ERROR: $dest/Makefile 的 luci.mk 引用改写失败（上游可能换了写法）" >&2; exit 1; }

  # git 保留 mode，但保险起见把 init.d / uci-defaults 补上可执行位
  find "package/$dest/root/etc/init.d" "package/$dest/root/etc/uci-defaults" \
       -type f -exec chmod +x {} + 2>/dev/null || true
  echo "[diy] gitdir: $dest <- $url#$ref/$subdir"
done < <(bash "$GEN" --features "$FEATURES" --list-gitdirs)

# ── 4. 权限修正（点阵屏插件需要可执行位）──
if [ -d package/luci-app-athena-led ]; then
  chmod +x package/luci-app-athena-led/root/etc/init.d/athena_led \
           package/luci-app-athena-led/root/usr/sbin/athena-led 2>/dev/null || true
fi

# ── 5. 精简上游默认包 ──
# FanchmWrt 把 luci-app-wol / luci-app-ddns 写进了 DEFAULT_PACKAGES.router，
# 只要设备类型是 router 就无条件装进来，features.md 根本管不到它们。
# Lucky 自带 WOL 与 DDNS，这两项纯重复，直接从源头删（连带 etherwake、i18n）。
# 编译前后 forbidden-packages.txt 还有一道拦截，防止被别的包重新拉回来。
bash "$SCRIPT_DIR/prune-defaults.sh" .

# ── 6. LuCI 浏览器标签标题 ──
# 主题把 <title>FanchmWrt</title> 写死在 header.ut 里，首启改 hostname 不会
# 让标签跟着变。这里在编译前改源码：标题读 boardinfo.hostname（首启设为
# Athena），以后在网页里改主机名，标签也同步。
# 必须在编译前改——CONFIG_LUCI_UTMIN=y 时 *.ut 会被 ucode -c 预编译成
# 字节码，装到设备上再 sed 会把模板弄坏。
LUCI_HEADER="package/fcm/luci-theme-fanchmwrt/ucode/template/themes/fanchmwrt/header.ut"
if [ -f "$LUCI_HEADER" ] && grep -q '<title>FanchmWrt</title>' "$LUCI_HEADER"; then
  sed -i "s|<title>FanchmWrt</title>|<title>{{ striptags(boardinfo.hostname ?? 'Athena') }}</title>|" "$LUCI_HEADER"
  echo "[diy] 标签标题改为跟随 hostname"
fi

echo "[diy] 完成：$(grep -c '^src-git' feeds.conf.default) 个 feed，$(
  find package -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' '
) 个本地包目录"
