#!/usr/bin/env bash
#
# gen-config.sh — 由 features.md 生成 .config 片段 / clone 清单 / feed 清单
#
# features.md 是 Markdown 表格：带 6 列表头的表格被解析，其余内容（标题、说明、
# 其他列数的表格）一律忽略。所以这个文件既是数据源也是给人看的文档。
#
# 用法：
#   scripts/gen-config.sh --features configs/features.md --out openwrt/.config.fragment
#   scripts/gen-config.sh --features configs/features.md --list-clones    # dest<TAB>url
#   scripts/gen-config.sh --features configs/features.md --list-gitdirs    # dest<TAB>url<TAB>ref<TAB>subdir
#   scripts/gen-config.sh --features configs/features.md --list-feeds       # name=url
#   scripts/gen-config.sh --features configs/features.md --list-required   # 启用行的包名（点名册自动派生）
#   scripts/gen-config.sh --features configs/features.md --check           # 只校验并汇总
#
# 退出码：0 成功 / 2 用法或数据错误
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FEATURES="$SCRIPT_DIR/../configs/features.md"
MODE="emit"
OUT=""

die() { printf '[gen-config] ERROR: %s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --features) [ $# -ge 2 ] || die "--features 需要参数"; FEATURES="$2"; shift 2 ;;
    --out)      [ $# -ge 2 ] || die "--out 需要参数";      OUT="$2";      shift 2 ;;
    --list-clones)   MODE="clones";   shift ;;
    --list-gitdirs)  MODE="gitdirs";  shift ;;
    --list-feeds)    MODE="feeds";    shift ;;
    --list-required) MODE="required"; shift ;;
    --check)         MODE="check";    shift ;;
    -h|--help) echo "用法: gen-config.sh [--features <features.md>] [--out <file>|--list-clones|--list-gitdirs|--list-feeds|--list-required|--check]"; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

[ -f "$FEATURES" ] || die "找不到 features 文件: $FEATURES"

# 原地去首尾空白（不 fork，Windows 上 $( ) 每次约 10ms）
trimv() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; TRIMV="$s"; }

declare -A SEEN=()
declare -A PKGS=()
declare -A FEED_URLS=()      # 声明过的 feed（不管启停）
declare -A FEED_NEEDED=()    # 启用的行引用到的 feed
DEV_EXTRA=""
CLONES=""
GITDIRS=""
ENABLED=0
DISABLED=0

