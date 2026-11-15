#!/usr/bin/env bash
#
# diy.sh — 单线构建的全部定制
#
# 用法：scripts/diy.sh <build-tree>
#   例：scripts/diy.sh openwrt
#
# 开关全部来自 configs/features.tsv：改那里，这里自动跟随。
# 不做 feed 替换、不改内核补丁——那是旧仓 Roc-script.sh 的主要复杂度来源。
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FEATURES="${FEATURES_FILE:-$REPO_DIR/configs/features.tsv}"
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

# ── 3. 权限修正（点阵屏插件需要可执行位）──
if [ -d package/luci-app-athena-led ]; then
  chmod +x package/luci-app-athena-led/root/etc/init.d/athena_led \
           package/luci-app-athena-led/root/usr/sbin/athena-led 2>/dev/null || true
fi

echo "[diy] 完成：$(grep -c '^src-git' feeds.conf.default) 个 feed，$(
  find package -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' '
) 个本地包目录"
