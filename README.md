# FanchmWrt Athena Builder

只为一台设备、一条分支存在的构建仓：**京东云雅典娜（JDCloud RE-CS-02，qualcommax/ipq60xx）**。

从 `openwrt-ci-roc` 的 **124 KB 自有逻辑**砍到 **17 KB 自有逻辑**（workflow 6.2 + 配置 5.1 + 默认值脚本 3.3 + diy 2.5），另加 30 KB 可复用的校验工具与测试，全仓 54 KB。保留三样东西：能编译、能验证、能追溯。

---

## 覆盖范围（明确不做什么）

| 做 | 不做 |
|---|---|
| 雅典娜单机型固件 | 亚瑟 / 太乙 / x86 / ipq807x |
| FanchmWrt snapshot 线（默认 `fanchmwrt-26.11`） | ImmortalWrt / LibWrt / 官方 OpenWrt 线 |
| 个人 4 个插件 + 点阵屏 + ImmortalWrt 定时重启单目录 | OAF（由内置 fwx 替代） |
| 包点名检查 + 版本锁 + 产物哈希 | SDK 独立分包流水线（需要时再加） |

砍掉的不是能力，是组合数。要恢复多机型时，复制本仓改 `configs/features.md` 即可；`required-packages.txt` 只存固定底座包，功能包由开关表自动派生。

> 源码线仍是 FanchmWrt。表格里「不做 ImmortalWrt 线」指的是**不换成它的整条源码与软件源**；`luci-app-autoreboot` 只是从它的仓库里取一个应用目录（9 个文件），用本仓官方 luci 的规则编译。

---

## 目录结构

```
.github/workflows/build.yml          完整构建流水线（24 步，约 2.5 小时；二次构建约 1.5 小时）
.github/workflows/check-config.yml   快速验证（约 10 分钟）：只验证设备选择与包清单，不编译
configs/features.md                  唯一开关表：编哪些包 + 拉哪些源 + 自动派生点名册
scripts/gen-config.sh                由 features.md 生成 .config 片段 / clone / gitdir / required 清单
configs/required-packages.txt        16 个固定底座包（其余由开关表自动派生，不要手改）
configs/forbidden-packages.txt       [block] / [warn]
files/etc/uci-defaults/99-...        首启默认值（PPPoE / WiFi / LAN IP / 关 IPv6；不含定时重启）
scripts/diy.sh                       全部定制（feed + clone + 稀疏取单目录）
scripts/check-packages.sh            包校验（--features 合并自动派生的点名册）
scripts/gen-lock.sh / verify-lock.sh 版本锁
scripts/hash-artifacts.sh            SHA256SUMS / BOM / build-info.json
scripts/gen-release-notes.sh         Release 说明（刷机要点 / 功能清单 / 校验 / 追溯）
tests/                               118 条回归断言（18 包校验 + 22 版本锁 + 78 开关）
```

---

## 首次使用

1. **建仓**：把本目录推到新仓库（建议公开，Actions 免费额度；私有仓 2–4 小时/次会烧配额）。
2. **配 Secrets**（Settings → Secrets and variables → Actions）：

   | Secret | 用途 | 必需 |
   |---|---|---|
   | `PPPOE_USERNAME` / `PPPOE_PASSWORD` | WAN 拨号 | 否（不填则保持 DHCP） |
   | `WIFI_SSID_2G` / `WIFI_SSID_5G` | 无线名（双 5G 同名漫游） | 否 |
   | `WIFI_PASSWORD` | 无线密码 | 否 |
   | `ADMIN_PASSWORD` | root 口令 | 否 |

   Secret 名**没有 `MY_` 前缀**（以仓库 Settings 里实际配置为准）；模板里的占位符 `__MY_*__` 只是 uci-defaults 脚本的固定字面量，两者不要混为一谈。首编曾因这里写成 `MY_*` 导致 `已填充占位符: 0 / 6`，现在流水线会在有未填充项时给出 warning。

   不填的项会保持占位符形态，`uci-defaults` 里的 `valid()` 会跳过它，不会把 SSID 写成 `__MY_*`。

