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
  add_list)
    # 只用于 nginx._lan.listen：按真实 uci 的列表语义追加，用 | 连接多个值
    k="$(key_of "${1%%=*}")"
    v="$(getv "$k")"
    if [ -n "$v" ]; then
      printf '%s=%s|%s\n' "$k" "$v" "${1#*=}" >> "$DB"
    else
      printf '%s=%s\n' "$k" "${1#*=}" >> "$DB"
    fi
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

# ── 桩：wifi / logger / passwd / nginx ──
printf '#!/bin/sh\nexit 0\n' > "$BIN/wifi"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "${LOG_FILE:-/dev/null}"\nexit 0\n' > "$BIN/logger"
printf '#!/bin/sh\ncat > /dev/null 2>&1\nexit 0\n' > "$BIN/passwd"
printf '#!/bin/sh\nexit 0\n' > "$BIN/nginx-ok"
printf '#!/bin/sh\nexit 1\n' > "$BIN/nginx-bad"
chmod +x "$BIN/uci" "$BIN/wifi" "$BIN/logger" "$BIN/passwd" "$BIN/nginx-ok" "$BIN/nginx-bad"

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

# 假设备：nginx 默认配置 —— _lan 双栈监听 443，_redirect2ssl 占着 80 做跳转。
# 列表值用 | 连接（与桩的 add_list 一致），这样"443 有没有被覆盖掉"测得出来。
seed_nginx() { # <db>
  printf 'nginx._lan=server\n'                                      >> "$1"
  printf 'nginx._lan.listen=443 ssl default_server|[::]:443 ssl default_server\n' >> "$1"
  printf 'nginx._redirect2ssl=server\n'                             >> "$1"
  printf 'nginx._redirect2ssl.listen=80|[::]:80\n'                  >> "$1"
}

# 假设备：LuCI 的 nginx location 文件 —— 反代被 302 到 http://域名/cgi-bin/luci/ 的现场
# 只在文件不存在时铺一份，便于同一 tag 重复执行验证幂等。
seed_locations() { # <path>
  [ -f "$1" ] && return 0
  cat > "$1" <<'LOC'
location = / {
		return 302 /cgi-bin/luci/;
}
location /cgi-bin/luci {
		index  index.html;
		include uwsgi_params;
		uwsgi_modifier1 9;
		uwsgi_pass unix:////var/run/luci-webui.socket;
}
LOC
}

# 假设备：主题的 header.ut —— 标签标题被写死成 FanchmWrt 的现场
# 同样只在文件不存在时铺一份，便于同一 tag 重复执行验证幂等。
seed_header() { # <path>
  [ -f "$1" ] && return 0
  if [ -n "${HEADER_SEED_BYTECODE:-}" ]; then
    # 模拟 CONFIG_LUCI_UTMIN=y 的产物：ucode 字节码，首字节不是 '<'
    printf '\033uc\000\002\000\000<title>FanchmWrt</title>\n' > "$1"
    return 0
  fi
  cat > "$1" <<'HDR'
<!DOCTYPE html>
<html lang="zh-cn">
	<head>
		<meta charset="utf-8">
		<title>FanchmWrt</title>
	</head>
	<body></body>
</html>
HDR
}

