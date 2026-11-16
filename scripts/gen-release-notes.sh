#!/usr/bin/env bash
#
# gen-release-notes.sh — 生成「给刷机的人看」的 Release 说明（Markdown）
#
# 用法：
#   scripts/gen-release-notes.sh --dist dist --features configs/features.md \
#     --manifest openwrt/bin/targets/.../xxx.manifest --lock versions.lock \
#     --upstream 8f3a2b1c9d4e --upstream-ref fanchmwrt-26.11 --trigger schedule \
#     --kernel 6.18.60 --out dist/release-notes.md
#
# 所有输入都是"能给就给"：缺哪个就省略对应段落，绝不因取不到数据而失败。
# 文件末尾有一段「自动化读取区」（upstream-commit: 等），定时构建靠它判断上游是否变化，不要删。
#
set -Eeuo pipefail

DIST=""; FEATURES=""; MANIFEST=""; LOCK=""
UPSTREAM=""; UPSTREAM_REF=""; TRIGGER=""; KERNEL=""; OUT=""

die() { printf '[release-notes] ERROR: %s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dist)         [ $# -ge 2 ] || die "--dist 需要参数";         DIST="$2";         shift 2 ;;
    --features)     [ $# -ge 2 ] || die "--features 需要参数";     FEATURES="$2";     shift 2 ;;
    --manifest)     [ $# -ge 2 ] || die "--manifest 需要参数";     MANIFEST="$2";     shift 2 ;;
    --lock)         [ $# -ge 2 ] || die "--lock 需要参数";         LOCK="$2";         shift 2 ;;
    --upstream)     [ $# -ge 2 ] || die "--upstream 需要参数";     UPSTREAM="$2";     shift 2 ;;
    --upstream-ref) [ $# -ge 2 ] || die "--upstream-ref 需要参数"; UPSTREAM_REF="$2"; shift 2 ;;
    --trigger)      [ $# -ge 2 ] || die "--trigger 需要参数";      TRIGGER="$2";      shift 2 ;;
    --kernel)       [ $# -ge 2 ] || die "--kernel 需要参数";       KERNEL="$2";       shift 2 ;;
    --out)          [ $# -ge 2 ] || die "--out 需要参数";          OUT="$2";          shift 2 ;;
    -h|--help) echo "用法: gen-release-notes.sh --dist <dir> --out <file.md> [其它可选参数]"; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

[ -n "$OUT" ] || die "缺少 --out"
[ -n "$DIST" ] || die "缺少 --dist"
[ -d "$DIST" ] || die "dist 目录不存在: $DIST"

# 北京时间 = UTC+8。不用 TZ=Asia/Shanghai：部分环境（如 Windows 的 Git Bash）
# 没有时区数据库，会静默回退成 GMT，导致说明里的时间少 8 小时。
BUILT_AT="$(date -u -d '+8 hours' '+%Y-%m-%d %H:%M:%S')"
BUILT_DATE="$(date -u -d '+8 hours' '+%Y-%m-%d %H:%M')"

# ── 触发方式说人话 ──
case "$TRIGGER" in
  schedule)          TRIGGER_CN="定时（每周五 03:30 北京时间）" ;;
  workflow_dispatch) TRIGGER_CN="手动触发" ;;
  push)              TRIGGER_CN="推送 tag" ;;
  "")                TRIGGER_CN="" ;;
  *)                 TRIGGER_CN="$TRIGGER" ;;
esac

# ── 功能开关清单（只认 6 列表格，第一列「名称」第二列「启用」）──
ON_LIST=""; OFF_LIST=""; ON_N=0; OFF_N=0
if [ -f "$FEATURES" ]; then
  PARSED="$(awk -F'|' '
    /^\| *名称 *\| *启用 *\|/ { inb=1; next }
    /^\|/ {
      if (!inb) next;
      name=$2; en=$3;
      gsub(/^[ \t]+|[ \t]+$/, "", name);
      gsub(/^[ \t]+|[ \t]+$/, "", en);
      if (en ~ /^-+$/) next;
      if (en == "1")      { on  = on  (on  == "" ? "" : "、") name; onn++ }
      else if (en == "0") { off = off (off == "" ? "" : "、") name; offn++ }
      next
    }
    { inb=0 }
    END { printf "%s\n%s\n%d\n%d\n", on, off, onn+0, offn+0 }
  ' "$FEATURES")"
  ON_LIST="$(printf '%s\n' "$PARSED" | sed -n 1p)"
  OFF_LIST="$(printf '%s\n' "$PARSED" | sed -n 2p)"
  ON_N="$(printf '%s\n' "$PARSED" | sed -n 3p)"
  OFF_N="$(printf '%s\n' "$PARSED" | sed -n 4p)"
fi

# ── 包数量（manifest 行数）──
PKG_N=""
if [ -f "$MANIFEST" ]; then
  PKG_N="$(awk 'NF>=1 && $1 !~ /^#/ {c++} END{print c+0}' "$MANIFEST")"
fi

# ── 从 BOM 取追溯字段（没有就省略）──
bom_get() {
  [ -f "$DIST/BOM.txt" ] || return 0
  awk -F= -v k="$1" '$1==k {print substr($0, index($0,"=")+1); exit}' "$DIST/BOM.txt"
}
CONFIG_SHA="$(bom_get config_sha256)"
LOCK_SHA="$(bom_get lock_sha256)"
ART_N="$(bom_get artifact_count)"
TOTAL_B="$(bom_get total_bytes)"
TOTAL_H=""
if [ -n "$TOTAL_B" ]; then
  TOTAL_H="$(awk -v b="$TOTAL_B" 'BEGIN{split("B KB MB GB",u," ");i=1;while(b>=1024&&i<4){b/=1024;i++};printf "%.1f %s",b,u[i]}')"
