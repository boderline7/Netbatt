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

## 成功怎么判定：三层，以 ACK 为准

把「ARP 出现」当成「地址分配成功」是不成立的。ARP 只说明邻居表里有解析记录，不能证明 `DISCOVER → OFFER → REQUEST → ACK` 走完了。而且 `/proc/net/arp` 的 Flags 只有 `0x0/0x2` 两态，**没有** NUD 的 REACHABLE/STALE——要看那个状态必须读 `ip neigh`。

| 层次 | 检测内容 | 判定方式 | 作用 |
|---|---|---|---|
| 第一层 | DHCP 服务启动 | dnsmasq 进程活着 + 67 被它占住 | 排除「起了但没监听」 |
| 第二层 | DHCP ACK 已发出 | `logcat` 里 `DHCPACK(<iface>) 192.168.8.x <mac>` 且计数比接管前有新增 | **主要成功依据** |
| 第三层 | 客户端已入网 | `ip neigh show dev <iface>` 出现 REACHABLE/STALE/DELAY | 辅助验证 |

两个实现上的坑，都是实测出来的：

- **日志不在文件里。** dnsmasq 在 Android 上把日志交给 logd，`-l` 指定的文件只有缓冲后的残片（实测接管结束仍为 0~36 字节），不能实时读。所以 ACK 只能从 `logcat -d -s dnsmasq` 取。行格式实测为
  `I/dnsmasq ( 9291): 287454020 DHCPACK(veth0) 192.168.8.2 aa:17:2c:06:b3:5b`。
- **`-l` 和 `-L` 不是一回事。** `-l` 是日志文件，`-L` 才是租约文件。旧版误用 `-l` 指向 `dnsmasq.leases`，于是一边把日志写进这个文件、一边又把它当租约解析。已改正为 `-L`，并且 `usb_peer()` 改成邻居表优先——infinite 租约下租约文件不一定及时落盘，不能当唯一来源。

另外 `--dhcp-broadcast` 是带可选 tag 的选项，**必须写 `=接口名`**：单写会把后面一个参数吃掉（`-L` 就是这样被吃掉、租约文件一直不生成），放最后又会解析失败直接退出。`sync_dnsmasq` 现在按接口逐个生成 `-i <iface> --dhcp-broadcast=<iface>`。

## USB DHCP 调度状态机

既然只能接管，就把接管做严谨，每一步都靠观测而不是固定 sleep：

| 阶段 | 做什么 | 判定与超时 |
|---|---|---|
| `hotspot_stopping` | 记下热点原始状态，关热点让出 67 | 等 67 真正空闲，最多 10 秒 |
| `dnsmasq_starting` | 起 dnsmasq 只服务 USB 接口 | 3 秒内进程在且 67 被占，否则回滚 |
| `wait_client` | 等 DHCP ACK | 25 秒内出现新增 ACK；没有 ACK 但邻居已解析则记 `ack_missing` |
| `dnsmasq_stopping` | 撤掉 dnsmasq | 等 67 释放，最多 6 秒 |
| `hotspot_restoring` | 还原热点 | 如果原本开着，等系统 DHCP 重新占住 67，最多 15 秒 |
| `verify_restored` | 落地校验（见下） | 立刻 |

**落地校验**——这一步是「当场成功、长期偶发失效」最容易漏掉的。临时分配成功不等于长期可用，热点重新接管 DHCP 之后要回头确认三件事，结果写进 `usb.net`：

| 结果 | 含义 |
|---|---|
| `ok` | 网关地址还在、无网段冲突、对端仍可解析 |
| `no_gw` | USB 接口上的 `192.168.8.1` 没了（系统改掉了接口地址） |
| `conflict` | 除 USB 外还有别的接口落在同一个 `/24`，两个 DHCP 会互相打架 |
| `no_peer` | 邻居表里没有本网段的已解析记录 |
| `down` | 没有 USB 接口 |

保护措施：

- 全流程 `mkdir` 原子锁，陈旧锁超过 120 秒自动接管；上一轮被强杀留下的过期锁会在下一轮 `apply` 里就地触发恢复。
- 任一步超时都回滚：先撤 dnsmasq、等端口释放，再把热点还原成本来的样子。
- 原来热点是关着的，绝不擅自打开（`ap.orig` 记录）。
- USB 拔掉导致的退出不算失败，不进冷却；分配失败才进 180 秒冷却。
- **同一个 USB 连接周期只接管一次**（`dhcp.cycle`）。接管进行中的后续触发只更新状态，只有 USB 真正断开重连才允许再走一遍完整流程，避免设备反复插拔导致热点被反复关开。
- 失败原因写进 `/data/adb/netbatt/dhcp.last`，阶段写进 `dhcp.state`。
- 开机时 `init` 会调 `dhcp_recover`：不管上次停在哪一阶段，都按**真实系统状态**收尾——残留 dnsmasq 一律清掉，热点只在「记录为开、现在关着」时才开回来，然后清锁。不盲信阶段文件。

