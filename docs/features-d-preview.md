# features · D 方案预览（Markdown 表格作为源文件）

> 本文件仅用于对比 GitHub 渲染效果，不参与构建。数据与 `configs/features.conf` 完全一致。

## 核心

| 名称 | 启用 | 设备附加包 | 包列表 | 来源 | 说明 |
| --- | --- | --- | --- | --- | --- |
| athena_target | 1 | 0 |  |  | 目标设备由 gen-config.sh 固定输出，此行仅作占位说明 |
| athena_led | 1 | 1 | luci-app-athena-led luci-i18n-athena-led-zh-cn | git:https://github.com/NONGFAH/luci-app-athena-led | 点阵屏小屏驱动 |
| athena_custom | 1 | 0 | athena-custom | feed:ybjbox=https://github.com/ybjbox/openwrt-packages.git | 个人默认值：PPPoE / WiFi / LAN IP / 关 IPv6 |
| dhcp_comment | 1 | 0 | luci-app-dhcp-comment | feed:ybjbox | DHCP 客户端备注 |
| clash_cleaner | 1 | 0 | sysupgrade-clash-cleaner | feed:ybjbox | 升级后清理 Clash 残留 |
| cf_ipcheck | 1 | 0 | luci-app-cf-ipcheck | feed:ybjbox | Cloudflare 优选 IP 实测 |

## 基础工具

| 名称 | 启用 | 设备附加包 | 包列表 | 来源 | 说明 |
| --- | --- | --- | --- | --- | --- |
| tools_base | 1 | 0 | tmux htop nano-full fdisk cfdisk sgdisk tune2fs fstrim openssh-sftp-server zoneinfo-asia coremark automount |  | 命令行与磁盘工具 |
| zram | 1 | 0 | zram-swap |  | 内存压缩（内核选项见 gen-config.sh） |

## 以下默认关闭

| 名称 | 启用 | 设备附加包 | 包列表 | 来源 | 说明 |
| --- | --- | --- | --- | --- | --- |
| openclash | 0 | 0 | luci-app-openclash | git:https://github.com/vernesong/OpenClash | 代理 |
| lucky | 0 | 0 | luci-app-lucky | git:https://github.com/gdy666/luci-app-lucky | 内网穿透 |
| smartdns | 0 | 0 | luci-app-smartdns smartdns | git:https://github.com/pymumu/luci-app-smartdns git:https://github.com/pymumu/openwrt-smartdns | DNS |
| mosdns | 0 | 0 | luci-app-mosdns | git:https://github.com/sbwml/luci-app-mosdns | DNS 分流 |
| airconnect | 0 | 0 | luci-app-airconnect airconnect | git:https://github.com/sbwml/luci-app-airconnect | AirPlay 桥接 |
| wechatpush | 0 | 0 | luci-app-wechatpush | git:https://github.com/tty228/luci-app-wechatpush | 微信推送 |
| bandix | 0 | 0 | bandix luci-app-bandix | git:https://github.com/timsaya/openwrt-bandix git:https://github.com/timsaya/luci-app-bandix | 流量看板（与 fwx 统计二选一） |
| quickfile | 0 | 0 | luci-app-quickfile | git:https://github.com/sbwml/luci-app-quickfile | 网页文件管理器（需 nginx） |
| theme_aurora | 0 | 0 | luci-theme-aurora luci-app-aurora-config | git:https://github.com/eamonxg/luci-theme-aurora git:https://github.com/eamonxg/luci-app-aurora-config | 第三方主题 |