3. **触发构建**（三种方式）：
   - **手动**：Actions → Build FanchmWrt Athena → Run workflow
   - **定时**：每周五 03:30（北京时间）自动跑一次。GitHub cron 按 **UTC** 解释，表达式写 `30 19 * * 4`（= 周四 19:30 UTC）；改时间记得减 8 小时。实际开跑可能延迟几分钟到几十分钟
   - **打 tag**：推送 `v*` tag 时自动构建，并以该 tag 发布 Release

   构建有两条自动规则：

   - **上游没变就不编**（仅定时触发）：先比对 fanchmwrt 分支当前 commit 与上次构建记录（写在 Release 说明第一行 `upstream-commit:`），相同则整次跳过，省掉 1.5–2.5 小时
   - **编完自动发 Release**：定时与手动构建统一命名 `athena-<北京时间戳>`（如 `athena-20261120-0331`），**都算正式版**（不标 Pre-release），也都**不抢 `latest`**——`latest` 只留给 `v*` tag 的手动发布

   定时任务单独占用一个并发组且不参与取消，**不会掐掉你正在手动跑的构建**；手动构建之间仍互相取消（连点两次只跑最新那次）。

   > **固件会自动清理**：每次发布后只保留最近 4 个 `athena-*` 版本（约一个月、约 720MB），更早的连同 tag 一起删除。`v*` tag 的发布不以 `athena-` 开头，**永远不会被删**。想改保留数量，调 workflow 清理步骤里的 `KEEP`。
4. **取产物**：Artifacts 里的 `dist/`，含固件、`SHA256SUMS`、`BOM.txt`、`build-info.json`。

   发 Release 时，说明页会给出：每个固件的用途与 SHA256、本次启用的功能清单、构建追溯（上游 commit、配置哈希等）。说明由 `scripts/gen-release-notes.sh` 生成，任一项数据取不到就自动省略，不影响发布；末尾有一段「自动化读取区」（`upstream-commit:`），定时构建靠它判断上游是否变化，不要删。
5. **刷机**：不死 uboot 刷 `factory.bin`，之后系统内升 `sysupgrade.bin`；**用 1.0.5 起必须不保留配置**。

要发 Release：打 `v*` tag，或手动触发时勾选 `create_release`。

---

## 版本线切换

默认 `fanchmwrt-26.11`（与官网 `snapshot-1.0.5` 同线，内核 6.18）。手动触发时改 `source_ref` 即可试其他分支。

> 切到 `fanchmwrt-25.12.6` 会**编不出雅典娜**：该分支没有 `jdcloud_re-cs-02` 设备定义、DTS 与 ipq-wifi board file。详见迁移方案第 03 节。

---

## 能力开关（features.md）

`configs/features.md` 是一张 Markdown 表格，**既是脚本的数据源，也是给人看的文档**。GitHub 上直接渲染成表格，带分组标题和格式说明；改完提交，没有第二份需要同步的文件。

列顺序固定：`名称 / 启用 / 设备附加包 / 包列表 / 来源 / 说明`。**只改 `启用` 列的 `1` / `0`**：`.config`、源码拉取、以及编译前后两道校验用的「点名册」会同时跟随，不需要再手动改 `required-packages.txt`。

```
| 名称 | 启用 | 设备附加包 | 包列表 | 来源 | 说明 |
|---|---|---|---|---|---|
| openclash | 0 | 0 | luci-app-openclash | git:https://github.com/vernesong/OpenClash | 代理 |
| tools_base | 1 | 0 | tmux htop nano-full ... | | 命令行与磁盘工具 |
| athena_custom | 1 | 0 | | | 首启脚本由构建仓注入，包列表可以为空 |
```

解析规则：只认带 6 列表头的表格（表头必须是 `名称 / 启用 / 设备附加包 / 包列表 / 来源 / 说明`）。`##` 标题、说明段落、其他列数的表格全部忽略——所以文件里可以放心写文档用的表格。每行必须 6 列，少写一个 `|` 会报错并指到行号。