# run_defaults <tag> <ssid2g> <ssid5g> <pass> [skip5g] [marker]
#   skip5g 非空时保留 __MY_WIFI_SSID_5G__ 占位符，模拟该 Secret 没配
#   marker 覆盖标记文件路径（t23 用它模拟「写不进去」；默认写本 tag 的临时目录）
run_defaults() {
  local tag="$1" s2="$2" s5="$3" pw="$4" skip="${5:-}"
  local root="$WORK/$tag"
  # 升级保护：标记必须指到本 tag 的临时目录，否则会往真实的 /etc/config/athena 写。
  # FORCE 默认 1，让 t1-t17 保持「每次都真执行」的语义（幂等测的是重复执行，
  # 不是「第二次直接跳过」）；升级保护本身另由 t18-t21 覆盖。
  # 用局部变量而不是 export：export 会把第一次的路径钉死成全局值，
  # 后面的 tag 全部写到第一个目录去（踩过）。
  local marker="${6:-$root/athena}"
  local force="${ATHENA_FIRSTBOOT_FORCE:-1}"
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
  # nginx 段：给一个真实存在的空文件当 /etc/config/nginx，让脚本走 nginx 分支
  seed_nginx "$UCI_DB"
  export ATHENA_NGINX_UCI="$root/nginx"
  : > "$ATHENA_NGINX_UCI"
  # 相对重定向段：location 文件 + nginx 桩（-t 校验）都可控
  export ATHENA_NGINX_LOCATIONS="$root/luci.locations"
  seed_locations "$ATHENA_NGINX_LOCATIONS"
  export ATHENA_NGINX_BIN="${ATHENA_TEST_NGINX_BIN:-$BIN/nginx-ok}"
  export ATHENA_NGINX_CONF="$root/nginx.conf"
  : > "$ATHENA_NGINX_CONF"
  # 标签标题段：header.ut 也给一份假的
  export ATHENA_LUCI_HEADER="$root/header.ut"
  seed_header "$ATHENA_LUCI_HEADER"
  ATHENA_FIRSTBOOT_MARKER="$marker" ATHENA_FIRSTBOOT_FORCE="$force" \
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

# ══ t8 nginx：关掉 80 → 443 强制跳转，但 443 不能被覆盖 ══
echo "== t8 nginx 直连 HTTP：_lan 加 80、_redirect2ssl 删除 =="
DB="$WORK/t1/uci"
NGINX_80="$(get_db "$DB" nginx._lan.listen)"
expect_eq "只做跳转的 _redirect2ssl 已被删除" "" "$(get_db "$DB" nginx._redirect2ssl)"
case "$NGINX_80" in
  *"80 default_server"*) ok "_lan 增加 80 default_server" ;;
  *) bad "_lan 增加 80 default_server" "listen=$NGINX_80" ;;
esac
case "$NGINX_80" in
  *"443 ssl default_server"*) ok "443 监听未被 add_list 覆盖（用 set 会丢网页）" ;;
  *) bad "443 监听未被 add_list 覆盖（用 set 会丢网页）" "listen=$NGINX_80" ;;
esac
case "$NGINX_80" in
  *"[::]:80 default_server"*) ok "IPv6 环境同时补 [::]:80" ;;
  *) bad "IPv6 环境同时补 [::]:80" "listen=$NGINX_80" ;;
esac

# ══ t9 没有 nginx 配置时，不能凭空写 nginx 段 ══
echo "== t9 固件里没有 /etc/config/nginx → 不碰 nginx =="
root="$WORK/t9"
mkdir -p "$root"
sed -e "s|__MY_WIFI_SSID_2G__|Athena_2G|g" \
    -e "s|__MY_WIFI_SSID_5G__|Athena_5G|g" \
    -e "s|__MY_WIFI_PASSWORD__|Passw0rd123|g" "$SCRIPT" > "$root/script"
export UCI_DB="$root/uci"
export LOG_FILE="$root/log.txt"
: > "$LOG_FILE"
seed_wireless "$UCI_DB"
seed_nginx "$UCI_DB"
ATHENA_NGINX_UCI="$root/no-such-nginx" \
ATHENA_NGINX_LOCATIONS="$root/no-such-locations" \
ATHENA_NGINX_BIN="$BIN/nginx-ok" \
ATHENA_LUCI_HEADER="$root/no-such-header" \
ATHENA_FIRSTBOOT_MARKER="$root/athena" \
ATHENA_FIRSTBOOT_FORCE=1 \
  PATH="$BIN:$PATH" $SH "$root/script" > /dev/null 2>&1 < /dev/null
DB="$UCI_DB"
expect_eq "没有配置文件时不写 listen" \
  "443 ssl default_server|[::]:443 ssl default_server" "$(get_db "$DB" nginx._lan.listen)"
expect_eq "没有配置文件时不删 _redirect2ssl" "server" "$(get_db "$DB" nginx._redirect2ssl)"

