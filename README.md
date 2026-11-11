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

## USB 侧 DHCP：为什么只能临时接管

热点开启时，DHCP 服务由 `system_server` 持有，实测绑定如下：

```
UNCONN  0  0  0.0.0.0%ap0:67  0.0.0.0:*  users:(("system_server",pid=1439,fd=681))
```

`%ap0` 是 ss 对 `SO_BINDTODEVICE` 的表示，说明它绑死在热点接口上。而 `/system/bin/dnsmasq` 是 2.51，DHCP socket 只能绑通配地址，四种写法全部实测失败：

| 写法 | 结果 |
|---|---|
| `-i ap0`（默认端口） | `failed to bind DHCP server socket: Address already in use` |
| `-a 192.168.105.247`（ap0 实际地址） | 同上 |
| `-z --bind-interfaces -i ap0` | 同上 |
| `-z --bind-interfaces -i wlan0`（完全无关的接口） | 同上 |

其中第三、四条最关键：`-z` 只影响 DNS 监听和收包接口过滤，DHCP socket 依旧是 `0.0.0.0:67`；换成无关接口也一样失败，说明失败原因不是地址冲突，而是这两条服务都要占同一个通配端口。

**结论：靠配置让 dnsmasq 只绑 `192.168.8.1:67` 走不通**，必须换实现——自己写一个带 `SO_BINDTODEVICE` 的最小 DHCP 服务才有可能与系统并存。那个方向没有在本模块里实施。

## USB DHCP 调度状态机

既然只能接管，就把接管做严谨，每一步都靠观测而不是固定 sleep：

| 步骤 | 做什么 | 判定与超时 |
|---|---|---|
| 触发 | USB 在线、未被用户关闭、接口存在、对端没有本网段地址 | 冷却期内直接跳过（180 秒） |
| 1 | 记下热点原始状态，关热点让出 67 | 等 67 真正空闲，最多 10 秒 |
| 2 | 起 dnsmasq 只服务 USB 接口 | 3 秒内必须看到 67 被占，否则回滚 |
| 3 | 等对端拿到 `192.168.8.2` | ARP 出现 REACHABLE/STALE 且非 169.254，最多 25 秒 |
| 4 | 撤掉 dnsmasq | 等 67 释放，最多 6 秒 |
| 5 | 还原热点 | 如果原本开着，等系统 DHCP 重新占住 67，最多 15 秒 |

保护措施：

- 全流程 `mkdir` 原子锁，陈旧锁超过 120 秒自动接管。
- 任一步超时都回滚：先撤 dnsmasq、等端口释放，再把热点还原成本来的样子。
- 原来热点是关着的，绝不擅自打开（`ap.orig` 记录）。
- USB 拔掉导致的退出不算失败，不进冷却；分配失败才进 180 秒冷却。
- 失败原因写进 `/data/adb/netbatt/dhcp.last`，状态写进 `dhcp.state`。
- 67 端口检测不只看 `ss`：先看 `ss -lun`，取不到时回退解析 `/proc/net/udp`（端口 0043）；客户端是否拿到地址看 `/proc/net/arp` 的 flags。

**这套机制的真实边界**，不粉饰：

- 它是一次性分配，不是常驻 DHCP。租期到达 50% 时客户端会续租，此时没人应答；租约过期后客户端必须重新获取，而那时热点可能正开着。所以长期方案应该是 USB 对端用静态 IP，或者换掉 DHCP 实现。
- 接管期间热点是关的。单 Wi-Fi 通道机型（如 V2121A 实测）上行会一起断，一次接管 5~30 秒，期间 USB 侧即使拿到地址也没有上游。
- `ss` 的行数变化、厂商定制 ROM 的绑定方式差异都可能让判定失真，因此每一步都配了超时兜底而不是死等。

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

USB DHCP 调度的验证进度：端口占用检测（热点关/开两种状态）、锁的互斥与重入、超时精度、冷却窗口，在 V2121A 上逐项跑过；完整六步接管需要带 `ncm0` 的机型，尚未端到端验证。

## 已知限制

- 热点与系统 DHCP 独占 67，模块只能临时接管，做不到常驻服务；详见上面的「USB 侧 DHCP」两节。
- 热点与 USB 为三层互通：`IP:端口` 可直连，跨网段的广播发现（mDNS / SSDP / DLNA）不工作。
- USB 口供电通常只有 5V/0.5A，热点与亮屏同时运行时电量可能负增长。
- soc 通道机型上，部分平台的 `current_now` 充电时为负值，模块已按 `status` 统一符号；仍有个别平台满电后停在 `Discharging` 数秒才切 `Charging`，属充电 IC 的保护延迟。
- 热点接口名按 `wlan2 / ap* / swlan*` 匹配，接口名特殊的机型需在 `downstream()` 里补一条。
