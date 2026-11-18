# features.md — 唯一的开关表（要什么改这里就行）

这一页就是「点菜单」：每行一个功能，`启用` 列写 1 表示要、写 0 表示不要。
改一处即可，三件事同时生效：

- 编译机自动按 1/0 生成「选中清单」，决定哪些功能装进固件；
- 源码按同一行自动去取；
- 编译前后检查用的「点名册」也按同一行自动增减，不用再改第二份清单。

本文件既是给脚本看的数据，也是给人看的表格——GitHub 上直接渲染，没有第二份要同步的文件。

## 几个词的意思

| 词 | 意思 |
|---|---|
| 固件 | 刷进路由器的整套系统 |
| 包 | 一个功能或软件，比如 OpenClash、ttyd |
| 软件源（feed） | 像「应用商店」，登记好网址后从里面挑包 |
| 选中清单（.config） | 编译机内部的清单，记录每个包「要 / 不要」；由本表自动生成，不用手改 |
| 点名册 | 编译前后两道检查用的「必须到场名单」；缺了谁，构建当场停下报错 |
| manifest | 编译完成后「实际装进固件」的清单；拿它对照点名册，防止少装 |

当前的开关状态对齐旧仓库：九个可选插件里启用 7 个，`bandix` 与 `theme_aurora` 关闭——前者与系统自带的流量统计重复，后者只是换个外观没有实际收益。要再减，把某一行的 `启用` 改回 `0` 即可。

`dhcp_comment` 与 `clash_cleaner` 目前也是 `0`：这两个包来自自建源 `ybjbox/openwrt-packages`，与当前系统（FanchmWrt 26.11 / apk）的兼容性还没实测过，先不装进固件，等验证过再单独打开。注意：`ybjbox` 软件源的网址登记在 `dhcp_comment` 这一行的来源列里，**行可以关、不要删**，`cf_ipcheck` 还靠它引用（关掉的行仍会解析来源列，登记不会丢）。

## 列的含义

| 列 | 说明 |
|---|---|
| 名称 | 给自己看的标签，只在报错时帮你定位是哪一行 |
| 启用 | `1` = 要；`0` = 不要（包不装、源码不取） |
| 设备附加包 | 旧机制留下的列，**已停用，保持 0**。它只在「一台编译机编很多型号、各装各的包」时才有用；本仓库只为雅典娜一台设备服务，所有包直接装进固件，这列永远是 0 |
| 包列表 | 要装的东西，空格隔开，一行可以写多个 |
| 来源 | 东西从哪来，写法见下表；不填 = 用系统自带的软件源 |
| 说明 | 中文备注，随便写，不影响运行 |

### 来源的写法

| 写法 | 作用 |
|---|---|
| `git:<网址>` | 把整个 GitHub 仓库拿下来当包用（适合小仓库） |
| `gitdir:<网址>#<分支>/<子目录>` | 大仓库只取其中一个文件夹（整个仓库 717 MB 也只下那几个文件） |
| `feed:<名字>=<网址>` | 登记一个外部软件源 |
| `feed:<名字>` | 引用其他行已登记的软件源 |
| 留空 | 用系统自带软件源 |

`gitdir:` 的用途：别的固件仓库里有个好插件，整仓搬会带进几百个同名包把系统搞乱，所以只取那一个文件夹。

解析规则：

- 只认带表头的 6 列表格，表头必须是 `名称 / 启用 / 设备附加包 / 包列表 / 来源 / 说明`
- 标题、说明、其他表格一律忽略（本页上面两张小表就是这么被跳过的）
- 每行必须正好 6 个格子，少写或多写一个竖线会报错，并告诉你是第几行
- 格子里必须出现竖线时，写成 `\|`
- `gitdir:` 的子目录必须是仓库内相对路径，不能写绝对路径或带 `..`

## 核心：不可关

> 首启脚本（宽带拨号 / WiFi 名称与密码 / 管理地址 / 关 IPv6 / 关硬件加速 /
> 换软件源 / 关 80→443 强制跳转）
> **不在这张表里**：它由构建仓 `files/etc/uci-defaults/99-athena-custom-settings`
> 直接写进 base-files overlay 随固件发布，编译时用 Secrets 填具体值。
> 要改内容就改那个文件，不装任何包。

