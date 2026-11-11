# NetBatt

安卓（Magisk）上的网络共享与供电控制模块。

## 功能

- **热点管理** — 网页开关热点、查看已连接设备，被系统关闭后自动恢复。
- **USB 共享** — 默认交给系统 tethering（兼容性最好，对端所见与插随身 WiFi 一致），系统没建出接口时才回退模块自建；网卡出现后控制台可在对端用 `http://<共享接口IP>:8080` 打开。
- **访问地址** — 页面顶部直接给两个地址：接 USB 的对端用哪个、连热点的设备用哪个，哪个链路没开就标未开启，不再写 `127.0.0.1`。
- **端口转发** — 热点侧访问本机指定端口的流量转到 USB 侧设备，默认不转发，端口可增删；页面上直接给出「几条规则、转到哪、生不生效」。
- **状态说明** — 手机网络、连进来的设备数、USB 连接、谁在发 IP，四项各一句人话，不看术语也能判断问题在哪。
- **充电控制** — 按电量上下限自动启停充电，带温度保护，显示实时充放电功率。
- **无线 ADB** — 网页开关 adbd 的 TCP 端口，带开机自启开关，不写 `persist` 属性；显示的连接地址只取对端可达的链路。
- **运行日志** — 自带 3MB 滚动日志 + 30 秒周期采样，网页可看可一键导出到 Download 目录，车机上不要 adb 也能排障。
- **页面刷新** — 右上角「刷新」强制重载；模块升级后页面构建号对不上会自动换地址，不用手动清 WebView 缓存。

## 充电通道

两套通道，按机型自动识别，结果在网页上直接显示：

| 平台 | 通道 | 节点 | 语义 |
|---|---|---|---|
| 高通（小米 11 等） | switch | `/sys/class/qcom-battery/input_suspend` | `0` 充电 / `1` 暂停 |
| 联发科 · vivo | soc | `/sys/class/power_supply/battery/keep_chg_soc` | 写入目标电量，充到即停 |

- `CHG_MODE=auto`（默认）按节点可写性自动选；`switch` / `soc` 可强制指定。
- soc 通道下「停止」写 5、「恢复」写 100。接管前的节点原值记在 `/data/adb/netbatt/soc.orig`，停用控制器会还原，不会顶掉系统自带的充电保护。
- 其它机型节点不同的话，改 `config.sh` 里的 `CHG_SWITCH`（switch 通道）或 `SOC_PATH`（soc 通道）即可。探测顺序：`qcom-battery/input_suspend` → `battery/input_suspend` → `charger/charging_enabled` → `battery/charging_enabled` → `battery/batt_slate_mode`。

## USB 网络类型：对端看不到网卡先改这里

对端完全看不到网卡，不是 DHCP 问题，是手机这端给的 USB 网络 class 对端内核不认。同一根线插电脑正常、插车机连网卡都不出现，就是这种情况。

| 类型 | 对端要求 | 兼容性 |
|---|---|---|
| RNDIS | `rndis_host` | 最好，Android/Windows/Linux 都有，随身 WiFi 基本都是这一类 |
| NCM | `cdc_ncm` | Windows 10+ 自带；很多车机和老 Linux 没有 |
| ECM | `cdc_ether` | 对端表现为 `eth*`，但手机 gadget 必须存在 `ecm` function |

默认 `auto`，按 `rndis > ecm > ncm` 挑一个。网页上可以直接指定。指定的类型本机不存在时接口会拒绝切换，不会把 USB 弄断。

**但这台机器上直接改 `sys.usb.config` 是空转。** 实测（V2121A / Android 11 / mt6893）：

```
setprop sys.usb.config rndis,adb
  → getprop 回显 rndis,adb          ← 看起来成功了
  → /config/usb_gadget/g1/functions/ 多出 rndis.gs4   ← 目录也建了
  → /config/usb_gadget/g1/configs/b.1/ 仍然是
      f1 → mtp.gs0, f2 → mass_storage.usb1, f3 → ffs.adb   ← 没链接
  → ip link 里没有 rndis0 / usb0     ← 内核根本没建网卡
```

function 只有在被链接进 configuration 并在 UDC 绑定时才 bind、才创建 netdev。这条链接是厂商 HAL 做的，写属性不会触发。所以对端什么都看不到，`sys.usb.config` 却骗你说成功了。

走系统 `TetheringManager` 就正常：接口立刻出现，地址由系统分配（每次网段不同，实测 192.168.16.x / 192.168.83.x）。

