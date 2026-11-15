# FanchmWrt Athena Builder

只为一台设备、一条分支存在的构建仓：**京东云雅典娜（JDCloud RE-CS-02，qualcommax/ipq60xx）**。

从 `openwrt-ci-roc` 的 **124 KB 自有逻辑**砍到 **17 KB 自有逻辑**（workflow 6.2 + 配置 5.1 + 默认值脚本 3.3 + diy 2.5），另加 30 KB 可复用的校验工具与测试，全仓 54 KB。保留三样东西：能编译、能验证、能追溯。

---

## 覆盖范围（明确不做什么）

| 做 | 不做 |
|---|---|
| 雅典娜单机型固件 | 亚瑟 / 太乙 / x86 / ipq807x |
| FanchmWrt snapshot 线（默认 `fanchmwrt-26.11`） | ImmortalWrt / LibWrt / 官方 OpenWrt 线 |
| 个人 4 个插件 + 点阵屏插件 | OAF（由内置 fwx 替代） |
| 包清单校验 + 版本锁 + 产物哈希 | SDK 独立分包流水线（需要时再加） |

砍掉的不是能力，是组合数。要恢复多机型时，复制本仓改 `configs/features.tsv` 与 `required-packages.txt` 即可。

---

## 目录结构

```
.github/workflows/build.yml          单条流水线（18 步）
configs/features.tsv                 唯一开关表：编哪些包 + clone 哪些源
scripts/gen-config.sh                由 features.tsv 生成 .config 片段 / clone 清单
configs/required-packages.txt        必须存在（缺失即失败）
configs/forbidden-packages.txt       [block] / [warn]
files/etc/uci-defaults/99-...        首启默认值（PPPoE / WiFi / LAN IP / 关 IPv6）
scripts/diy.sh                       全部定制（加 feed + clone 两个包，约 40 行）
scripts/check-packages.sh            包校验
scripts/gen-lock.sh / verify-lock.sh 版本锁
scripts/hash-artifacts.sh            SHA256SUMS / BOM / build-info.json
tests/                               57 条回归断言（12 包校验 + 22 版本锁 + 23 开关）
```

---

## 首次使用

1. **建仓**：把本目录推到新仓库（建议公开，Actions 免费额度；私有仓 2–4 小时/次会烧配额）。
2. **配 Secrets**（Settings → Secrets and variables → Actions）：

   | Secret | 用途 | 必需 |
   |---|---|---|
   | `MY_PPPOE_USERNAME` / `MY_PPPOE_PASSWORD` | WAN 拨号 | 否（不填则保持 DHCP） |
   | `MY_WIFI_SSID_2G` / `MY_WIFI_SSID_5G` | 无线名（双 5G 同名漫游） | 否 |
   | `MY_WIFI_PASSWORD` | 无线密码 | 否 |
   | `MY_ADMIN_PASSWORD` | root 口令 | 否 |

   不填的项会保持占位符形态，`uci-defaults` 里的 `valid()` 会跳过它，不会把 SSID 写成 `__MY_*`。

3. **手动触发**：Actions → Build FanchmWrt Athena → Run workflow。
4. **取产物**：Artifacts 里的 `dist/`，含固件、`SHA256SUMS`、`BOM.txt`、`build-info.json`。
5. **刷机**：不死 uboot 刷 `factory.bin`，之后系统内升 `sysupgrade.bin`；**用 1.0.5 起必须不保留配置**。

要发 Release：打 `v*` tag，或手动触发时勾选 `create_release`。

---

## 版本线切换

默认 `fanchmwrt-26.11`（与官网 `snapshot-1.0.5` 同线，内核 6.18）。手动触发时改 `source_ref` 即可试其他分支。

> 切到 `fanchmwrt-25.12.6` 会**编不出雅典娜**：该分支没有 `jdcloud_re-cs-02` 设备定义、DTS 与 ipq-wifi board file。详见迁移方案第 03 节。

---

## 能力开关（features.tsv）

一行一个能力，六列：`名称|启用|设备附加包|包列表|来源|说明`。改 `启用` 列即可，配置与 clone 会同时跟随。