# ══ t10 nginx 相对重定向：反代访问保留 scheme 与端口 ══
echo "== t10 nginx 相对重定向：location 文件首行插入 absolute_redirect off =="
LOC_FILE="$WORK/t1/luci.locations"
expect_eq "首行是 absolute_redirect off" "absolute_redirect off;" "$(head -n 1 "$LOC_FILE")"
if grep -q 'location = / {' "$LOC_FILE"; then
  ok "原有 location 块未被破坏"
else
  bad "原有 location 块未被破坏" "$(cat "$LOC_FILE")"
fi
if grep -q 'return 302 /cgi-bin/luci/;' "$LOC_FILE"; then
  ok "302 目标仍是相对路径 /cgi-bin/luci/"
else
  bad "302 目标仍是相对路径 /cgi-bin/luci/"
fi
if grep -q 'nginx 重定向已改为相对路径' "$WORK/t1/log.txt"; then
  ok "留下改动成功日志"
else
  bad "留下改动成功日志" "$(cat "$WORK/t1/log.txt")"
fi

# ══ t11 幂等：同一份文件重复执行不叠加 ══
echo "== t11 重复执行不重复插入 =="
run_defaults t11 "Athena_2G" "Athena_5G" "Passw0rd123"
run_defaults t11 "Athena_2G" "Athena_5G" "Passw0rd123"
CNT="$(grep -c 'absolute_redirect off' "$WORK/t11/luci.locations")"
expect_eq "文件里只有一条 absolute_redirect off" 1 "$CNT"

# ══ t12 开关关闭：一行都不许动 ══
echo "== t12 ATHENA_NGINX_REL_REDIRECT=0 → 不动 location 文件 =="
ATHENA_NGINX_REL_REDIRECT=0 run_defaults t12 "Athena_2G" "Athena_5G" "Passw0rd123"
if grep -q 'absolute_redirect' "$WORK/t12/luci.locations"; then
  bad "开关关闭时不插入" "$(head -n 1 "$WORK/t12/luci.locations")"
else
  ok "开关关闭时不插入"
fi

# ══ t13 校验失败：必须回滚，不能留下打不开网页的配置 ══
echo "== t13 nginx -t 失败 → 回滚，文件保持原样 =="
ATHENA_TEST_NGINX_BIN="$BIN/nginx-bad" run_defaults t13 "Athena_2G" "Athena_5G" "Passw0rd123"
if grep -q 'absolute_redirect' "$WORK/t13/luci.locations"; then
  bad "校验失败时回滚" "$(head -n 1 "$WORK/t13/luci.locations")"
else
  ok "校验失败时回滚"
fi
expect_eq "回滚后首行仍是原 location 块" "location = / {" "$(head -n 1 "$WORK/t13/luci.locations")"
if grep -q '未通过校验，已回滚' "$WORK/t13/log.txt"; then
  ok "留下回滚日志"
else
  bad "留下回滚日志" "$(cat "$WORK/t13/log.txt")"
fi

# ══ t14 标签标题：从写死的 FanchmWrt 改为跟随 hostname ══
echo "== t14 标签标题改为跟随 hostname（默认 Athena） =="
HDR_FILE="$WORK/t1/header.ut"
if grep -q "boardinfo.hostname ?? 'Athena'" "$HDR_FILE"; then
  ok "title 改为读 boardinfo.hostname"
else
  bad "title 改为读 boardinfo.hostname" "$(grep -i '<title>' "$HDR_FILE")"
fi
if grep -q '<title>FanchmWrt</title>' "$HDR_FILE"; then
  bad "写死的 FanchmWrt 已被替换" "$(grep -i '<title>' "$HDR_FILE")"
else
  ok "写死的 FanchmWrt 已被替换"
fi
if grep -q 'lang="zh-cn"' "$HDR_FILE"; then
  ok "文件其余内容未被破坏"
else
  bad "文件其余内容未被破坏"
fi
if grep -q '浏览器标签标题已改为跟随主机名' "$WORK/t1/log.txt"; then
  ok "留下标题改动日志"
