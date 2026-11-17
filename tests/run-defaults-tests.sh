#!/usr/bin/env bash
#
# run-defaults-tests.sh — 首启脚本 files/etc/uci-defaults/99-athena-custom-settings 的回归测试
#
# 做法：把 uci / wifi / logger / passwd 打成桩放进临时 PATH，
# 用一份"三射频（2g + 5g + 5g）"的假 wireless 配置跑真脚本，检查最终写进去的值。
#
# 桩的存档方式：整份配置一个文件，只追加不重写、纯 shell 解析（后写覆盖先写）。
# 不调 awk / mv —— 这两样在 Windows 上反复覆盖同一文件时会被文件监控卡死。
#
# 用法：bash tests/run-defaults-tests.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
SCRIPT="$KIT/files/etc/uci-defaults/99-athena-custom-settings"
SH="${SH:-sh}"

# 固定 POSIX 路径：mktemp -d 在 Windows 上返回 C:\... 反斜杠路径，塞进 PATH 找不到桩
WORK="/tmp/athena-defaults.$$"
BIN="$WORK/bin"
mkdir -p "$BIN" || { echo "无法创建临时目录 $BIN" >&2; exit 2; }

PASS=0
FAIL=0
RC=0

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s%s\n' "$1" "${2:+（$2）}"; FAIL=$((FAIL+1)); }

expect_eq() { # desc want got
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2] got [$3]"; fi
}

# ── 桩：uci（单文件、追加式，后写覆盖先写）──
cat > "$BIN/uci" <<'STUB'
#!/bin/sh
DB="${UCI_DB:?}"
[ -f "$DB" ] || : > "$DB"
quiet=0
if [ "$1" = "-q" ]; then quiet=1; shift; fi
cmd="$1"; shift
key_of() { printf '%s' "$1" | tr -d '[]'; }
getv() {
  v=""
  while IFS= read -r line; do
    case "$line" in
      "$1="*) v="${line#*=}" ;;
    esac
  done < "$DB"
  printf '%s' "$v"
}
case "$cmd" in
  get)
    k="$(key_of "$1")"
    v="$(getv "$k")"
    if [ -z "$v" ]; then
      [ "$quiet" = 1 ] || echo "uci: Entry not found" >&2
      exit 1
    fi
    printf '%s\n' "$v"
    ;;
  set)
    k="$(key_of "${1%%=*}")"
    printf '%s=%s\n' "$k" "${1#*=}" >> "$DB"
    ;;
  delete)
    k="$(key_of "$1")"
    printf '%s=\n' "$k" >> "$DB"
    ;;
  commit|batch|reorder|add|rename) : ;;
  show) cat "$DB" ;;
  *) : ;;
esac
exit 0
STUB

# ── 桩：wifi / logger / passwd ──
printf '#!/bin/sh\nexit 0\n' > "$BIN/wifi"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "${LOG_FILE:-/dev/null}"\nexit 0\n' > "$BIN/logger"
printf '#!/bin/sh\ncat > /dev/null 2>&1\nexit 0\n' > "$BIN/passwd"
chmod +x "$BIN/uci" "$BIN/wifi" "$BIN/logger" "$BIN/passwd"

# 假设备：radio0=2.4G，radio1/radio2=5G，三个 AP 接口
seed_wireless() { # <db>
  local i
  : > "$1"
  for i in 0 1 2; do
    printf 'wireless.radio%s=wifi-device\n' "$i"       >> "$1"
    printf 'wireless.@wifi-iface%s=wifi-iface\n' "$i"  >> "$1"
    printf 'wireless.@wifi-iface%s.device=radio%s\n' "$i" "$i" >> "$1"
    printf 'wireless.@wifi-iface%s.mode=ap\n' "$i"     >> "$1"
    printf 'wireless.@wifi-iface%s.ssid=OpenWrt\n' "$i" >> "$1"
  done
  printf 'wireless.radio0.band=2g\n' >> "$1"
  printf 'wireless.radio1.band=5g\n' >> "$1"
  printf 'wireless.radio2.band=5g\n' >> "$1"
  # 另挂一个 sta（中继/上游）接口：这类接口不该被改名、更不该被塞入本机 AP 密码
  printf 'wireless.@wifi-iface3=wifi-iface\n'        >> "$1"
  printf 'wireless.@wifi-iface3.device=radio1\n'     >> "$1"
  printf 'wireless.@wifi-iface3.mode=sta\n'          >> "$1"
  printf 'wireless.@wifi-iface3.ssid=UpstreamWiFi\n' >> "$1"
}