```
openclash|0|0|luci-app-openclash|git:https://github.com/vernesong/OpenClash|代理
tools_base|1|0|tmux htop nano-full ...||命令行与磁盘工具
athena_custom|1|0|athena-custom|feed:ybjbox=https://github.com/ybjbox/openwrt-packages.git|个人默认值
```

| 想做的事 | 怎么改 |
|---|---|
| 开 OpenClash | `openclash\|0\|` → `openclash\|1\|` |
| 关掉命令行工具 | `tools_base\|1\|` → `tools_base\|0\|` |
| 加一个新插件 | 复制一行，填包名；需要外部源就写 `git:<url>` 或 `feed:<名>=<url>` |
| 只引用已有 feed | 写 `feed:ybjbox`（URL 由其他行声明） |
| 校验表格有没有写错 | `./scripts/gen-config.sh --check` |

预览生成结果：

```bash
./scripts/gen-config.sh --features configs/features.tsv            # 打印 .config 片段
./scripts/gen-config.sh --features configs/features.tsv --list-clones
./scripts/gen-config.sh --features configs/features.tsv --check
```

表格写错会在生成阶段直接报错并给出行号（重名、启用列不是 0/1、来源前缀不认识、feed 引用但没声明 URL）。

## 本地复现

```bash
git clone --depth=1 -b fanchmwrt-26.11 https://github.com/fanchmwrt/fanchmwrt-snapshot.git openwrt
./scripts/diy.sh openwrt
cd openwrt && ./scripts/feeds update -a && ./scripts/feeds install -a && cd ..

printf 'CONFIG_TARGET_qualcommax=y\nCONFIG_TARGET_qualcommax_ipq60xx=y\nCONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02=y\n' > openwrt/.config
(cd openwrt && make defconfig)
./scripts/gen-config.sh --features configs/features.tsv --out openwrt/.config.fragment
cat openwrt/.config.fragment >> openwrt/.config
(cd openwrt && make defconfig)

./scripts/check-packages.sh --config openwrt/.config
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
| 配置 | 7 份 `.config` 双文件合并 | 1 份开关表（自动生成片段） |
| 脚本 | 2 个 / 69 KB（含大量 feed 替换） | 1 个 / 40 行 |
| 工作流 | 8 个 / 42 KB | 1 个 |
| 流水线 | 直接 build | 包校验 → 版本锁 → build → manifest 校验 → 哈希 |
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
| `check-packages` 报缺 `luci-app-fwx-*` | feeds 是否 `update -a` 成功；`source_ref` 是否切到了没有 fwx 的分支 |
| manifest 校验报 `qca-nss-ecm` | `source_ref` 混入了 NSS 补丁分支 |
| 编译过但 WiFi 不起 | `ipq-wifi-jdcloud_re-cs-02` 是否在 manifest；DTS 是否为 26.11 分支自带 |
| 刷后登录不了 | `uci-defaults` 里 LAN IP 改成了 10.0.0.1；用该网段访问 |
| 流量统计不动 | `fastnat.global.enabled` 必须为 0；`flow_offloading_hw` 为 0 |

---

## 设计取舍

**为什么用开关表而不是整份 `.config`**：301 KB 的 `.config` 人工维护必漂移。`features.tsv` 只表达"我要哪些能力"，由脚本生成 `.config` 片段，升级 FanchmWrt 时自动继承上游默认。代价是每次多跑一遍 `make defconfig`（几秒）。

**为什么开关表同时驱动 clone**：以前"加包"和"加源"分散在 `.config` 与 `diy.sh` 两处，改一处忘一处就会编译失败。现在 `enabled` 为 0 的行既不选包也不 clone，只有一个事实来源。

**为什么没有 SDK 分包流水线**：4 个自定义包已随固件编入，单独出 ipk 只会增加发布面。要分发插件时再加，`Build-Packages.yml` 可从旧仓照搬。

**为什么保留 `verify-lock.sh` 却不在 CI 里跑**：CI 每次现生成 lock，自校验必然通过。它的价值在本地——改完 `diy.sh` 或换分支后，用它确认"和上次发布差在哪"。