**USB 链路与上行是两个独立指标**，网页分两行显示。单 Wi-Fi 通道机型开热点会让 `wlan0` 掉线、上行中断，但那不是 USB DHCP 失败；把两者混成一个结论就会误判。

**这套机制的真实边界**，不粉饰：

- 它是一次性分配，不是常驻 DHCP。infinite 租约下客户端不会进入 T1/T2 续租，所以「续租无人应答」在同一段连接内不成立；真正的问题在**重新获取**——客户端断开重连、重启或主动 RELEASE 后要重新 DISCOVER，而那时热点可能正开着。长期方案应该是 USB 对端用静态 IP，或者换掉 DHCP 实现。
- 接管期间热点是关的。单 Wi-Fi 通道机型（如 V2121A 实测）上行会一起断，一次接管 5~30 秒，期间 USB 侧即使拿到地址也没有上游。
- `ss` 的行数变化、厂商定制 ROM 的绑定方式差异都可能让判定失真，因此每一步都配了超时兜底而不是死等。
- 完整的六步接管需要真实 `ncm0` 链路，V2121A 上没有该接口，只能在小米 11 上验证。

## 真机实测

2026-11-11 在 vivo V2121A（天玑 mt6893 / Android，Magisk 28104）上装包跑通全流程，途中修掉六个真实缺陷：

