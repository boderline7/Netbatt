# NetBatt

安卓（Magisk）上的网络共享与供电控制模块。

## 功能

- **热点管理** — 网页开关热点、查看已连接设备，被系统关闭后自动恢复。
- **USB 共享** — 打开 NCM 共享，USB 侧固定在 `192.168.8.0/24`，与热点侧双向互通。
- **端口转发** — 热点侧访问本机指定端口的流量转到 USB 侧设备，默认不转发，端口可增删。
- **充电控制** — 按电量上下限自动启停充电，带温度保护，显示实时充放电功率。

## 充电通道

两套通道，按机型自动识别，结果在网页上直接显示：

| 平台 | 通道 | 节点 | 语义 |
|---|---|---|---|
| 高通（小米 11 等） | switch | `/sys/class/qcom-battery/input_suspend` | `0` 充电 / `1` 暂停 |
| 联发科 · vivo | soc | `/sys/class/power_supply/battery/keep_chg_soc` | 写入目标电量，充到即停 |

- `CHG_MODE=auto`（默认）按节点可写性自动选；`switch` / `soc` 可强制指定。
- soc 通道下「停止」写 5、「恢复」写 100。接管前的节点原值记在 `/data/adb/netbatt/soc.orig`，停用控制器会还原，不会顶掉系统自带的充电保护。
- 其它机型节点不同的话，改 `config.sh` 里的 `CHG_SWITCH`（switch 通道）或 `SOC_PATH`（soc 通道）即可。探测顺序：`qcom-battery/input_suspend` → `battery/input_suspend` → `charger/charging_enabled` → `battery/charging_enabled` → `battery/batt_slate_mode`。

## 安装

1. 将仓库打包为 zip（`netbatt/` 目录内容需位于压缩包根部）。
2. Magisk 刷入，重启。
3. 桌面出现 `NetBatt`，或浏览器访问 `http://<手机IP>:8080`。

## 实现要点

- 热点走系统原生 SoftAP，由随模块安装的特权应用（`TETHER_PRIVILEGED`）通过 `TetheringManager` 控制。
- 控制台是 busybox httpd + CGI，无外部依赖。
- USB 侧由模块自行配置地址并运行 dnsmasq；上游路由、NAT、转发规则每 5 秒校正一次。
- 端口转发使用独立 iptables 链，DNAT 目标从 DHCP 租约实时读取，设备换 IP 无需改动配置。

## 验证机型

| 机型 | 平台 | 充电通道 | 状态 |
|---|---|---|---|
| 小米 11（venus） | 骁龙 888 | switch · `qcom-battery/input_suspend` | 已跑通 |
| vivo V2121A | 天玑 mt6893 | soc · `battery/keep_chg_soc` | 已跑通 |

天玑机上 `battery/input_suspend` 是 0444 只读，写不进去（返回 Permission denied），所以这类机型不能沿用开关节点，只能走目标电量通道。

## 已知限制

- 系统 IpServer 独占 67 端口，热点开启时模块的 dnsmasq 无法工作。新设备接入 USB 需在热点关闭状态下获取地址。
- 热点与 USB 为三层互通：`IP:端口` 可直连，跨网段的广播发现（mDNS / SSDP / DLNA）不工作。
- USB 口供电通常只有 5V/0.5A，热点与亮屏同时运行时电量可能负增长。
- soc 通道机型上，部分平台的 `current_now` 充电时为负值，模块已按 `status` 统一符号；仍有个别平台满电后停在 `Discharging` 数秒才切 `Charging`，属充电 IC 的保护延迟。
- 热点接口名按 `wlan2 / ap* / swlan*` 匹配，接口名特殊的机型需在 `downstream()` 里补一条。