fi

human_size() {
  awk -v b="$1" 'BEGIN{split("B KB MB GB",u," ");i=1;while(b>=1024&&i<4){b/=1024;i++};printf "%.1f %s",b,u[i]}'
}

# ── 产物表（按用途排序：首次刷机 → 系统升级 → 救砖 → 其它）──
declare -a A_FACTORY=() A_SYSUP=() A_INITRA=() A_OTHER=()
if [ -d "$DIST/firmware" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$(basename "$f")" in
      *factory.bin)    A_FACTORY+=("$f") ;;
      *sysupgrade.bin) A_SYSUP+=("$f") ;;
      *initramfs*)     A_INITRA+=("$f") ;;
      *)               A_OTHER+=("$f") ;;
    esac
  done < <(find "$DIST/firmware" -maxdepth 1 -type f \( -name '*.bin' -o -name '*.itb' \) | sort)
fi

ROWS=""; FILE_N=0
for f in ${A_FACTORY[@]+"${A_FACTORY[@]}"} ${A_SYSUP[@]+"${A_SYSUP[@]}"} \
         ${A_INITRA[@]+"${A_INITRA[@]}"} ${A_OTHER[@]+"${A_OTHER[@]}"}; do
  base="$(basename "$f")"
  sz="$(stat -c '%s' "$f" 2>/dev/null || stat -f '%z' "$f")"
  hash="$(sha256sum "$f" | awk '{print $1}' | sed 's/^\\//')"
  case "$base" in
    *factory.bin)    use="**首次刷机**：进不死 uboot 上传" ;;
    *sysupgrade.bin) use="**系统内升级**：LuCI「系统 → 备份/刷机」" ;;
    *initramfs*)     use="只读内存系统，救砖 / 试机用" ;;
    *)               use="" ;;
  esac
  # printf -v 保留换行；用 $( ) 接会吞掉行尾换行，导致表格粘成一行
  printf -v ROW '| `%s` | %s | %s | `%s` |\n' "$base" "$use" "$(human_size "$sz")" "$hash"
  ROWS+="$ROW"
  FILE_N=$((FILE_N + 1))
done

# ── 写说明 ──
mkdir -p "$(dirname "$OUT")"
{
  printf '# 雅典娜固件 · %s（北京时间）\n\n' "$BUILT_DATE"
  printf 'FanchmWrt snapshot'
  [ -n "${UPSTREAM_REF:-}" ] && printf ' · `%s`' "$UPSTREAM_REF"
  printf ' · `jdcloud_re-cs-02`'
  [ -n "$KERNEL" ] && printf ' · Linux %s' "$KERNEL"
  [ -n "$PKG_N" ] && printf ' · %s 个包' "$PKG_N"
  printf '\n\n'

  if [ "$FILE_N" -gt 0 ]; then
    printf '## 刷机\n\n'
    printf '| 文件 | 用途 | 大小 | SHA256 |\n|---|---|---|---|\n'
    printf '%s' "$ROWS"
    printf '\n'
  fi

  if [ "$ON_N" -gt 0 ] || [ "$OFF_N" -gt 0 ]; then
    printf '## 本次包含\n\n'
    [ "$ON_N" -gt 0 ] && printf -- '- **启用 %s 项**：%s\n' "$ON_N" "$ON_LIST"
    [ "$OFF_N" -gt 0 ] && printf -- '- 关闭 %s 项：%s\n' "$OFF_N" "$OFF_LIST"
    printf '\n'
  fi

  printf '## 构建追溯\n\n| 项 | 值 |\n|---|---|\n'
  [ -n "$UPSTREAM_REF" ] && printf '| 上游分支 | `fanchmwrt-snapshot` @ `%s` |\n' "$UPSTREAM_REF"
  [ -n "$UPSTREAM" ]     && printf '| 上游 commit | `%s` |\n' "$UPSTREAM"
  [ -n "$TRIGGER_CN" ]   && printf '| 触发方式 | %s |\n' "$TRIGGER_CN"
  printf '| 构建时间 | %s |\n' "$BUILT_AT"
  [ -n "$CONFIG_SHA" ] && [ "$CONFIG_SHA" != "none" ] && printf '| 配置哈希 | `%s` |\n' "$CONFIG_SHA"
  [ -n "$LOCK_SHA" ]   && [ "$LOCK_SHA" != "none" ]   && printf '| 版本锁哈希 | `%s` |\n' "$LOCK_SHA"
  [ -n "$ART_N" ]      && printf '| 产物 | %s 个，共 %s |\n' "$ART_N" "${TOTAL_H:-未知}"
  printf '\n'

  printf -- '> 完整校验值见附件 `SHA256SUMS`，逐包清单见固件内 `manifest`。\n\n'

  # 自动化读取区：定时构建的 gate job 依赖这里的 upstream-commit 行，删了会导致每次都全量重建
  printf '<!-- 自动化读取区（定时构建判断上游是否变化），请保留 -->\n'
  printf 'upstream-commit: %s\n' "${UPSTREAM:-unknown}"
  printf 'upstream-ref: %s\n' "${UPSTREAM_REF:-unknown}"
  printf 'built-at: %s\n' "$BUILT_AT"
  printf 'trigger: %s\n' "${TRIGGER:-unknown}"
} > "$OUT"

printf '[release-notes] 写入 %s（%s 个产物，启用 %s 项功能）\n' "$OUT" "$FILE_N" "${ON_N:-0}"