因此 v2.8.0 起 **USB 共享一律先走系统 tethering**，`wait_for 12` 内没建出接口才回退自建。`USB_NATIVE=1`（默认）表示只信系统、不回退；改 `0` 才允许回退。回退的那条路只对接受 `sys.usb.config` 的 ROM 有效。

网页「USB 类型」那行的后缀就是这里的状态：`系统共享` = 网卡真建出来了；`模块自建 · 未链接` = 属性设了但没生效，只有这种 ROM 才会出现。

v3.1.0 起页面只列**本机 gadget 真有**的类型：读 `/config/usb_gadget/*/functions`，没有的那个直接画成禁用并注明「本机不支持」。V2121A 只有 `rndis`，所以 NCM / ECM 两个按钮是灰的——以前能点但点了没用，纯属误导。

## 端口转发：三个前提，缺一个就不通

链上只挂 DNAT 是不够的。v3.1.0 之前只往 `nat` 表里写了规则，页面显示「已开启」，实际一个包都过不去，原因有三处，都在 `nat` 之外：

| 前提 | 缺了会怎样 | 现在怎么补 |
|---|---|---|
| `ip_forward=1` | 包到了本机就停，不转发 | `apply` 与 `sync_fwd` 每次置 1 |
| 对端网段有 `lookup main` 的策略路由 | DNAT 改完目的地址后找不到出口，直接丢 | 按实测网段加 `ip rule to <net> lookup main pref 3500` |
| `FORWARD` 放行 | netd 的 `tetherctrl_FORWARD` 默认 DROP，包死在最后一步 | 热点网段、对端网段、模块网段三者两两 ACCEPT |

第三条是最隐蔽的一条：老版本只放行模块自己的 `192.168.8.0/24`，而系统 tethering 会把对端放到它自己选的网段（实测 `16/66/83/103/152` 段都见过），DNAT 后的包根本不在放行名单里。**规则全在、就是不通**，就是这么来的。

另外两处加固：

- 跳转链改为按 `ap_iface` 实测名挂，不再写死 `wlan2 ap0 softap0 swlan0`（漏 `wlan1` 和厂商自定义名，规则建了也没包进来匹配）。
- 不知道对端地址时**不下 DNAT**：以前会兜底填 `192.168.8.2`，系统 tethering 换了网段就指向一个不存在的主机。现在页面直接说「规则已建，但对端还没连上」。

排查顺序按页面提示走：`fwd_state` 为 `no_peer` 是目标未知（USB 侧还没连上），`no_usb` 是压根没有网卡，`no_rule` 是规则没建成（重加一次端口即可）。

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

### v3.1.0：接管默认关闭

接管要先把热点关掉才能拿到 67，代价太大，现场还引出了两个新问题：

- 开过无线 ADB 之后热点起不来。adbd 重启会让 USB 重新枚举，触发一轮接管；热点被关掉后系统 tethering 的状态没跟着回来，页面就一直显示「未开启」，按开启也没反应。
- 热点恢复后短时间内连上来的设备可能拿到模块网段的地址，表现为「热点开着、能连上，但没有网」。

所以 `USB_DHCP_TAKEOVER` 默认 `0`：不关热点、不抢 67，USB 端的地址交给系统 tethering。系统没接管、又确实需要对端拿地址时，在 `/data/adb/netbatt/config.sh` 里改成 `1` 再重启模块，代价是接管那几十秒热点会断一次。下面几节记录的是这条路打开时的实现细节。

### v3.1.2：修 dnsmasq 震荡

接管关闭后，日志里出现过 `模块自建 dnsmasq` 与 `接管已关闭` 每 5 秒交替刷屏、dnsmasq 起了又停的死循环——这正是「热点开着但没网、USB 对端拿不到 IP」的直接原因：dnsmasq 每次刚起就被下一轮杀掉，租约永远发不出去。

两个根因，都修了：

1. **状态 key 冲突**：`apply` 的 DHCP 三分支用 `log_chg dhcpw` 记 `self`/`sys`，`usb_dhcp_tick` 在接管关闭时也用同一个 `dhcpw` 记 `off`。两把 key 同名、值不同，每 5 秒互相覆盖，`apply` 下一轮看到值变了就再 `sync_dnsmasq` 一遍。现改为独立 key `take`，互不干扰。
2. **让位迟滞**：系统 tethering 建立的那几秒里 `sys_dhcp_any` 会时有时无，`apply` 若每次都立刻切回自建，dnsmasq 就在「让位/自建」之间高频起停。现在一旦进入让位（热点开或系统接管），至少保持 20 秒冷却，确认系统真的没接管了才允许自建。

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