get_db() { # <db> <key> —— 与桩一致：后写覆盖先写
  local v="" val
  while IFS= read -r val; do
    case "$val" in
      "$2="*) v="${val#*=}" ;;
    esac
  done < "$1"
  printf '%s' "$v"
}

# run_defaults <tag> <ssid2g> <ssid5g> <pass> [skip5g]
#   skip5g 非空时保留 __MY_WIFI_SSID_5G__ 占位符，模拟该 Secret 没配
run_defaults() {
  local tag="$1" s2="$2" s5="$3" pw="$4" skip="${5:-}"
  local root="$WORK/$tag"
  mkdir -p "$root"
  if [ -n "$skip" ]; then
    sed -e "s|__MY_WIFI_SSID_2G__|$s2|g" \
        -e "s|__MY_WIFI_PASSWORD__|$pw|g" "$SCRIPT" > "$root/script"
  else
    sed -e "s|__MY_WIFI_SSID_2G__|$s2|g" \
        -e "s|__MY_WIFI_SSID_5G__|$s5|g" \
        -e "s|__MY_WIFI_PASSWORD__|$pw|g" "$SCRIPT" > "$root/script"
  fi
  export UCI_DB="$root/uci"
  export LOG_FILE="$root/log.txt"
  : > "$LOG_FILE"
  seed_wireless "$UCI_DB"
  PATH="$BIN:$PATH" $SH "$root/script" > /dev/null 2>&1 < /dev/null
  RC=$?
}

# ══ t1 正常值：2G 与两台 5G 各自写对 ══
echo "== t1 正常 Secret：2G 独立名、双 5G 同名、密码一致 =="
run_defaults t1 "Athena_2G" "Athena_5G" "Passw0rd123"
DB="$WORK/t1/uci"
expect_eq "退出码 0" 0 "$RC"
expect_eq "2G 写入正式名" "Athena_2G" "$(get_db "$DB" wireless.@wifi-iface0.ssid)"
expect_eq "5G#1 写入正式名" "Athena_5G" "$(get_db "$DB" wireless.@wifi-iface1.ssid)"
expect_eq "5G#2 写入正式名" "Athena_5G" "$(get_db "$DB" wireless.@wifi-iface2.ssid)"
expect_eq "密码写入 5G#1" "Passw0rd123" "$(get_db "$DB" wireless.@wifi-iface1.key)"
expect_eq "加密方式 psk2" "psk2" "$(get_db "$DB" wireless.@wifi-iface1.encryption)"
expect_eq "2.4G 信道 11" 11 "$(get_db "$DB" wireless.radio0.channel)"
expect_eq "5G 信道 auto" auto "$(get_db "$DB" wireless.radio1.channel)"
if grep -q "Athena_2G" "$WORK/t1/log.txt" && grep -q "Athena_5G" "$WORK/t1/log.txt"; then
  ok "首启日志记下写入的 SSID（便于事后追溯）"
else
  bad "首启日志记下写入的 SSID（便于事后追溯）" "$(cat "$WORK/t1/log.txt")"
fi