| 想做的事 | 怎么改 |
|---|---|
| 开 OpenClash | 该行 `\| 0 \|` → `\| 1 \|` |
| 关掉命令行工具 | `tools_base` 那行 `\| 1 \|` → `\| 0 \|` |
| 关掉某插件后担心点名册 | **不用管**，点名册由开关表自动派生，关掉就自动少几行 |
| 加一个新插件 | 复制一行，填包名；需要外部源就写 `git:<url>` 或 `feed:<名>=<url>` |
| 只取别的大仓里一个插件目录 | 写 `gitdir:<url>#<分支>/<子目录>`（稀疏检出，不整仓拉） |
| 只引用已有 feed | 写 `feed:ybjbox`（URL 由其他行声明） |
| 单元格里必须写竖线 | 转义成 `\|` |
| 校验表格有没有写错 | `./scripts/gen-config.sh --check` |

预览生成结果：

```bash
./scripts/gen-config.sh --features configs/features.md            # 打印 .config 片段
./scripts/gen-config.sh --features configs/features.md --list-clones
./scripts/gen-config.sh --features configs/features.md --list-gitdirs
./scripts/gen-config.sh --features configs/features.md --list-required  # 自动派生的点名册
./scripts/gen-config.sh --features configs/features.md --check
```

表格写错会在生成阶段直接报错并给出行号（重名、启用列不是 0/1、列数不对、来源前缀不认识、feed 引用但没声明 URL、`gitdir:` 子目录写成绝对路径）。

### 点名册自动派生（只改一处）

「点名册」= 编译前后两道检查用的「必须到场名单」：名单上的包没出现在固件里，构建当场停下报错。这个机制防的是"以为装了其实没装"。

早期版本里开关表和 `configs/required-packages.txt` 要手动对齐：关掉某个插件却忘了删点名册里的那一行，编译前校验就会报「缺少必需包」停下来。现在不再需要这一步：

| | 内容 | 谁维护 |
|---|---|---|
| `configs/required-packages.txt` | 16 个固定底座包（fwx 内核与页面、`luci-compat`、4 个无线包） | 换 FanchmWrt 版本线时才核对 |
| `--list-required` | 当前 39 项，全部来自 `features.md` 的**启用行** | 改开关自动变化 |

`check-packages.sh --features configs/features.md` 把两者合并去重，编译前（查 `.config`）和编译后（查 manifest）两道校验共用同一份清单，日志里会打印「固定底座 16 项 + 开关表自动派生 N 项」。

> **比旧版更严，这是有意的**：以前很多启用包根本没被检查，现在是逐个核对。如果某个包在 feeds 里不存在或名字写错，`make defconfig` 会把它静默丢掉，编译前这一步就会点名报出来——把隐患提前暴露，而不是等到刷机后才发现插件没装上。报缺包时先看日志点的是哪个包，通常是包名笔误或对应 feed 没拉到。

> **为什么是 Markdown 表格**：`.conf` 的竖线文本在 GitHub 上只是纯文本；`.tsv` 要求每行列数一致，注释行（1 列）与空行（0 列）会让表格视图直接拒绝渲染；YAML 结构更强但 CI 上要额外装 PyYAML。Markdown 表格三样都占：能渲染、能写注释、解析零依赖。

### 当前基线与旧仓的差异

`features.md` 的启停状态对齐旧仓 `ybjbox/openwrt-ci-roc`（General / Packages / JDCloud 三份配置）：**19 条启用、2 条关闭**，39 个包、9 个 git 源 + 1 个 `gitdir` 单目录。

五处**刻意不照搬**：