**USB 链路与上行是两个独立指标**，网页上是分开的两个状态。单 Wi-Fi 通道机型开热点会让 `wlan0` 掉线、上行中断，但那不是 USB DHCP 失败；把两者混成一个结论就会误判。

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

## 无线 ADB

开关只写运行时属性 `service.adb.tcp.port`，不碰 `persist.adb.tcp.port`：

```
setprop service.adb.tcp.port 5555
setprop ctl.restart adbd
```

- 「永久」由模块在开机后恢复（`adb_tcp_restore`，等 adbd 真起来再改端口，太早设会被 init 覆盖）。
- 不写 `persist` 那条的原因：vivo 的开发者选项读到它非空就直接拒绝进入；而且禁用 Magisk 模块也不会清掉它，属性还留在 persist 分区里。页面检测到残留会显示「清理 persist 残留」按钮，同时删 `/data/property/persist.adb.tcp.port` 文件和内存属性——只删内存属性重启会从文件里读回来。
- adbd 监听 `0.0.0.0`，所以每条链路上的地址都能连。页面只列**对端真能走到的**地址：
  USB 共享接口、热点接口、`wlan0`，最多两条；蜂窝地址（`ccmni`/`rmnet`，运营商内网）不列，
  拿它去连一定失败。`127.0.0.1` 是手机自己，页面上不再出现。
- **和热点不冲突。** v3.1.0 起 DHCP 接管默认关闭，开关无线 ADB 不会再顺带把热点关掉；
  以前「开了无线 ADB 热点就起不来」的根因就在那条接管路径上，不是 adbd 本身。
- 开机自启是独立开关（`ADB_BOOT`，默认开）：开机后等 adbd 起来再延迟 5 秒才设端口，
  太早设会被 init 的默认值盖回去，表现为「已配置，未监听」。实测 V2121A 重启后约 9 秒挂上 5555。
- 如果装过别的「ADB over WiFi 常驻」模块（例如 id 为 `adb_tcp_5555` 的），它的 `post-fs-data.sh` 每开机会重新写回 `persist.adb.tcp.port=5555`，本模块清掉也会被它写回来，必须先把那个模块卸载。只停用不够——停用只是不执行脚本，已经写进 persist 分区的属性还在。
- 页面显示三态：已关闭 / 监听中 / 已配置未监听。最后一种说明 adbd 没起来或被 ROM 顶掉了。

## 运行日志

车机上没有 adb、也不方便导 logcat，所以模块自己记一份，落在 `/data/adb/netbatt/`：

- 当前文件 `netbatt.log`，写满 `LOG_MAX`（默认 3145728 字节，即 3MB）后滚成 `netbatt.log.1`，只保留一份历史，磁盘占用最多约 6MB。
- 记录的是状态跳变，不是每轮快照：`loop.sh` 每 5 秒跑一次 `apply`，`log_chg` 用 `$DATA/logv.*` 存上次取值，值不变就不写。幂等动作（保活重复拉起、DHCP 轮询）因此不会把 3MB 刷满。
- 充放电曲线走独立的**周期采样**：`sample_once` 每 5 秒读一次电量/电流/电压/温度，按 `SAMPLE_INT`（默认 15 秒）降采样成一行 `采样: 76% 放 -4.2W -1050mA 31.0℃`；间隔内五项全同就跳过，不会堆重复行。15 秒一行约 21KB/小时，3MB 能盖 6 天以上。想更密在 `config.sh` 里调小 `SAMPLE_INT`。
- 内容：启动快照（版本、Android 版本、平台、gadget functions、充电通道）、网段与下游接口变化、USB 功能切换与结果、dnsmasq 起停与未监听原因、DHCP 接管每一步与失败原因、USB 链路状态、充电结论变化、周期采样、ADB / 网段 / 阈值 / 转发等用户动作。
- 网页「运行日志」显示最近 150 行，可刷新、清空、导出。
- **导出**：点「下载」不是走浏览器附件（WebView 壳没实现下载监听，`Content-Disposition` 会被静默吞掉），而是由 root 直接把整份日志落盘到 `/sdcard/Download/netbatt.log`，页面提示路径，用文件管理器就能取。桌面浏览器里仍可用 `/cgi-bin/api.sh?a=log&full=1` 原始下载。
- 走纯文本接口，不占 JSON：`a=log&n=200` 取尾部，`a=logdump` 导出到 Download，`a=logclear` 清空。