| 缺陷 | 现象 | 原因 |
|---|---|---|
| zip 条目用了反斜杠 | 装完模块目录里只有 `module.prop`，`bin\loop.sh` 被当成单个文件名 | 用 PowerShell `Compress-Archive` 打包，中央目录写的是 `\`；必须用正斜杠打包 |
| CGI 无执行位 | 首页 200，但 `/cgi-bin/api.sh` 一律 404 | Magisk 解压不保留 zip 里的权限，`api.sh` 是 644；需在 `post-fs-data.sh` 里补 chmod |
| 热点接口名写死 `wlan2` | 热点开着但 `ap=0`，USB DHCP 调度永不触发 | vivo 的热点接口叫 `ap0` |
| 热点接口残留导致误判 | 热点已关，状态机却以为开着，关热点→等 67 超时→假失败并杀掉 dnsmasq | `ap0` 关闭后残留为 `state DOWN`，只看接口存在不够，必须同时有 IPv4 地址 |
| USB 网卡没 `up` | 地址配上了但包发不出去，对端一直停在 169.254 | 切换 `sys.usb.config` 后 `rndis0` 停在 DOWN，只配地址不够 |
| 单地址池拿不到地址 | dnsmasq 收到 DISCOVER 回 `no address available` | `-F 192.168.8.2,192.168.8.2` 只有一个地址时不可用，扩到 `.2-.10` 立刻正常 |
| 与系统 tethering 抢同一接口 | 对端拿到 `192.168.66.x` 却连不上 `192.168.8.1`，dnsmasq 每 8 秒 bind 失败 | 系统已接管时模块仍改地址、抢 67；改为检测到就让位（见下节） |

顺带把 SNAT 的 `-o ncm0` 改成按实际 USB 接口生成（vivo 是 `rndis0`），以及 `web` 地址改为热点接口的真实 IP。

端到端结果：

- USB：电脑识别为 `Remote NDIS based Internet Sharing Device`，DHCP 拿到 `192.168.8.5`（`PrefixOrigin=Dhcp`），`ping 192.168.8.1` 3/3 通、0ms，网页与 API 都能从 USB 侧访问。
- 热点 + USB 共存：`ap0` 与 `rndis0` 同时在，`status` 里 role 分别标成 `hotspot` / `usb`，电脑（USB 侧）能直接打开热点侧地址（HTTP 200），跨网段 FORWARD 规则双向生成。
- 充电：改阈值 3 秒内起停（`Charging(-281.9mA) → Discharging(+170.8mA)`），把上限温度压到 10℃ 能触发停充、改回即恢复；停用控制器会把 `keep_chg_soc` 还原成接管前的值。

系统热点的网段由 `TetheringManager` 自己选，实测三次分别是 `192.168.138.0/24`、`192.168.91.0/24`、`192.168.218.0/24`，跟模块设的 `192.168.8.0/24` 不是一回事。所以「热点与 USB 同网段」这个目标在这类机型上做不到，实际靠 iptables 的跨网段 FORWARD 保证互访。

## 系统 tethering 抢先接管时

开 `sys.usb.config=ncm,adb` 之后，系统有时会立刻接管这条链路：`dumpsys tethering` 显示 `rndis0 - TetheredState`，67 绑在 `0.0.0.0%rndis0:67`，并按它自己选的网段发地址（实测 `192.168.66.x`，DHCP 服务器 `192.168.66.241`）。

这时模块若照旧操作就是纯破坏：

- 把接口地址改成 `192.168.8.1`，对端拿到 `66.x` 却连不上 `8.1` 的机器，链路等于被改坏；
- 起 dnsmasq 抢 67，每 8 秒 `failed to bind DHCP server socket` 刷一次日志。

所以 `apply` 里按 `sys_dhcp_on` 分流，两种情形都能正常工作：

| 场景 | 67 持有者 | 接口地址 | 模块行为 |
|---|---|---|---|
| 系统未接管 | 模块的 dnsmasq | `192.168.8.1` | 自己服务 DHCP，地址池 `.2-.10` |
| 系统已接管 | `system_server` | 系统自选（如 `192.168.66.x`） | 完全让位：不改地址、不起 dnsmasq，只保留转发与互访规则 |

`status` 里的 `sys_dhcp` 字段表示当前是否让位（1 = 系统在服务）。两种场景下 `clients` / `target` 都能正确定位对端，端口转发照常生效。

## 安装

1. 将 `netbatt/` 目录内容打成 zip，**条目必须是正斜杠**（用 PowerShell `Compress-Archive` 会写反斜杠，装上去目录结构全废）。
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
| 小米 11（venus） | 骁龙 888 | switch · `qcom-battery/input_suspend` | 充电通道已跑通，NetBatt 模块未实装 |
| vivo V2121A | 天玑 mt6893 | soc · `battery/keep_chg_soc` | 模块已实装，充电 / 热点 / USB 共享均实测 |

天玑机上 `battery/input_suspend` 是 0444 只读，写不进去（返回 Permission denied），所以这类机型不能沿用开关节点，只能走目标电量通道。

USB DHCP 的验证进度：V2121A 上跑通了「热点关闭 + USB 共享」这条主路径——dnsmasq 常驻在 `rndis0:67`，电脑完成 `DISCOVER → OFFER → REQUEST → ACK` 并拿到 `192.168.8.5`，网页识别到客户端、`usb_net=ok`。

**未验证的是「热点开着时插新设备 → 六步接管」**：这次测试全程热点处于关闭状态，接管流程没有触发（V2121A 的 USB 网卡是 `rndis0` 而非 `ncm0`，但接口名已覆盖）。三层判定（构造 DHCPREQUEST 拿真实 `DHCPACK`、验证「无新增不认旧记录」）、锁的互斥与重入、超时精度、冷却窗口、崩溃恢复与周期锁，都是函数级验证过的。

另外用 `veth` + 网络命名空间在本机造过链路：dnsmasq 侧能看到 `DHCPDISCOVER → DHCPOFFER`，但客户端收不到回包（虚拟链路 + Android 网络栈的限制，`veth1` 收发计数为 0），所以**广播修复的实际效果只能在真实 `ncm0` 上确认**。

## 已知限制

- 热点与系统 DHCP 独占 67，模块只能临时接管，做不到常驻服务；详见上面的「USB 侧 DHCP」两节。
- 接管能否成功依赖客户端主动发 DHCP。对端如果已缓存旧地址、或用了静态 IP，接管流程会走完但不会产生 ACK，此时靠邻居表兜底记 `ack_missing`。
- 热点与 USB 为三层互通：`IP:端口` 可直连，跨网段的广播发现（mDNS / SSDP / DLNA）不工作。
- USB 口供电通常只有 5V/0.5A，热点与亮屏同时运行时电量可能负增长。
- soc 通道机型上，部分平台的 `current_now` 充电时为负值，模块已按 `status` 统一符号；仍有个别平台满电后停在 `Discharging` 数秒才切 `Charging`，属充电 IC 的保护延迟。
- 热点接口名自动匹配 `wlan2 / ap0 / swlan0 / softap0 / wlan1`，并回退查 `iw dev` 里的 AP 模式接口；完全自定义命名的 ROM 仍可能漏判。
