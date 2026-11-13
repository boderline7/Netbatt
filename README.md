# NetBatt

一台常年放车里的 Android 手机（Magisk root），让它自己跟着车开关热点。

v5 起只做四件事：热点随车自动化、空转保护、充电阈值、无线 ADB。
原有的 USB 网络共享（自动共享 / 保留 ADB / 网段 / 端口转发 / DHCP 接管）已整体移除，
原因见文末「为什么不做 USB 共享」。热点决策表见 [docs/热点决策表.md](docs/热点决策表.md)。

热点部分按「采集 → 决策 → 执行」拆开，三层只通过事实和目标交流：

| 层 | 文件 | 职责 |
|---|---|---|
| 采集 | `bin/nb-facts.sh` | 读 sysfs / Android，输出 `POWER` `AP_REAL` `CLIENTS` `CHG_HELD` |
| 决策 | `bin/nb-decide.sh` | 读配置 + 事实，算 `HS_TARGET`，只管意图 |
| 执行 | `bin/nb-hs.sh` / `bin/nb-chg.sh` | 让实际状态追上目标，重试、失败记录 |

## 功能

- **三种模式**：自动（跟车）/ 常开 / 关闭。
- **自动**：有电持续 5 秒开，断电持续 120 秒关。
- **常开**：有电就开、断电就关，但不参与空转保护。
- **空转保护**：自动模式下热点开着但 15 分钟没有设备连上，自动关闭；下次通电重新开启。
- **充电阈值**：上限 / 恢复 / 过温，硬件通道按平台自动识别。
- **无线 ADB**：只写运行时属性，开机按上次状态恢复。
- **运行日志**：本地 3MB 滚动，网页可看、可导出到 `/sdcard/Download`。

## 取电与检测

点烟器取电（已实测随车辆启停断电）。主信号：

```
/sys/class/power_supply/{usb,ac,dc,wireless}/present == 1 或 online == 1
```

`present` 只看插没插，不受模块自己停充影响，所以优先用它。
电池 `status == Charging` 与 `current_now > 0` 只在节点都不存在时兜底，
且**模块主动停充期间不采信**——否则充满电停充后会被误判成「车断电」。

原始信号要经过确认才叫「有电」：持续 5 秒为有电（`ON_CONFIRM`），
持续 120 秒为断电（`OFF_CONFIRM`）。这样点火时电压跌落闪一下 0 不会误清抑制标记。

## 三种模式

| 模式 | 行为 |
|---|---|
| `auto` | 有电开、断电关；15 分钟无设备自动关 |
| `on` | 有电开、断电关；不被空转关 |
| `off` | 始终保持关闭 |

`on` 和 `auto` 的唯一差别就是会不会被空转保护关掉。`on` 不是无条件常开——
车断电仍然会关，免得热点把手机电池耗干。

## 空转保护

自动模式下，热点开着且连续 `IDLE_OFF_MIN`（默认 15）分钟客户端数为 0 → 关热点。

- 客户端数用 `iw dev <ap接口> station dump` 数 `Station`，取不到时退回 `ip neigh`。
- 关闭后落 `suppress` 标记，本次供电周期内不再自动开；断电确认后自动清除。
- 手动点「立即关热点」也落同一个标记，否则自动模式下一轮就会把它重新打开。
- 恢复办法：点「立即开热点」（清标记）或断电再通电。
- 常开模式不做空转保护。

## 充电通道

两套通道，按机型自动识别，结果在网页上直接显示：

| 平台 | 通道 | 节点 | 语义 |
|---|---|---|---|
| 高通（小米 11 等） | switch | `/sys/class/qcom-battery/input_suspend` | `0` 充电 / `1` 暂停 |
| 联发科 · vivo | soc | `/sys/class/power_supply/battery/keep_chg_soc` | 写入目标电量，充到即停 |