| 项 | 旧仓 | 本仓 | 原因 |
|---|---|---|---|
| `luci-app-oaf` | 启用 | 不装 | 与内置 `fwx` 抢 netfilter 钩子与 `/etc/config/appfilter` |
| NSS / `TESTING_KERNEL` | 启用 | 不装 | snapshot 线无 NSS 卸载栈；且与流量统计、DPI 原理冲突 |
| `luci-app-quickfile` | 配合 nginx 使用 | 只装插件 | `luci-light` 硬依赖 `uhttpd`（`+uhttpd +uhttpd-mod-ubus`），换 web 服务器要连带拆掉 `luci` 元包，本轮不做 |
| `bandix` | 启用 | 关闭 | `fwx` 自带流量与会话统计，它靠常驻进程轮询 conntrack 出数，重复且多一份开销 |
| `luci-theme-aurora` | 启用 | 关闭 | `fwx` 页面样式在插件内自备，换主题只有视觉差异，无功能收益 |

`quickfile` 因此**装上但不可用**：它需要 nginx 接管 80，而 uhttpd 由依赖强制启用。要用它，得把 `luci` 换成 `luci-nginx` + 手工挑 `luci-mod-*`（旧仓正是这么做的），这是一次独立改造，不适合和首编混在一起。

`bandix` 关掉后，流量统计只剩 `fwx` 一套（`luci-app-fwx-traffic-stat` + `luci-app-fwx-session-stat`，已在必需包清单里）；两者口径不同，同时开会出现两个数字不一致的面板，反而难判断哪个可信。

### 定时重启（ImmortalWrt 插件，网页可改）

> 更正：早前本文件写「ImmortalWrt 也已移除 `luci-app-autoreboot`」是查错了。`immortalwrt/luci` 的 `applications/luci-app-autoreboot` 是 2025 年的新版（JS 页面 + procd 服务 + UCI 配置），官方软件仓库也提供 ipk。

FanchmWrt 用的是官方 `openwrt/luci`（104 个应用），不带这个应用。构建时用 `gitdir:` **只取这一个目录**（9 个文件）放进 `package/`，并把 Makefile 的 `include ../../luci.mk` 改指 `$(TOPDIR)/feeds/luci/luci.mk`。

**为什么不整仓拉**：`immortalwrt/luci` 约 717 MB / 167 个应用，与官方 luci 绝大部分包同名；整仓当第二个软件源加进来会互相覆盖、`feeds install -a` 依赖解析错乱，而且它的 `luci.mk` 带 ucode 模板版本要求，与本仓官方规则不一致。稀疏检出只下 9 个文件，三个问题全避开。插件用的是标准 `uci` / `crontab` / `procd` 接口，跨版本风险小。

- 位置：网页「系统 → 定时重启」（`admin/system/autoreboot`）
- 默认：插件自带 `/etc/config/autoreboot` 是 `enabled=0`（周日 02:00 但**不启用**）；固件**不做任何预置**，刷完不会自动重启
- 启用、改时间：直接在网页上点，即时生效，**不用重新编译固件**（服务按 `#autoreboot_` 标记动态管理 crontab，不会叠加多条）
- 首启脚本 `99-athena-custom-settings` 原先那条写死的 `0 4 * * 0 reboot` 已删除，避免两套计划重复重启
- 界面语言：插件自带 `po/zh_Hans`，`CONFIG_LUCI_LANG_zh_Hans=y` 时由官方 `luci.mk` 生成中文语言包
- 与 `watchcat` 的分工：`watchcat` 管「断网后卡死」的异常自愈，`autoreboot` 管「计划性定期重启」，互不冲突
- 退路：若首次构建实测该页面打不开，可刷机后在「系统 → 软件包」手动装 ImmortalWrt 官方 ipk，不必重编固件（但每次刷机要重装一次）

## 编译加速（三层缓存）

完整构建约 2.5 小时，**编译占 98%**（实测 2h21m / 2h24m），其余步骤合计不到 3 分钟。因此缓存全部打在编译链上：