`log_clear` 会同时删掉 `logv.*` 与采样去重标记，所以清空后的第一次 `apply` 会重新记一遍当前状态，采样也从零开始，不会留下“状态没变所以一直不记”的空窗。

## 安装

1. 将 `netbatt/` 目录内容打成 zip，**条目必须是正斜杠**（用 PowerShell `Compress-Archive` 会写反斜杠，装上去目录结构全废）。
2. Magisk 刷入，重启。
3. 桌面出现 `NetBatt`，或浏览器访问 `http://<手机IP>:8080`。

## 实现要点

- 热点走系统原生 SoftAP，由随模块安装的特权应用（`TETHER_PRIVILEGED`）通过 `TetheringManager` 控制。
- 控制台是 busybox httpd + CGI，无外部依赖。
- USB 侧默认由系统 tethering 配地址、发 DHCP；模块只在系统没接管时才自建，且接管默认关闭。
- 端口转发除了 `nat` 表的 DNAT，还要 `ip_forward`、策略路由、`FORWARD` 三条一起配合，见上面的专节。

## 验证机型

| 机型 | 平台 | 充电通道 | 状态 |
|---|---|---|---|
| 小米 11（venus） | 骁龙 888 | switch · `qcom-battery/input_suspend` | 充电通道已跑通，NetBatt 模块未实装 |
| vivo V2121A | 天玑 mt6893 | soc · `battery/keep_chg_soc` | 模块已实装，充电 / 热点 / USB 共享均实测 |

天玑机上 `battery/input_suspend` 是 0444 只读，写不进去（返回 Permission denied），所以这类机型不能沿用开关节点，只能走目标电量通道。

USB DHCP 的验证进度：V2121A 上跑通了「热点关闭 + USB 共享」这条主路径——dnsmasq 常驻在 `rndis0:67`，电脑完成 `DISCOVER → OFFER → REQUEST → ACK` 并拿到 `192.168.8.5`，网页识别到客户端、`usb_net=ok`。

**未验证的是「热点开着时插新设备 → 六步接管」**：这次测试全程热点处于关闭状态，接管流程没有触发（V2121A 的 USB 网卡是 `rndis0` 而非 `ncm0`——v2.6.0 起默认就走 RNDIS，不再写死 ncm）。三层判定（构造 DHCPREQUEST 拿真实 `DHCPACK`、验证「无新增不认旧记录」）、锁的互斥与重入、超时精度、冷却窗口、崩溃恢复与周期锁，都是函数级验证过的。

另外用 `veth` + 网络命名空间在本机造过链路：dnsmasq 侧能看到 `DHCPDISCOVER → DHCPOFFER`，但客户端收不到回包（虚拟链路 + Android 网络栈的限制，`veth1` 收发计数为 0），所以**广播修复的实际效果只能在真实 `ncm0` 上确认**。

## 已知限制

- 热点与系统 DHCP 独占 67，模块做不到常驻 DHCP；v3.1.0 起默认不接管（见「USB 侧 DHCP」最后一节），需要时手动打开。
- 接管能否成功依赖客户端主动发 DHCP。对端如果已缓存旧地址、或用了静态 IP，接管流程会走完但不会产生 ACK，此时靠邻居表兜底记 `ack_missing`。
- 热点与 USB 为三层互通：`IP:端口` 可直连，跨网段的广播发现（mDNS / SSDP / DLNA）不工作。
- USB 口供电通常只有 5V/0.5A，热点与亮屏同时运行时电量可能负增长。
- soc 通道机型上，部分平台的 `current_now` 充电时为负值，模块已按 `status` 统一符号；仍有个别平台满电后停在 `Discharging` 数秒才切 `Charging`，属充电 IC 的保护延迟。
- 热点接口名自动匹配 `wlan2 / ap0 / swlan0 / softap0 / wlan1`，并回退查 `iw dev` 里的 AP 模式接口；完全自定义命名的 ROM 仍可能漏判。
- USB 网络类型只能换手机这端给的 class，对端内核没有对应驱动时无解（手机侧没有权限替换对端驱动栈）。
- 无线 ADB 监听所有接口且不做来源限制，同一网段内任何设备都能连；内网使用可以接受，别接到不可信的网络。
