#!/usr/bin/env bash
#
# hash-artifacts.sh — 为固件产物生成 SHA256SUMS / BOM.txt / build-info.json
#
# 用法：
#   scripts/hash-artifacts.sh --tree . --out dist
#   scripts/hash-artifacts.sh --tree . --out dist --lock versions.lock
#
# 退出码：0 成功 / 1 未找到产物 / 2 用法错误
#
set -Eeuo pipefail

TREE=""
OUT=""
LOCK=""

die() { printf '[hash-artifacts] ERROR: %s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --tree) [ $# -ge 2 ] || die "--tree 需要参数"; TREE="$2"; shift 2 ;;
    --out)  [ $# -ge 2 ] || die "--out 需要参数";  OUT="$2";  shift 2 ;;
    --lock) [ $# -ge 2 ] || die "--lock 需要参数"; LOCK="$2"; shift 2 ;;
    -h|--help) echo "用法: hash-artifacts.sh --tree <tree> --out <dir> [--lock <lockfile>]"; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

[ -d "$TREE" ] || die "tree 不存在: $TREE"
[ -n "$OUT" ] || die "缺少 --out"
[ -d "$TREE/bin/targets" ] || die "找不到 $TREE/bin/targets（尚未编译？）"

mkdir -p "$OUT"

lock_get() { # section item field_no
  [ -f "$LOCK" ] || return 0
  awk -F'\t' -v sec="$1" -v item="$2" -v n="$3" '
    /^\[.*\]$/ { s=substr($1,2,length($1)-2); next }
    s==sec && $1==item { print $n; exit }
  ' "$LOCK"
}
meta_get() {
  [ -f "$LOCK" ] || return 0
  awk -F'\t' -v k="$1" '
    /^\[meta\]$/ { m=1; next }
    /^\[.*\]$/ { m=0 }
    m && $1==k { print $2; exit }
  ' "$LOCK"
}

SRC_REPO="$(lock_get source source 2)"
SRC_REF="$(lock_get source source 3)"
SRC_COMMIT="$(lock_get source source 4)"
[ -n "$SRC_COMMIT" ] || SRC_COMMIT="$(git -C "$TREE" rev-parse HEAD 2>/dev/null || echo unknown)"
[ -n "$SRC_REPO" ]   || SRC_REPO="$(git -C "$TREE" config --get remote.origin.url 2>/dev/null || echo unknown)"
[ -n "$SRC_REF" ]    || SRC_REF="$(git -C "$TREE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"

OPENWRT_VERSION="$(meta_get openwrt_version)"
[ -n "$OPENWRT_VERSION" ] || OPENWRT_VERSION="$(cat "$TREE/version" 2>/dev/null || echo unknown)"
TARGET="$(meta_get target)"
PROFILE="$(meta_get profile)"
CONFIG_SHA="$(meta_get config_sha256)"
LOCK_SHA=""
[ -f "$LOCK" ] && LOCK_SHA="$(sha256sum "$LOCK" | awk '{print $1}' | sed 's/^\\//')"

FILES=()
while IFS= read -r f; do
  [ -n "$f" ] && FILES+=("$f")
done < <(find "$TREE/bin/targets" -type f \
  \( -name '*.bin' -o -name '*.itb' -o -name '*.img' -o -name '*.img.gz' \
     -o -name '*.ubi' -o -name '*.tar' -o -name '*.manifest' -o -name '*.buildinfo' \) \
  ! -path '*/packages/*' | sort)

COUNT="${#FILES[@]}"
[ "$COUNT" -gt 0 ] || { printf '[hash-artifacts] 未找到固件产物：%s/bin/targets\n' "$TREE" >&2; exit 1; }

: > "$OUT/SHA256SUMS"
TOTAL=0
ROWS=()
JSON_ITEMS=()
FIRST=1

for f in "${FILES[@]}"; do
  rel="${f#"$TREE"/bin/targets/}"
  size=$(stat -c '%s' "$f" 2>/dev/null || stat -f '%z' "$f")
  hash=$(sha256sum "$f" | awk '{print $1}' | sed 's/^\\//')
  TOTAL=$((TOTAL + size))
  printf '%s  %s\n' "$hash" "$rel" >> "$OUT/SHA256SUMS"
  ROWS+=("$(printf '%-62s  %12s  %s' "$rel" "$size" "$hash")")
  if [ "$FIRST" -eq 1 ]; then FIRST=0; else JSON_ITEMS+=(","); fi
  JSON_ITEMS+=("$(printf '\n    {"name":"%s","size":%s,"sha256":"%s"}' "$rel" "$size" "$hash")")
done

{
  printf '# Build BOM — 由 hash-artifacts.sh 生成\n'
  printf 'generated_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'openwrt_version=%s\n' "$OPENWRT_VERSION"
  printf 'target=%s\n' "${TARGET:-unknown}"
  printf 'profile=%s\n' "${PROFILE:-unknown}"
  printf 'source_repo=%s\n' "$SRC_REPO"
  printf 'source_ref=%s\n' "$SRC_REF"
  printf 'source_commit=%s\n' "$SRC_COMMIT"
  printf 'config_sha256=%s\n' "${CONFIG_SHA:-none}"
  printf 'lock_sha256=%s\n' "${LOCK_SHA:-none}"
  printf 'artifact_count=%s\n' "$COUNT"
  printf 'total_bytes=%s\n' "$TOTAL"
  printf '# name  size_bytes  sha256\n'
  printf '%s\n' "${ROWS[@]}"
} > "$OUT/BOM.txt"

{
  printf '{\n'
  printf '  "generated_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "openwrt_version": "%s",\n' "$OPENWRT_VERSION"
  printf '  "target": "%s",\n' "${TARGET:-unknown}"
  printf '  "profile": "%s",\n' "${PROFILE:-unknown}"
  printf '  "source": {"repo": "%s", "ref": "%s", "commit": "%s"},\n' "$SRC_REPO" "$SRC_REF" "$SRC_COMMIT"
  printf '  "config_sha256": "%s",\n' "${CONFIG_SHA:-none}"
  printf '  "lock_sha256": "%s",\n' "${LOCK_SHA:-none}"
  printf '  "artifact_count": %s,\n' "$COUNT"
  printf '  "total_bytes": %s,\n' "$TOTAL"
  printf '  "artifacts": ['
  printf '%s' "${JSON_ITEMS[@]}"
  printf '\n  ]\n}\n'
} > "$OUT/build-info.json"

human() { awk -v b="$1" 'BEGIN{split("B KB MB GB",u," ");i=1;while(b>=1024&&i<4){b/=1024;i++};printf "%.1f %s",b,u[i]}'; }
printf '[hash-artifacts] %s 个产物，共 %s\n' "$COUNT" "$(human "$TOTAL")"
printf '  %s/SHA256SUMS\n  %s/BOM.txt\n  %s/build-info.json\n' "$OUT" "$OUT" "$OUT"
