# features.md — 单线构建的唯一开关表

改需求只改这里：把某行的 `启用` 从 `0` 改成 `1`，`gen-config.sh` 生成 `.config`、`diy.sh` 拉源码，两边同时生效。
本文件既是脚本的数据源，也是 GitHub 上可直接阅读的表格——没有第二份需要同步的文档。

当前的启停状态对齐旧仓 `ybjbox/openwrt-ci-roc`（General / Packages / JDCloud 三份配置），九个可选插件里启用 7 个：`bandix` 与 `theme_aurora` 关闭——前者与 `fwx` 自带的流量统计重复，后者对 `fwx` 页面没有收益。要再减，把某一行的 `启用` 改回 `0` 即可。

## 列含义

| 列 | 说明 |
|---|---|
| 名称 | 唯一标识，仅用于阅读与报错定位 |
| 启用 | `1` = 编译进固件并拉取来源；`0` = 完全跳过（包不选、源不 clone） |
| 设备附加包 | `1` = 该行包列表同时写进 `CONFIG_TARGET_DEVICE_PACKAGES_*` |
| 包列表 | 空格分隔的包名，展开为 `CONFIG_PACKAGE_<name>=y` |
| 来源 | 空格分隔的 token，写法见下表 |
| 说明 | 中文备注，不参与解析 |

### 来源写法

| 写法 | 作用 |
|---|---|
| `git:<url>` | 克隆到 `package/<仓库名末段>` |
| `feed:<名>=<url>` | 追加 `src-git <名> <url>` 到 `feeds.conf.default` |
| `feed:<名>` | 引用其他行已声明的 feed URL |
| 留空 | 用 FanchmWrt 自带 feeds |

解析规则：

- 只解析带表头的 6 列表格，表头必须是 `名称 / 启用 / 设备附加包 / 包列表 / 来源 / 说明`
- `##` 标题、普通段落、其他列数的表格一律忽略（上面两张说明表就是靠这条被跳过的）
- 每行必须 6 列，少写或多写分隔符会直接报错并指到行号
- 单元格内如必须出现竖线，写成 `\|`

## 核心：不可关

| 名称 | 启用 | 设备附加包 | 包列表 | 来源 | 说明 |
|---|---|---|---|---|---|
| athena_target | 1 | 0 | | | 目标设备由 gen-config.sh 固定输出，此行仅作占位说明 |
| athena_led | 1 | 1 | luci-app-athena-led luci-i18n-athena-led-zh-cn | git:https://github.com/NONGFAH/luci-app-athena-led | 点阵屏小屏驱动 |
| athena_custom | 1 | 0 | athena-custom | feed:ybjbox=https://github.com/ybjbox/openwrt-packages.git | 个人默认值：PPPoE / WiFi / LAN IP / 关 IPv6 |
| dhcp_comment | 1 | 0 | luci-app-dhcp-comment | feed:ybjbox | DHCP 客户端备注 |
| clash_cleaner | 1 | 0 | sysupgrade-clash-cleaner | feed:ybjbox | 升级后清理 Clash 残留 |
| cf_ipcheck | 1 | 0 | luci-app-cf-ipcheck | feed:ybjbox | Cloudflare 优选 IP 实测 |

## 基础工具：按需关

| 名称 | 启用 | 设备附加包 | 包列表 | 来源 | 说明 |
|---|---|---|---|---|---|
| tools_base | 1 | 0 | tmux htop nano-full fdisk cfdisk sgdisk tune2fs fstrim openssh-sftp-server zoneinfo-asia coremark automount | | 命令行与磁盘工具 |
| zram | 1 | 0 | zram-swap | | 内存压缩（内核选项见 gen-config.sh） |

## 可选插件：每开一个都是独立构建风险点（旧仓同款，但关掉 bandix 与第三方主题）

| 名称 | 启用 | 设备附加包 | 包列表 | 来源 | 说明 |
|---|---|---|---|---|---|
| openclash | 1 | 0 | luci-app-openclash | git:https://github.com/vernesong/OpenClash | 代理 |
| lucky | 1 | 0 | luci-app-lucky lucky | git:https://github.com/gdy666/luci-app-lucky | 内网穿透 |
| smartdns | 1 | 0 | luci-app-smartdns smartdns luci-i18n-smartdns-zh-cn | git:https://github.com/pymumu/luci-app-smartdns git:https://github.com/pymumu/openwrt-smartdns | DNS |
| mosdns | 1 | 0 | luci-app-mosdns mosdns v2ray-geodata luci-i18n-mosdns-zh-cn | git:https://github.com/sbwml/luci-app-mosdns | DNS 分流 |
| airconnect | 1 | 0 | luci-app-airconnect airconnect | git:https://github.com/sbwml/luci-app-airconnect | AirPlay 桥接 |
| wechatpush | 1 | 0 | luci-app-wechatpush | git:https://github.com/tty228/luci-app-wechatpush | 微信推送 |
| bandix | 0 | 0 | bandix luci-app-bandix | git:https://github.com/timsaya/openwrt-bandix git:https://github.com/timsaya/luci-app-bandix | 流量看板。fwx 自带流量/会话统计，装它等于多一个常驻进程轮询 conntrack，故关闭 |
| quickfile | 1 | 0 | luci-app-quickfile | git:https://github.com/sbwml/luci-app-quickfile | 网页文件管理器。需 nginx 接管 80，而 luci-light 强依赖 uhttpd，本轮不做 web 服务器替换 → 装上但暂不可用 |
| theme_aurora | 0 | 0 | luci-theme-aurora luci-app-aurora-config | git:https://github.com/eamonxg/luci-theme-aurora git:https://github.com/eamonxg/luci-app-aurora-config | 第三方主题。fwx 页面自带样式，换主题只是视觉不一致，收益为零，故关闭 |

## 基础功能：旧仓没开、按需补上

| 名称 | 启用 | 设备附加包 | 包列表 | 来源 | 说明 |
|---|---|---|---|---|---|
| upnp | 1 | 0 | luci-app-upnp | | 端口自动映射（BT / PS / Xbox）。安全面：等于允许局域网设备自行开洞，与行为管理方向相反 |
| watchcat | 1 | 0 | luci-app-watchcat watchcat | | 定时 ping，连续失败 N 次自动重启，治"断网后卡死"。定时重启另由 uci-defaults 的 cron 实现——官方 feed 无 luci-app-autoreboot |
| logrotate | 1 | 0 | logrotate | | 日志轮转，防 /var/log 写满。wechatpush、fwx 都会写日志 |