else
  bad "留下标题改动日志" "$(cat "$WORK/t1/log.txt")"
fi

# ══ t15 幂等：重复执行不重复替换 ══
echo "== t15 标签标题改动幂等 =="
run_defaults t15 "Athena_2G" "Athena_5G" "Passw0rd123"
run_defaults t15 "Athena_2G" "Athena_5G" "Passw0rd123"
TITLE_CNT="$(grep -c 'boardinfo.hostname' "$WORK/t15/header.ut")"
expect_eq "文件里只有一处 hostname 标题" 1 "$TITLE_CNT"

# ══ t16 开关关闭：标签保持原样 ══
echo "== t16 ATHENA_LUCI_TITLE_HOSTNAME=0 → 不动 header.ut =="
ATHENA_LUCI_TITLE_HOSTNAME=0 run_defaults t16 "Athena_2G" "Athena_5G" "Passw0rd123"
if grep -q '<title>FanchmWrt</title>' "$WORK/t16/header.ut"; then
  ok "开关关闭时标题保持原样"
else
  bad "开关关闭时标题保持原样" "$(grep -i '<title>' "$WORK/t16/header.ut")"
fi

# ══ t17 预编译字节码：一个字节都不许动 ══
echo "== t17 header.ut 是 ucode 字节码 → 跳过，不破坏模板 =="
HEADER_SEED_BYTECODE=1 run_defaults t17 "Athena_2G" "Athena_5G" "Passw0rd123"
HDR_FILE="$WORK/t17/header.ut"
if head -c 1 "$HDR_FILE" | od -An -c | grep -q '033'; then
  ok "字节码文件首字节未被改成 '<'"
else
  bad "字节码文件首字节未被改成 '<'" "$(head -c 4 "$HDR_FILE" | od -An -c)"
fi
if grep -q '预编译字节码' "$WORK/t17/log.txt"; then
  ok "留下字节码跳过日志"
else
  bad "留下字节码跳过日志" "$(cat "$WORK/t17/log.txt")"
fi

# ══ t18 首次执行：写入升级保护标记 ══
echo "== t18 首次执行写入 /etc/config/athena 标记 =="
run_defaults t18 "Athena_2G" "Athena_5G" "Passw0rd123"
MARK18="$WORK/t18/athena"
if [ -f "$MARK18" ]; then ok "标记文件已生成"; else bad "标记文件未生成"; fi
if grep -q "config athena 'firstboot'" "$MARK18" 2>/dev/null; then
  ok "标记是合法的 UCI 段"
else
  bad "标记是合法的 UCI 段" "$(cat "$MARK18" 2>/dev/null)"
fi
if grep -q "option applied '1'" "$MARK18" 2>/dev/null; then
  ok "标记记录了 applied=1"
else
  bad "标记记录了 applied=1" "$(cat "$MARK18" 2>/dev/null)"
fi
if grep -q '已写入升级保护标记' "$WORK/t18/log.txt"; then
  ok "留下写入标记日志"
else
  bad "留下写入标记日志" "$(cat "$WORK/t18/log.txt")"
fi

# ══ t19 标记存在：整体跳过，一个配置都不许动 ══
# 手工铺「用户已经配好的现场」，模拟保留配置升级后配置已还原的样子。
echo "== t19 标记存在 → 跳过，不覆盖用户配置 =="
root="$WORK/t19"
mkdir -p "$root"
sed -e "s|__MY_WIFI_SSID_2G__|Athena_2G|g" \
    -e "s|__MY_WIFI_SSID_5G__|Athena_5G|g" \
    -e "s|__MY_WIFI_PASSWORD__|Passw0rd123|g" "$SCRIPT" > "$root/script"