in_table=0
lineno=0
while IFS= read -r raw || [ -n "$raw" ]; do
  lineno=$((lineno + 1))
  raw="${raw%$'\r'}"                    # 兼容 CRLF
  raw="${raw#$'\xef\xbb\xbf'}"          # 兼容 UTF-8 BOM
  trimv "$raw"
  line="$TRIMV"

  # 不是表格行：结束当前表格，继续找下一个表头
  case "$line" in
    '|'*) ;;
    *) in_table=0; continue ;;
  esac

  # 先把转义的 \| 换成占位符，切分后再还原，否则列数会被算错
  split_line="${line//\\|/$'\x01'}"
  body="${split_line#|}"
  case "$body" in *'|') body="${body%|}" ;; esac

  IFS='|' read -r -a cells <<< "$body"
  for i in "${!cells[@]}"; do
    trimv "${cells[$i]}"
    cells[$i]="${TRIMV//$'\x01'/|}"
  done
  ncols="${#cells[@]}"

  # 表头：6 列且首列是「名称」——从这一行开始进入数据区
  if [ "$ncols" -eq 6 ] && [ "${cells[0]}" = "名称" ] && [ "${cells[1]}" = "启用" ]; then
    in_table=1
    continue
  fi
  [ "$in_table" = 1 ] || continue       # 说明用的表格，跳过

  # 分隔行（| --- | --- | ...）：去掉 | : - 与空白后为空
  sep_rest="${line//[|:[:space:]-]/}"
  [ -n "$sep_rest" ] || continue

  if [ "$ncols" -ne 6 ]; then
    die "第 $lineno 行：数据行必须有 6 列，实际 $ncols 列（少写或多写了一个分隔符 |）"
  fi

  name="${cells[0]}"; en="${cells[1]}"; dev="${cells[2]}"
  pkgs="${cells[3]}"; repo="${cells[4]}"

  [ -n "$name" ] || die "第 $lineno 行：名称为空"
  [ -z "${SEEN[$name]:-}" ] || die "第 $lineno 行：功能名重复（$name）"
  SEEN["$name"]=1

  case "$en" in
    0) DISABLED=$((DISABLED + 1)); IS_ON=0 ;;
    1) ENABLED=$((ENABLED + 1));   IS_ON=1 ;;
    *) die "第 $lineno 行（$name）：启用列必须是 0 或 1，实际是 '$en'" ;;
  esac

  case "$dev" in
    0|1) ;;
    *) die "第 $lineno 行（$name）：设备附加包列必须是 0 或 1" ;;
  esac
  if [ "$IS_ON" = "1" ] && [ "$dev" = "1" ] && [ -z "$pkgs" ]; then
    die "第 $lineno 行（$name）：标记为设备附加包但包列表为空"
  fi

  if [ "$IS_ON" = "1" ]; then
    for p in $pkgs; do
      PKGS["$p"]=1
    done
    if [ "$dev" = "1" ]; then
      DEV_EXTRA="$DEV_EXTRA $pkgs"
    fi
  fi

  # 语法校验对启停行都做：关着的行写错了，等打开时才炸更难受
  for token in $repo; do
    case "$token" in
      git:*)
        url="${token#git:}"
        [ -n "$url" ] || die "第 $lineno 行（$name）：git: 后面没有 URL"
        if [ "$IS_ON" = "1" ]; then
          dest="$(basename "${url%.git}")"
          CLONES+="$dest"$'\t'"$url"$'\n'
        fi
        ;;
      gitdir:*)
        # 只取大仓里的一个子目录：gitdir:<url>#<分支>/<子目录>
        # 例：gitdir:https://github.com/immortalwrt/luci#master/applications/luci-app-autoreboot
        spec="${token#gitdir:}"
        case "$spec" in
          *'#'*'/'*) ;;
          *) die "第 $lineno 行（$name）：gitdir: 需写成 gitdir:<url>#<分支>/<子目录>" ;;
        esac
        url="${spec%%#*}"; rest="${spec#*#}"
        ref="${rest%%/*}"; subdir="${rest#*/}"
        [ -n "$url" ] && [ -n "$ref" ] && [ -n "$subdir" ] || \
          die "第 $lineno 行（$name）：gitdir: 的 URL / 分支 / 子目录都不能为空"
        case "$subdir" in
          /*|*'..'*) die "第 $lineno 行（$name）：gitdir: 子目录必须是仓库内相对路径" ;;
        esac
        if [ "$IS_ON" = "1" ]; then
          dest="$(basename "$subdir")"
          GITDIRS+="$dest"$'\t'"$url"$'\t'"$ref"$'\t'"$subdir"$'\n'
        fi
        ;;
      feed:*=*)
        spec="${token#feed:}"
        FEED_URLS["${spec%%=*}"]="${spec#*=}"
        if [ "$IS_ON" = "1" ]; then FEED_NEEDED["${spec%%=*}"]=1; fi
        ;;
      feed:*)
        if [ "$IS_ON" = "1" ]; then FEED_NEEDED["${token#feed:}"]=1; fi
        ;;
      *)
        die "第 $lineno 行（$name）：来源列的写法不认识：'$token'。可用的写法：git:网址、gitdir:网址#分支/子目录、feed:名字=网址"
        ;;
    esac
  done
done < "$FEATURES"

[ $((ENABLED + DISABLED)) -gt 0 ] || die "没有从 $FEATURES 读到任何功能行（需要 6 列表格，表头以「名称 | 启用」开头；如果这个文件从 Excel 另存过，竖线可能被改成了 Tab）"

# feed 完整性：被引用但没人声明 URL
for f in "${!FEED_NEEDED[@]}"; do
  [ -n "${FEED_URLS[$f]:-}" ] || die "软件源 '$f' 被用到但没有登记网址（写成 feed:$f=<网址>）"
done

case "$MODE" in
  clones)
    if [ -n "$CLONES" ]; then printf '%s' "$CLONES" | sort -u; fi
    exit 0
    ;;
  gitdirs)
    if [ -n "$GITDIRS" ]; then printf '%s' "$GITDIRS" | sort -u; fi
    exit 0
    ;;
  feeds)
    for f in $(printf '%s\n' "${!FEED_NEEDED[@]}" | sort); do
      printf '%s=%s\n' "$f" "${FEED_URLS[$f]}"
    done
    exit 0
    ;;
  required)
    # 点名册自动派生：只输出「启用行」的包名，排序去重。
    # 与开关表天然同步：把 1 改成 0，这里立刻少几行，不用再手改第二份清单。
    if [ "${#PKGS[@]}" -gt 0 ]; then
      printf '%s\n' "${!PKGS[@]}" | sort -u
    fi
    exit 0
    ;;
  check)
    printf '[gen-config] 功能项：启用 %d，关闭 %d，包 %d 个，设备附加包 %d 个\n' \
      "$ENABLED" "$DISABLED" "${#PKGS[@]}" "$(echo $DEV_EXTRA | wc -w | tr -d ' ')"
    printf '  git 源：%s 个\n' "$(printf '%s' "$CLONES" | grep -c . || true)"
    printf '  gitdir：%s 个\n' "$(printf '%s' "$GITDIRS" | grep -c . || true)"
    printf '  feed  ：%s 个\n' "${#FEED_NEEDED[@]}"
    printf '  自动派生点名册：%d 项（--list-required）\n' "${#PKGS[@]}"
    exit 0
    ;;
esac

# ---------- 生成 .config 片段 ----------
emit() {
  printf '# 由 gen-config.sh 从 features.md 生成 — 不要手改\n'
  printf '# 注意：本片段不含目标设备选择行（CONFIG_TARGET_* 那三行）。\n'
  printf '# 它们由流水线基线一次性写入；片段里再写一遍，第二次展开会报\n'
  printf '# "override: ... changes choice state"，把已选好的设备重置丢失，\n'
  printf '# 导致整台设备静默漂移成别的型号（2026-11 云构建实际发生过）。\n'
  # 官方 DEVICE_PACKAGES 由 include/image.mk 追加进镜像，不生成 CONFIG_PACKAGE_* 符号，
  # 因此编译前的 .config 校验看不见它们。这里显式选中同一组包：既保证 make 真编译
  # 无线底座，也让 required-packages.txt 的编译前校验有据可查（26.11 target 定义核对过）。
  printf '# ---- 无线底座（与目标设备绑定，不可关）----\n'
  printf 'CONFIG_PACKAGE_ipq-wifi-jdcloud_re-cs-02=y\n'
  printf 'CONFIG_PACKAGE_ath11k-firmware-qcn9074=y\n'
  printf 'CONFIG_PACKAGE_kmod-ath11k-pci=y\n'
  if [ -n "$DEV_EXTRA" ]; then
    local dev_sorted
    dev_sorted="$(echo $DEV_EXTRA | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//')"
    printf 'CONFIG_TARGET_DEVICE_PACKAGES_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02="%s"\n' "$dev_sorted"
  fi
  printf 'CONFIG_LUCI_LANG_zh_Hans=y\n'
  # 编译加速：ccache 会跳过已编译过的相同目标。CI 上由 actions/cache 持久化，
  # 本地构建需先装 ccache（apt install ccache），否则 make 会报找不到 ccache。
  printf 'CONFIG_CCACHE=y\n'

  printf '# ---- 包 ----\n'
  if [ "${#PKGS[@]}" -gt 0 ]; then
    for p in $(printf '%s\n' "${!PKGS[@]}" | sort); do
      printf 'CONFIG_PACKAGE_%s=y\n' "$p"
    done
  fi

  if [ -n "${PKGS[zram-swap]:-}" ]; then
    printf '# zram 内核选项（与 zram-swap 绑定）\n'
    printf 'CONFIG_KERNEL_ZRAM_BACKEND_LZ4=y\n'
    printf 'CONFIG_KERNEL_ZRAM_DEF_COMP_LZ4=y\n'
  fi

  printf '# ---- 明确不选（策略，非功能开关）----\n'
  printf '# CONFIG_PACKAGE_luci-app-oaf is not set\n'
  printf '# CONFIG_PACKAGE_luci-app-appfilter is not set\n'
  printf '# CONFIG_PACKAGE_luci-app-sqm is not set\n'
  printf '# CONFIG_PACKAGE_sqm-scripts-nss is not set\n'
  printf '# CONFIG_NSS_FIRMWARE_VERSION_12_5 is not set\n'
  printf '# CONFIG_TESTING_KERNEL is not set\n'
}

if [ -n "$OUT" ]; then
  mkdir -p "$(dirname "$OUT")"
  emit > "$OUT"
  printf '[gen-config] 写入 %s（%d 个包，%d 个设备附加包）\n' "$OUT" "${#PKGS[@]}" "$(echo $DEV_EXTRA | wc -w | tr -d ' ')"
else
  emit
fi