| 名称 | 启用 | 设备附加包 | 包列表 | 来源 | 说明 |
|---|---|---|---|---|---|
| athena_target | 1 | 0 | | | 占位行：设备型号写死在流水线里，这行只是提醒别删 |
| athena_led | 1 | 0 | luci-app-athena-led luci-i18n-athena-led-zh-cn | git:https://github.com/NONGFAH/luci-app-athena-led | 点阵屏小屏驱动（普通直选，随固件安装） |
| dhcp_comment | 0 | 0 | luci-app-dhcp-comment | feed:ybjbox=https://github.com/ybjbox/openwrt-packages.git | 给局域网设备起备注名。**暂缓**：与当前系统兼容性未验证，先不装 |
| clash_cleaner | 0 | 0 | sysupgrade-clash-cleaner | feed:ybjbox | 升级后清理 Clash 残留。**暂缓**：同上，兼容性未验证 |
| cf_ipcheck | 1 | 0 | luci-app-cf-ipcheck | feed:ybjbox | Cloudflare 优选 IP 实测 |

## 基础工具：按需关

| 名称 | 启用 | 设备附加包 | 包列表 | 来源 | 说明 |
|---|---|---|---|---|---|
| tools_base | 1 | 0 | tmux htop nano-full fdisk cfdisk sgdisk tune2fs fstrim openssh-sftp-server zoneinfo-asia coremark | | 命令行与磁盘工具（automount 系统默认已带，不用点名） |
| zram | 1 | 0 | zram-swap | | 内存压缩（细节写死在脚本里，不用管） |

## 可选插件：每开一个都是独立构建风险点（旧仓同款，但关掉 bandix 与第三方主题）

| 名称 | 启用 | 设备附加包 | 包列表 | 来源 | 说明 |
|---|---|---|---|---|---|
| openclash | 1 | 0 | luci-app-openclash | git:https://github.com/vernesong/OpenClash | 代理 |
| lucky | 1 | 0 | luci-app-lucky lucky | git:https://github.com/gdy666/luci-app-lucky | 内网穿透 |
| airconnect | 1 | 0 | luci-app-airconnect airconnect | git:https://github.com/sbwml/luci-app-airconnect | AirPlay 桥接 |
| wechatpush | 1 | 0 | luci-app-wechatpush | git:https://github.com/tty228/luci-app-wechatpush | 微信推送 |
| bandix | 0 | 0 | bandix luci-app-bandix | git:https://github.com/timsaya/openwrt-bandix git:https://github.com/timsaya/luci-app-bandix | 流量看板。系统自带的流量统计够用，它多驻留一个后台进程还重复出数，故关闭 |
| quickfile | 1 | 0 | luci-app-quickfile | git:https://github.com/sbwml/luci-app-quickfile | 网页文件管理器。它需要换掉系统自带的网页服务才能用，这轮没换 → 装了但暂不可用 |
| theme_aurora | 0 | 0 | luci-theme-aurora luci-app-aurora-config | git:https://github.com/eamonxg/luci-theme-aurora git:https://github.com/eamonxg/luci-app-aurora-config | 第三方主题。系统页面自带样式，换主题只是外观不同，没有实际收益，故关闭 |

## 基础功能：旧仓没开、按需补上

> 坑一：`upnp` 是上游 `include/target.mk` 的默认包，这里写 `1` 只是重复点名，
> 改成 `0` 不会把它从固件里删掉。真要去掉得走 `scripts/prune-defaults.sh`，
> 并在 `configs/forbidden-packages.txt` 登记拦截。
>
> 坑二：`autoreboot` 在同一个默认包列表里也有，但 FanchmWrt 的 luci feed 指向
> 官方 `openwrt/luci`，里面**没有**这个应用，那条默认包是空转。它必须靠本表的
> `gitdir:` 单目录才真正装得进去——2026-11-18 曾按「源码自带」把该行删掉，
> 结果固件里连菜单都没了，同名条目并不会把包带进来。

| 名称 | 启用 | 设备附加包 | 包列表 | 来源 | 说明 |
|---|---|---|---|---|---|
| upnp | 1 | 0 | luci-app-upnp | | 端口自动映射（游戏机 / BT 下载用）。注意：等于允许局域网设备自行开洞，与行为管理方向相反 |
| watchcat | 1 | 0 | luci-app-watchcat watchcat | | 定时探测网络，连续失败 N 次自动重启，治「断网后卡死」（异常自愈，与计划重启互不冲突） |
| logrotate | 1 | 0 | logrotate | | 日志轮转，防日志写满存储。微信推送、行为管理都会写日志 |
| autoreboot | 1 | 0 | luci-app-autoreboot | gitdir:https://github.com/immortalwrt/luci#master/applications/luci-app-autoreboot | 网页「系统 → 定时重启」。官方 luci feed 没有这个应用，必须靠 `gitdir:` 只取这一个目录（9 个文件）；插件自带 `enabled=0`，不预置时间，改时间不用重编 |
| ttyd | 1 | 0 | luci-app-ttyd ttyd luci-i18n-ttyd-zh-cn | | 网页终端，装完在「服务 → 终端」。监听 7681；公网走 https 时 iframe 会被混合内容拦，需在 Lucky 单独反代后把「URL override」填成那个地址 |