- `CHG_MODE=auto`（默认）按平台挑通道，**不是谁先可写就用谁**：
  天玑先试 `keep_chg_soc`，其余平台先试 `input_suspend`，最后才走通用探测列表。
  两条通道语义完全不同，骁龙节点写 `5/100`、天玑节点写 `0/1` 都是无效甚至有害的，
  所以探测结果缓存在 `/data/adb/netbatt/chg.node`，网页每 5 秒刷状态不会去碰 sysfs；
  想强制重探就删掉这个文件。`switch` / `soc` 也能手动指定，但节点不存在时自动回落到探测。
- **停充不影响热点判定**。模块主动停充后电池会变成「未充电/放电」、`current_now` 归零，
  这不能当成「车断电」——采集层用 `CHG_HELD` 这个事实把它排除掉，热点只看充电器是否插着。
  否则充满电就会把正在使用的热点关掉。
- 节点写入只在状态变化时执行，另有 10 分钟兜底重写一次，防止系统在插拔/息屏后把节点改回去。
- soc 通道下「停止」写 5、「恢复」写 100。接管前的节点原值记在 `/data/adb/netbatt/soc.orig`，
  停用控制器会还原，不会顶掉系统自带的充电保护。
- 其它机型节点不同的话，改 `config.sh` 里的 `CHG_SWITCH`（switch）或 `SOC_PATH`（soc）。
  探测顺序：`qcom-battery/input_suspend` → `battery/input_suspend` → `charger/charging_enabled`
  → `battery/charging_enabled` → `battery/batt_slate_mode`。

## 无线 ADB

只写运行时属性 `service.adb.tcp.port`，**不碰** `persist.adb.tcp.port`：
写 persist 会让部分 ROM 的开发者选项直接进不去。开机恢复由 `nb-daemon.sh adb-restore` 负责，
它会等 `init.svc.adbd` 真起来再设端口。

老版本写进 persist 的 5555 不会随模块卸载消失，网页上留了「清除 persist 残留」按钮。

## 运行日志

`/data/adb/netbatt/netbatt.log`，到 `LOG_MAX`（默认 3MB）滚成 `netbatt.log.1`，只留一份历史。

- 状态跳变才记（`log_chg`），采样按 `SAMPLE_INT`（默认 15 秒）降采样且五个值全同就跳过，不刷屏。
- 车机上没法 adb 也导不出 logcat，排障基本靠这份日志。
- WebView 壳没实现 DownloadListener，所以「导出」是直接写 `/sdcard/Download/net-YYYYMMDD.log`，
  同名已存在就续 `-2`、`-3`，不覆盖。

## 文件结构

```
netbatt/
├── module.prop
├── post-fs-data.sh        特权应用与权限白名单、脚本执行位
├── service.sh             等 boot_completed → 清 WebView 缓存 → 起守护
├── uninstall.sh           停网页、杀守护
├── bin/
│   ├── nb-core.sh         路径 / 配置 / 日志
│   ├── nb-facts.sh        采集层：供电确认、热点实况、客户端数、停充状态
│   ├── nb-decide.sh       决策层：模式 + 事实 -> HS_TARGET
│   ├── nb-hs.sh           热点执行器
│   ├── nb-chg.sh          充电执行器：通道探测 / 阈值 / 还原
│   ├── nb-adb.sh          无线 ADB
│   ├── nb-web.sh          httpd + 状态 JSON
│   └── nb-daemon.sh       10 秒一轮的常驻调度（采集→决策→执行）
├── system/                特权应用 NetBattConsole（调 TetheringManager）
└── webroot/
    ├── index.html
    └── cgi-bin/api.sh
```

旧版的 `nb-lib.sh`（91KB）、`loop.sh`、`netbatt.sh` 已删除；
v4 的 `nb-power.sh`（信号 + 决策 + 充电三合一）已拆成上面四个文件。
守护方式从「每 5 秒 fork 四个 sh」改成「一个常驻进程 sleep 10 秒」。

## 安装

```powershell
python tools/pack.py      # 产出 NetBatt-vX.Y.Z.zip 到仓库根
```

Magisk 里刷入 zip，重启。控制台：手机浏览器打开 `http://127.0.0.1:8080`，
或从特权应用 NetBattConsole 打开（走 `window.NetBatt` 桥，热点开关更直接）。
热点开起来后，同网段设备的访问地址是热点接口的局域网 IP。