# 用户自建的配置：SSID 改过、LAN 换过网段、还加了一条静态租约
: > "$root/uci"
printf 'wireless.radio0=wifi-device\n' >> "$root/uci"
printf 'wireless.@wifi-iface0=wifi-iface\n' >> "$root/uci"
printf 'wireless.@wifi-iface0.device=radio0\n' >> "$root/uci"
printf 'wireless.@wifi-iface0.mode=ap\n' >> "$root/uci"
printf 'wireless.@wifi-iface0.ssid=MyHomeWiFi\n' >> "$root/uci"
printf 'wireless.radio0.band=2g\n' >> "$root/uci"
printf 'network.lan.ipaddr=192.168.9.1\n' >> "$root/uci"
printf 'dhcp.@host[0].name=nas\n' >> "$root/uci"
# 标记已存在（上一次首启写的）
printf "config athena 'firstboot'\n\toption applied '1'\n" > "$root/athena"
UCI_DB="$root/uci" LOG_FILE="$root/log.txt" \
ATHENA_FIRSTBOOT_MARKER="$root/athena" ATHENA_FIRSTBOOT_FORCE=0 \
ATHENA_NGINX_UCI="$root/nginx" ATHENA_NGINX_LOCATIONS="$root/luci.locations" \
ATHENA_NGINX_BIN="$BIN/nginx-ok" ATHENA_LUCI_HEADER="$root/header.ut" \
  PATH="$BIN:$PATH" $SH "$root/script" > /dev/null 2>&1 < /dev/null
DB="$root/uci"
expect_eq "用户 SSID 未被覆盖" "MyHomeWiFi" "$(get_db "$DB" wireless.@wifi-iface0.ssid)"
expect_eq "用户 LAN 网段未被覆盖" "192.168.9.1" "$(get_db "$DB" network.lan.ipaddr)"
expect_eq "静态租约未被冲掉" "nas" "$(get_db "$DB" dhcp.@host[0].name)"
expect_eq "没有写入主机名默认值" "" "$(get_db "$DB" system.@system0.hostname)"
expect_eq "没有写 nginx 的 80 监听" "" "$(get_db "$DB" nginx._lan.listen)"
if [ -f "$root/luci.locations" ]; then
  bad "跳过时不动 nginx location 文件"
else
  ok "跳过时不动 nginx location 文件"
fi
if [ -f "$root/header.ut" ]; then
  bad "跳过时不动 header.ut"
else
  ok "跳过时不动 header.ut"
fi
if grep -q '判定为保留配置升级，跳过默认值写入' "$root/log.txt"; then
  ok "日志说明跳过原因"
else
  bad "日志说明跳过原因" "$(cat "$root/log.txt")"
fi

# ══ t20 FORCE=1：标记存在也强制重跑 ══
echo "== t20 ATHENA_FIRSTBOOT_FORCE=1 → 标记存在也强制执行 =="
root="$WORK/t20"
mkdir -p "$root"
sed -e "s|__MY_WIFI_SSID_2G__|Athena_2G|g" \
    -e "s|__MY_WIFI_SSID_5G__|Athena_5G|g" \
    -e "s|__MY_WIFI_PASSWORD__|Passw0rd123|g" "$SCRIPT" > "$root/script"
: > "$root/uci"
printf 'wireless.radio0=wifi-device\n' >> "$root/uci"
printf 'wireless.@wifi-iface0=wifi-iface\n' >> "$root/uci"
printf 'wireless.@wifi-iface0.device=radio0\n' >> "$root/uci"
printf 'wireless.@wifi-iface0.mode=ap\n' >> "$root/uci"
printf 'wireless.@wifi-iface0.ssid=MyHomeWiFi\n' >> "$root/uci"
printf 'wireless.radio0.band=2g\n' >> "$root/uci"
printf 'network.lan.ipaddr=192.168.9.1\n' >> "$root/uci"
printf "config athena 'firstboot'\n\toption applied '1'\n" > "$root/athena"
UCI_DB="$root/uci" LOG_FILE="$root/log.txt" \
ATHENA_FIRSTBOOT_MARKER="$root/athena" ATHENA_FIRSTBOOT_FORCE=1 \
ATHENA_NGINX_UCI="$root/no-nginx" ATHENA_NGINX_LOCATIONS="$root/no-loc" \
ATHENA_NGINX_BIN="$BIN/nginx-ok" ATHENA_LUCI_HEADER="$root/no-hdr" \
  PATH="$BIN:$PATH" $SH "$root/script" > /dev/null 2>&1 < /dev/null