| 缓存 | 缓存内容 | 失效条件 | 预计收益（第二次起） |
|---|---|---|---|
| `dl` | 源码包下载目录 `openwrt/dl` | `features.md` 变化 | 省掉重复下载（已生效） |
| `ccache` | `openwrt/.ccache`（OpenWrt 强制指定此路径，不能用别处；上限 5G） | `features.md` 变化；`restore-keys` 会兜底复用旧缓存 | **30–60 分钟** |
| 工具链 | `build_dir/host`、`build_dir/toolchain-*`、`staging_dir/host`、`staging_dir/toolchain-*` | 上游 commit 或 `features.md` 变化 | **20–30 分钟** |

设计要点：

- **只复用编译产物，不改固件内容**：缓存失效最坏退化为全量编译，不会产出错误固件。
- **工具链缓存的 key 带上游 commit**（`git ls-remote` 解析前 12 位）：上游一更新自动失效，避免新旧源码混用。
- **只在构建成功时保存**（`if: success()`）：失败不会把半成品写进缓存。
- 仓库缓存上限 10GB，超出时 GitHub 按最久未用自动淘汰；`dl` + `ccache` + 工具链合计约 5–8GB。
- 本地构建同样受益：先 `sudo apt install ccache`（片段里已默认带 `CONFIG_CCACHE=y`）。

预期：首次构建（填充缓存）约 2.5 小时，之后稳定在 **1.5 小时左右**。日志里会打印编译前后的 `ccache -s` 统计，可据此判断命中率。

定时每周跑一次还有个附带好处：缓存不会因长期不用而过期，每次都能享受缓存后的速度。

## 本地复现

```bash
git clone --depth=1 -b fanchmwrt-26.11 https://github.com/fanchmwrt/fanchmwrt-snapshot.git openwrt
./scripts/diy.sh openwrt
cd openwrt && ./scripts/feeds update -a && ./scripts/feeds install -a && cd ..

printf 'CONFIG_TARGET_MULTI_PROFILE=y\nCONFIG_TARGET_qualcommax=y\nCONFIG_TARGET_qualcommax_ipq60xx=y\nCONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02=y\n' > openwrt/.config
(cd openwrt && make defconfig)
./scripts/gen-config.sh --features configs/features.md --out openwrt/.config.fragment
cat openwrt/.config.fragment >> openwrt/.config
(cd openwrt && make defconfig)

./scripts/check-packages.sh --config openwrt/.config --features configs/features.md
./scripts/gen-lock.sh --tree openwrt --out versions.lock
(cd openwrt && make -j"$(nproc)")
./scripts/hash-artifacts.sh --tree openwrt --out dist --lock versions.lock
```

改完开关后想固定基线：把 `openwrt/.config` 存成 `configs/athena.config.locked`，并把工作流第 9 步改成整份覆盖。开关表适合快速迭代，整份配置适合长期复现。

---

## 与 openwrt-ci-roc 的差异

| 维度 | 旧仓 | 本仓 |
|---|---|---|
| 源码 | laipeng668/immortalwrt + NSS 补丁 | fanchmwrt-snapshot，无 NSS |
| 配置 | 7 份 `.config` 双文件合并 | 1 份 Markdown 开关表（自动生成片段） |
| 脚本 | 2 个 / 69 KB（含大量 feed 替换） | 1 个 / 40 行 |
| 工作流 | 8 个 / 42 KB | 1 个 |
| 流水线 | 直接 build | 包点名 → 版本锁 → 编译 → 实装清单核对 → 哈希 |
| 体积 | 约 124 KB（全为自有逻辑） | 54 KB（自有 17 KB + 校验工具与测试 30 KB + 文档 7 KB） |

### 旧仓要删的文件

```
.github/workflows/Build-OpenWrt.yml
.github/workflows/Build-Packages.yml
.github/workflows/IPQ60XX-LibWrt.yml
.github/workflows/IPQ807X-LibWrt.yml
.github/workflows/JDCloud-ImmortalWrt.yml
.github/workflows/JDCloud-NoWiFi-ImmortalWrt.yml
.github/workflows/Trigger-All-Workflows.yml
.github/workflows/x86-64-ImmortalWrt.yml
configs/General.config
configs/JDCloud.config
configs/JDCloud.NoWiFi.config
configs/IPQ60XX.config
configs/IPQ807X.config
configs/Packages.config
configs/x86-64.config
scripts/Roc-script.sh
scripts/SDK-script.sh
```