# ══ t2 核心回归：密码粘到 WIFI_SSID_5G 这一格 ══
echo "== t2 密码粘错格（SSID_5G == WIFI_PASSWORD）→ 必须回退，不能广播密码 =="
run_defaults t2 "Athena_2G" "Passw0rd123" "Passw0rd123"
DB="$WORK/t2/uci"
expect_eq "5G#1 未把密码当信号名" "Athena_5G" "$(get_db "$DB" wireless.@wifi-iface1.ssid)"
expect_eq "5G#2 未把密码当信号名" "Athena_5G" "$(get_db "$DB" wireless.@wifi-iface2.ssid)"
expect_eq "密码仍然正确写入" "Passw0rd123" "$(get_db "$DB" wireless.@wifi-iface1.key)"
expect_eq "2G 不受影响" "Athena_2G" "$(get_db "$DB" wireless.@wifi-iface0.ssid)"
if grep -q "SSID 与 WiFi 密码相同" "$WORK/t2/log.txt"; then
  ok "留下「SSID 与密码相同」告警日志"
else
  bad "留下「SSID 与密码相同」告警日志" "$(cat "$WORK/t2/log.txt")"
fi

# ══ t3 2G 也不许被密码污染 ══
echo "== t3 密码粘到 WIFI_SSID_2G → 同样回退 =="
run_defaults t3 "Passw0rd123" "Athena_5G" "Passw0rd123"
DB="$WORK/t3/uci"
expect_eq "2G 未把密码当信号名" "Athena" "$(get_db "$DB" wireless.@wifi-iface0.ssid)"
expect_eq "5G 正常" "Athena_5G" "$(get_db "$DB" wireless.@wifi-iface1.ssid)"

# ══ t4 Secret 没配：保持占位符 → 一个都不许写 ══
echo "== t4 WIFI_SSID_5G 未配置（保留占位符）→ 不得把 __MY_* 写进配置 =="
run_defaults t4 "Athena_2G" "" "Passw0rd123" skip5g
DB="$WORK/t4/uci"
expect_eq "5G#1 保持固件默认" "OpenWrt" "$(get_db "$DB" wireless.@wifi-iface1.ssid)"
expect_eq "5G#2 保持固件默认" "OpenWrt" "$(get_db "$DB" wireless.@wifi-iface2.ssid)"
expect_eq "2G 仍按配置写入" "Athena_2G" "$(get_db "$DB" wireless.@wifi-iface0.ssid)"

# ══ t5 超长 SSID → 截断到 32 字节 ══
echo "== t5 SSID 超过 32 字节 → 截断 =="
run_defaults t5 "Athena_2G" "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" "Passw0rd123"
DB="$WORK/t5/uci"
expect_eq "截断到 32 字节" "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345" \
  "$(get_db "$DB" wireless.@wifi-iface1.ssid)"

# ══ t6 非 AP 接口（sta 中继）不被动：直接复查 t1 那一轮的结果 ══
echo "== t6 mode=sta 的接口不被改名改密码 =="
DB="$WORK/t1/uci"
expect_eq "sta 接口信号名保持不变" "UpstreamWiFi" "$(get_db "$DB" wireless.@wifi-iface3.ssid)"
if [ -z "$(get_db "$DB" wireless.@wifi-iface3.key)" ]; then
  ok "sta 接口没有被塞入 AP 密码"
else
  bad "sta 接口没有被塞入 AP 密码" "key=$(get_db "$DB" wireless.@wifi-iface3.key)"
fi

# ══ t7 兜底命令必须是 wifi config ══
echo "== t7 兜底命令必须是 wifi config（wifi detect 自 23.05 起已废弃） =="
CODE_ONLY="$(grep -vE '^[[:space:]]*#' "$SCRIPT")"
case "$CODE_ONLY" in
  *"wifi config"*) ok "脚本用 wifi config 兜底" ;;
  *) bad "脚本用 wifi config 兜底" "没有 wifi config" ;;
esac
case "$CODE_ONLY" in
  *"wifi detect"*) bad "代码里不再调用 wifi detect" "注释可以提，代码不能调" ;;
  *) ok "代码里不再调用 wifi detect" ;;
esac

echo
printf '结果: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