DB="$root/uci"
expect_eq "强制模式下 SSID 按默认值重写" "Athena_2G" "$(get_db "$DB" wireless.@wifi-iface0.ssid)"
expect_eq "强制模式下 LAN 按默认值重写" "10.0.0.1" "$(get_db "$DB" network.lan.ipaddr)"
expect_eq "强制模式下主机名写成 Athena" "Athena" "$(get_db "$DB" system.@system0.hostname)"

# ══ t21 静态检查：默认标记必须落在 /etc/config 下 ══
echo "== t21 标记默认路径必须在 /etc/config（才会随备份保留） =="
if grep -q 'ATHENA_FIRSTBOOT_MARKER:-/etc/config/athena' "$SCRIPT"; then
  ok "默认标记是 /etc/config/athena"
else
  bad "默认标记是 /etc/config/athena" "$(grep -n 'ATHENA_FIRSTBOOT_MARKER' "$SCRIPT")"
fi
if grep -q 'ATHENA_FIRSTBOOT_FORCE' "$SCRIPT"; then
  ok "提供强制重跑开关"
else
  bad "提供强制重跑开关"
fi

# ══ t22 静态检查：标记必须在改配置之前写入 ══
# 2026-11-19 实机踩到：镜像里有本脚本、脚本也确实跑过（/etc/uci-defaults 已空），
# 但 /etc/config/athena 从未生成，升级保护等于没装。原因是写入放在末尾，任何一段
# 提前结束都会漏掉它，而 uci-defaults 本来就不重跑。改成开头写以后钉死这个顺序。
echo "== t22 标记写入必须早于第一个配置改动 =="
MK_LINE="$(grep -n '^write_marker$' "$SCRIPT" | head -1 | cut -d: -f1)"
UCI_LINE="$(grep -n '^uci set ' "$SCRIPT" | head -1 | cut -d: -f1)"
if [ -n "$MK_LINE" ] && [ -n "$UCI_LINE" ] && [ "$MK_LINE" -lt "$UCI_LINE" ]; then
  ok "write_marker 在第 $MK_LINE 行，早于首个 uci set（第 $UCI_LINE 行）"
else
  bad "标记写入位置不对" "write_marker=${MK_LINE:-无} uci_set=${UCI_LINE:-无}"
fi

# ══ t23 标记写不进去：不中断，但要留 err 日志 ══
# 写不进去意味着这台机器下次「保留配置」升级会被默认值全覆盖，必须显眼。
echo "== t23 标记写入失败：不中断，留 err 日志 =="
mkdir -p "$WORK/t23"
: > "$WORK/t23/blocker"    # 用普通文件占位，让 mkdir -p 与重定向都失败
run_defaults t23 "Athena_2G" "Athena_5G" "Passw0rd123" "" "$WORK/t23/blocker/athena"
if [ "$RC" = "0" ]; then ok "写入失败不影响后续执行"; else bad "脚本异常退出" "rc=$RC"; fi
if grep -q '写入升级保护标记失败' "$WORK/t23/log.txt" 2>/dev/null; then
  ok "留下写入失败日志"
else
  bad "留下写入失败日志" "$(cat "$WORK/t23/log.txt" 2>/dev/null)"
fi
# 即使标记没写进去，配置本身仍应照常应用
expect_eq "配置仍然被应用" "Athena_2G" "$(get_db "$WORK/t23/uci" wireless.@wifi-iface0.ssid)"

echo "== t24 rpcd 执行超时放宽到 180 秒 =="
if grep -q "rpcd.@rpcd\[0\].timeout='180'" "$SCRIPT"; then
  ok "rpcd 超时设为 180 秒（网页升级大备份不会被 30s 杀掉）"
else
  bad "rpcd 超时未设置" "网页升级 46MB 级备份会被 rpcd 默认 30 秒超时杀掉"
fi

echo
printf '结果: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