保留 `LICENSE`；`README.md` 重写；`keys/`、`Homepage.png` 按需。

---

## 排障

| 现象 | 先查 |
|---|---|
| 「雅典娜设备符号丢失」/「产物不是雅典娜设备」 | 设备护栏当场拦截了目标漂移（曾静默编成 8devices 开发板、白等 3 小时）。根因：设备选择默认是"单选一个默认设备"，恰好指向字母序第一的 8devices，必须开多设备模式并显式选雅典娜——基线 4 行（含 `CONFIG_TARGET_MULTI_PROFILE=y`）缺一不可；改完跑 `check-config` 快速验证（10 分钟）再触发完整构建 |
| 编译日志看起来"卡住不动" | 已改为实时滚动（默认摘要模式，每个包一两行）。个别包（工具链、内核、OpenClash 这类大件）单包编译十几分钟属正常；把鼠标悬停在日志行首可以看到每行的时间戳 |
| 编译失败想看真实报错 | 流水线会自动用单线程 `V=s` 重跑到出错点，尾部日志存进 `build-log-tail.txt` artifact；「编译」步骤里的红色 `error` 行就是根因 |
| 编译前报「缺少必需包」 | 看日志点名的是固定底座还是**开关表派生项**：派生项多半是包名笔误或对应 feed 没拉到，被 `make defconfig` 静默丢弃；对照 `features.md` 那一行的包列表 |
| `check-packages` 报缺 `luci-app-fwx-*` | feeds 是否 `update -a` 成功；`source_ref` 是否切到了没有 fwx 的分支 |
| 「系统 → 定时重启」打不开 | 看 `diy.sh` 的 `gitdir` 步骤是否拿到 9 个文件、Makefile 的 `luci.mk` 引用是否改写成功；退路是手动装 ipk |
| manifest 校验报 `qca-nss-ecm` | `source_ref` 混入了 NSS 补丁分支 |
| 编译过但 WiFi 不起 | `ipq-wifi-jdcloud_re-cs-02` 是否在 manifest；DTS 是否为 26.11 分支自带 |
| 刷后登录不了 | `uci-defaults` 里 LAN IP 改成了 10.0.0.1；用该网段访问 |
| 流量统计不动 | `fastnat.global.enabled` 必须为 0；`flow_offloading_hw` 为 0 |

---

## 设计取舍

**为什么用开关表而不是整份 `.config`**：`.config` 是编译机内部的"选中清单"，301 KB 全是系统生成的行，人工维护必然漂移。`features.md` 只表达"我要哪些能力"，由脚本生成清单片段，升级 FanchmWrt 时自动继承上游默认。代价是每次多跑一遍展开步骤（几秒）。

**为什么开关表同时驱动 clone**：以前"加包"和"加源"分散在 `.config` 与 `diy.sh` 两处，改一处忘一处就会编译失败。现在 `enabled` 为 0 的行既不选包也不 clone，只有一个事实来源。

**为什么点名册也由开关表自动派生**：以前额外还有一份手写 `required-packages.txt`，关了开关忘了删对应行，构建就会卡在「缺少必需包」——这是非专业使用者最容易踩的坑。合并成单一事实来源后，改开关即改清单，编译前后两道校验共用。代价是校验从「漏检」变成「真检查」：所有启用包都必须真的出现在 `.config` 与 manifest 里，缺依赖会在编译前就点名报出来。

**为什么没有 SDK 分包流水线**：4 个自定义包已随固件编入，单独出 ipk 只会增加发布面。要分发插件时再加，`Build-Packages.yml` 可从旧仓照搬。

**为什么保留 `verify-lock.sh` 却不在 CI 里跑**：CI 每次现生成 lock，自校验必然通过。它的价值在本地——改完 `diy.sh` 或换分支后，用它确认"和上次发布差在哪"。
