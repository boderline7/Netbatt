#!/system/bin/sh
# NetBatt 公共库：网段接管 + 设备列表 + 充电控制
MODDIR=/data/adb/modules/netbatt
DATA=/data/adb/netbatt
BB=/data/adb/magisk/busybox
[ -x "$BB" ] || BB=/system/bin/busybox
CFG=$DATA/config.sh
PORT=8080
BATT=/sys/class/power_supply/battery

mkdir -p "$DATA"

# 默认值：config.sh 里存在同名项时会覆盖，缺失项保持默认（兼容旧配置文件）
PREFIX=192.168.8
# USB 只有一台设备，池就一个地址：谁接上去都是 .2
POOL_START=2
POOL_END=10
DNS1=223.5.5.5
DNS2=119.29.29.29
PAUSE_CAP=88
RESUME_CAP=83
MAX_TEMP=45
# 充电通道：auto 按机型自动选；switch 用开关节点，soc 用目标电量节点
CHG_MODE=auto
CHG_SWITCH=/sys/class/qcom-battery/input_suspend
CHG_ON=0
CHG_OFF=1
# soc 通道（vivo/MTK）：写入目标电量，充到该值即停
SOC_PATH=/sys/class/power_supply/battery/keep_chg_soc
CHG_SOC_OFF=5
CHG_SOC_ON=100
KEEP_WIFI=0
KEEP_USB=0
# 热点设备访问本机这个端口时，转发给 USB 端那台固定设备
FWDPORT=18765
# USB 网络功能类型。对端看不到网卡时换的就是这里：
#   rndis  兼容性最好，Android/Windows/Linux 都认，随身 WiFi 基本都是这一类
#   ncm    需要对端有 cdc_ncm 驱动，Windows 10+ 自带，很多车机没有
#   ecm    对端表现为 cdc_ether(eth*)，但本机 gadget 必须存在该 function
#   auto   按对端兼容性排序挑一个真实存在的
USB_NET=auto
# 1=交给系统 tethering 全权负责（网段由系统选）；0=允许在系统失败时退回自建
# 默认 1：实测 vivo 这类 ROM 直接写 sys.usb.config 只建 functions 目录、
# 不链接进 configs，内核不建网卡，对端永远看不到设备。系统 tethering 走厂商 HAL 才有效。
USB_NATIVE=1
# 无线 ADB。只设 service.adb.tcp.port（重启即失效），持久化由本模块开机恢复，
# 绝不写 persist.adb.tcp.port —— 那条属性会让 vivo 的开发者选项直接进不去
ADB_TCP=0
ADB_PORT=5555
# 开机是否自动恢复无线 ADB。开机后等 adbd 起来再延迟几秒设置，
# 太早设会被 init 覆盖，面板会显示"已配置，未监听"
ADB_BOOT=1
# USB 端拿不到地址时，是否允许模块临时关掉热点、抢 67 端口把地址发下去。
# 默认 0（关）：实测这条路径会让热点起不来、热点回来之后客户端拿到错网段的地址，
# 代价远大于收益——系统 tethering 正常时根本用不到它。
# 确实需要对端拿地址时，在 config.sh 把它设成 1，代价是接管期间热点会断一次。
USB_DHCP_TAKEOVER=0
# 运行日志单文件上限（字节）。写满滚成 netbatt.log.1，只留一份历史，最多约 2 倍
LOG_MAX=3145728
# 周期采样间隔（秒）。loop 每 5 秒一轮，太密会刷满日志，默认 15 秒记一行电量/功率
SAMPLE_INT=15

if [ ! -f "$CFG" ]; then
  cat > "$CFG" <<EOC
PREFIX=$PREFIX
POOL_START=$POOL_START
POOL_END=$POOL_END
DNS1=$DNS1
DNS2=$DNS2
PAUSE_CAP=$PAUSE_CAP
RESUME_CAP=$RESUME_CAP
MAX_TEMP=$MAX_TEMP
CHG_MODE=$CHG_MODE
CHG_SWITCH=$CHG_SWITCH
CHG_ON=$CHG_ON
CHG_OFF=$CHG_OFF
SOC_PATH=$SOC_PATH
CHG_SOC_OFF=$CHG_SOC_OFF
CHG_SOC_ON=$CHG_SOC_ON
KEEP_WIFI=$KEEP_WIFI
KEEP_USB=$KEEP_USB
FWDPORT=$FWDPORT
USB_NET=$USB_NET
USB_NATIVE=$USB_NATIVE
ADB_TCP=$ADB_TCP
ADB_PORT=$ADB_PORT
ADB_BOOT=$ADB_BOOT
USB_DHCP_TAKEOVER=$USB_DHCP_TAKEOVER
LOG_MAX=$LOG_MAX
SAMPLE_INT=$SAMPLE_INT
EOC
fi

# 老配置文件缺新键时补默认值，避免升级后行为变化
if ! $BB grep -q '^CHG_MODE=' "$CFG" 2>/dev/null; then
  cat >> "$CFG" <<EOC
CHG_MODE=auto
SOC_PATH=/sys/class/power_supply/battery/keep_chg_soc
CHG_SOC_OFF=5
CHG_SOC_ON=100
EOC
fi

# 升级上来的老配置缺新键时补默认值；已有的键一律不动
for kv in "USB_NET=auto" "USB_NATIVE=1" "ADB_TCP=0" "ADB_PORT=5555" "ADB_BOOT=1" "USB_DHCP_TAKEOVER=0" "LOG_MAX=3145728" "SAMPLE_INT=15"; do
  $BB grep -q "^${kv%%=*}=" "$CFG" 2>/dev/null || echo "$kv" >> "$CFG"
done

. "$CFG"

# v2.8.0 把默认路径切成系统 tethering。老配置里的 USB_NATIVE=0 是上一版默认值
# 灌进去的，不是用户主动选的，所以升级时按 seed 标记纠正一次；之后用户自己改的照旧。
if ! $BB grep -q '^CFG_SEED=' "$CFG" 2>/dev/null; then
  USB_NATIVE=1
  $BB sed -i 's/^USB_NATIVE=.*/USB_NATIVE=1/' "$CFG" 2>/dev/null
  echo "CFG_SEED=1" >> "$CFG"
fi

# 老配置的地址池是 2..2（单地址），实测 dnsmasq 会一直回 no address available，
# 升级上来的配置必须一起纠正，否则只有全新安装才正常
if [ -n "$POOL_START" ] && [ -n "$POOL_END" ] && [ "$POOL_END" -le "$POOL_START" ]; then
  POOL_END=$((POOL_START + 8))
  $BB sed -i "s/^POOL_END=.*/POOL_END=$POOL_END/" "$CFG" 2>/dev/null
fi

# v3.1.2 把采样间隔默认值从 30 秒收紧到 15 秒。v3.1.1 会把 SAMPLE_INT=30 写进 config，
# 而「已有键不改」的补默认值逻辑会把它保留下来，导致升级后采样还是 30 秒。
# 用独立 seed 标记：只在「还是上一版默认值 30」时纠正一次，用户自己改过的照旧。
if ! $BB grep -q '^CFG_SAMPLE_SEED=' "$CFG" 2>/dev/null; then
  [ "$SAMPLE_INT" = "30" ] && $BB sed -i 's/^SAMPLE_INT=.*/SAMPLE_INT=15/' "$CFG" 2>/dev/null
  echo "CFG_SAMPLE_SEED=1" >> "$CFG"
fi
. "$CFG"

# ---------- 运行日志 ----------
# 车机上没法 adb 也导不出 logcat，模块自己落一份到 /data/adb/netbatt。
# 单文件到 LOG_MAX（默认 3MB）就滚成 netbatt.log.1，只保留一份历史，
# 磁盘占用最多约 6MB。网页「运行日志」能直接看，也能整份下载。
LOG="$DATA/netbatt.log"
LOG1="$DATA/netbatt.log.1"

log_size() {
  [ -f "$1" ] || { echo 0; return 0; }
  n=$($BB stat -c %s "$1" 2>/dev/null)
  [ -z "$n" ] && n=$($BB wc -c < "$1" 2>/dev/null)
  echo "${n:-0}"
}

# 滚动必须在写之前做：一次写只多几十字节，超一点无所谓，不能让它无界增长。
# 这里直接 printf，不走 log()，否则递归。
log_rotate() {
  [ "$(log_size "$LOG")" -ge "${LOG_MAX:-3145728}" ] || return 0
  mv -f "$LOG" "$LOG1" 2>/dev/null
  : > "$LOG" 2>/dev/null
  printf '%s [log] 超过 %s 字节，已滚动到 %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "${LOG_MAX:-3145728}" "${LOG1##*/}" >> "$LOG" 2>/dev/null
}

log() {
  log_rotate
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
}

# 只在取值变化时记一行。loop.sh 每 5 秒跑一次 apply，无条件写会把 3MB 刷满，
# 而且真正有用的信息（状态跳变）反而被淹没。
log_chg() {
  k="$DATA/logv.$1"; v="$2"; shift 2
  [ "$($BB cat "$k" 2>/dev/null)" = "$v" ] && return 0
  printf '%s\n' "$v" > "$k" 2>/dev/null
  log "$*"
}

# 周期采样：按固定间隔记一行电量/功率快照。loop 每 5 秒一轮，5 秒就记一行
# 会把 3MB 几小时刷满，所以按 SAMPLE_INT（默认 15 秒）降采样；间隔内值没变化
# 也不记，避免长时间待机时全是重复行。落一行约 90 字节，15 秒一行 ≈ 21KB/小时，
# 3MB 日志能盖 6 天以上。
SAMPLE_INT=${SAMPLE_INT:-15}
sample_now() {
  now=$(date '+%s')
  last=$($BB cat "$DATA/sample.ts" 2>/dev/null)
  [ -n "$last" ] && [ $(( now - last )) -lt "$SAMPLE_INT" ] && return 0
  # 快照键：电量:方向:功率:电流:温度，五项全同就跳过（说明这段没实质变化）
  key="$1:$2:$3:$4:$5"
  [ "$($BB cat "$DATA/sample.k" 2>/dev/null)" = "$key" ] && return 0
  printf '%s\n' "$now" > "$DATA/sample.ts" 2>/dev/null
  printf '%s\n' "$key" > "$DATA/sample.k" 2>/dev/null
  log "采样: $1% $2 $3W ${4}mA $5℃"
}

# 最近 n 行；当前文件不够时把滚动出去的那份接在前面
log_tail() {
  n="$1"
  case "$n" in ''|*[!0-9]*) n=120;; esac
  [ "$n" -lt 1 ] && n=1
  [ "$n" -gt 2000 ] && n=2000
  cur=$($BB wc -l < "$LOG" 2>/dev/null); [ -z "$cur" ] && cur=0
  if [ "$cur" -ge "$n" ] || [ ! -f "$LOG1" ]; then
    $BB tail -n "$n" "$LOG" 2>/dev/null
  else
    { $BB tail -n "$n" "$LOG1"; $BB tail -n "$n" "$LOG"; } 2>/dev/null | $BB tail -n "$n"
  fi
}

# 整份导出：先旧后新，顺序才对
log_dump() {
  [ -f "$LOG1" ] && $BB cat "$LOG1" 2>/dev/null
  $BB cat "$LOG" 2>/dev/null
}

log_clear() {
  : > "$LOG" 2>/dev/null
  rm -f "$LOG1" "$DATA"/logv.* "$DATA"/sample.ts "$DATA"/sample.k 2>/dev/null
  log "日志已清空"
}

# 导出到用户随手能读的目录。WebView 壳没实现 DownloadListener，
# Content-Disposition 附件会被静默吞掉，所以直接由 root 落盘到 /sdcard/Download，
# 用户用文件管理器/相册都能找到。返回落盘路径，失败返回空。
log_export() {
  dst=""
  for d in /sdcard/Download /sdcard/Documents /storage/emulated/0/Download /data/media/0/Download; do
    if [ -d "$d" ] || mkdir -p "$d" 2>/dev/null; then
      dst="$d/netbatt.log"
      break
    fi
  done
  [ -z "$dst" ] && return 1
  if log_dump > "$dst" 2>/dev/null; then
    echo "$dst"
    return 0
  fi
  return 1
}

# 模块构建号，页面拿它判断自己是不是 WebView 缓存里的旧副本
nb_build() {
  v=$($BB sed -n 's/^versionCode=//p' "$MODDIR/module.prop" 2>/dev/null | $BB tr -d '\r\n ')
  echo "${v:-0}"
}

# 开机记一次环境快照：排障时第一眼看的就是这几行
log_boot() {
  ver=$($BB sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)
  rel=$($BB getprop ro.build.version.release 2>/dev/null)
  plat=$(chg_platform 2>/dev/null)
  log "===== 启动 v${ver:-?} · Android $rel · 平台 ${plat:-?} ====="
  log "配置: 网段 $GW/24 池 .$POOL_START-.$POOL_END · USB类型 $USB_NET(生效 $(usb_net_pick)) · native=$USB_NATIVE · 日志上限 $LOG_MAX"
  log "USB functions: $(usb_funcs)"
  chg_detect >/dev/null 2>&1
  log "USB 接口: $(usb_ifaces 2>/dev/null || echo 无) · 充电通道: ${CHG_CH:-?} ${CHG_NODE:-}"
}

# ---------- 网络 ----------

# 被共享的下游接口：热点(ap*/wlan1/wlan2/swlan0)、USB(rndis0/ncm0/usb0) 等。
# 排除 lo、上行 wlan0、蜂窝与默认路由所在接口。
# 已配 IP 的接口 + 刚建好还没 IP 的共享接口（ncm0/rndis0 刚拉起时没地址）
downstream() {
  DEF=$(ip route show default 2>/dev/null | $BB awk '{print $5}')
  {
    ip -o -4 addr show | $BB awk -v def="$DEF" '
      BEGIN{n=split(def,d," ");for(i=1;i<=n;i++)dv[d[i]]=1}
      $2!="lo" && $2!="wlan0" && !($2 in dv) && $2 !~ /^(rmnet|ccmni|dummy|tun)/ && $4 !~ /^127\./ {print $2}
    '
    ip -o link show | $BB awk -F': ' '{print $2}' | $BB sed 's/@.*//' | $BB awk -v def="$DEF" '
      BEGIN{n=split(def,d," ");for(i=1;i<=n;i++)dv[d[i]]=1}
      /^(rndis|ncm|usb[0-9]|ap[0-9]|softap|swlan|wlan2)/ && !($0 in dv) {print}
    '
  } | $BB sort -u | $BB tr '\n' ' ' | $BB sed 's/ *$//'
}

stop_dnsmasq() {
  if [ -f "$DATA/dnsmasq.pid" ]; then
    log "dnsmasq 停止 (pid $($BB cat "$DATA/dnsmasq.pid" 2>/dev/null))"
  fi
  [ -f "$DATA/dnsmasq.pid" ] && kill "$(cat $DATA/dnsmasq.pid)" 2>/dev/null
  pkill -f "/system/bin/dnsmasq" 2>/dev/null
  # 清掉早期实验残留在 nat 表里的重定向/DNAT 规则
  for i in ncm0 rndis0 usb0 wlan2 ap0 softap0 swlan0; do
    while iptables -t nat -D PREROUTING -i "$i" -p udp --dport 67 -j REDIRECT --to-ports 6767 2>/dev/null; do :; done
    while iptables -t nat -D PREROUTING -i "$i" -p udp --dport 67 -j DNAT --to-destination "$GW:6767" 2>/dev/null; do :; done
  done
  rm -f "$DATA/dnsmasq.pid" "$DATA/dnsmasq.ifaces"
}

# 系统热点在时会独占 0.0.0.0:67，所以只在热点没开时由我们接管 USB 端的 DHCP。
sync_dnsmasq() {
  want="$1"
  [ -z "$want" ] && { stop_dnsmasq; return 0; }
  alive=0
  [ -f "$DATA/dnsmasq.pid" ] && kill -0 "$(cat $DATA/dnsmasq.pid)" 2>/dev/null && alive=1
  if [ "$alive" = 1 ] && [ "$(cat $DATA/dnsmasq.ifaces 2>/dev/null)" = "$want" ]; then
    return 0
  fi

  stop_dnsmasq
  sleep 1

  # 租期给 24h，不用 infinite：Windows 吃得下 0xffffffff，但车机和精简
  # DHCP 客户端里有把它判成非法租期、干脆不回 ACK 的情况。热点一直开超过
  # 24 小时时客户端会在 T1 续租失败、到期掉线，重插一次即可。
  # 池不能只给一个地址：实测 dnsmasq 2.51 在 -F 192.168.8.2,192.168.8.2 时
  # 收到 DISCOVER 会直接回 "no address available"，Windows 一直停在 169.254；
  # 扩到 .2-.10 后同一客户端立刻拿到地址。
  # 注意 2.51 没有 --dhcp-sequential-ip（传了会 bad command line options 直接退出），
  # 所以具体分到哪个地址由 dnsmasq 自己决定，池内地址都可用即可，
  # 对端真实地址始终以 ARP/租约为准（usb_peer），不假设固定 .2。
  # 注意 -L（租约文件）和 -l（日志文件）是两个选项，不能混用
  # --log-dhcp：把四步交互写进 logd，ACK 判定靠它（文件日志有缓冲延迟，不可实时读）
  set -- -k -R -n -K -x "$DATA/dnsmasq.pid" -u dns_tether \
         -L "$DATA/dnsmasq.leases" --log-dhcp \
         -F "$PREFIX.$POOL_START,$PREFIX.$POOL_END,24h" \
         -O "3,$GW" -O "6,$DNS1,$DNS2" \
         --dhcp-option-force=43,ANDROID_METERED \
         -S "$DNS1" -S "$DNS2"
  # --dhcp-broadcast 是可选 tag 的选项：单独写会把后面一个参数吃掉、放末尾又会解析失败，
  # 必须用 =tag 形式（实测三种写法只有 =tag 可靠）。首次接入时对端还没有 ARP 条目，
  # 单播 OFFER 依赖邻居解析会发不出去，USB 单客户端场景强制广播无副作用。
  for i in $want; do set -- "$@" -i "$i" --dhcp-broadcast="$i"; done

  nohup /system/bin/dnsmasq "$@" > "$DATA/dnsmasq.log" 2>&1 &
  sleep 1
  echo "$want" > "$DATA/dnsmasq.ifaces"
  log "dnsmasq 启动: 接口 $want · 池 $PREFIX.$POOL_START-$POOL_END · 网关 $GW"
  if ! dhcp_serving; then
    # 2.51 参数写错会直接退出，原因只在 dnsmasq.log 里，顺手抄进运行日志
    log "dnsmasq 未监听 67: $($BB head -3 "$DATA/dnsmasq.log" 2>/dev/null | $BB tr '\n' ' ')"
  fi
}

apply() {
  # 先对齐 USB 网络功能类型，再配地址：类型切换会重建 gadget，地址得在后面配
  usb_sync_func
  A=$(ip -o -4 addr show)
  echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null

  # 系统共享没接管时自己补：共享网段走上级路由表 + NAT，客户端才能上网
  UP=$(ip route get 114.114.114.114 2>/dev/null | $BB awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  if [ -n "$UP" ]; then
    ip rule show | $BB grep -q "from $PREFIX.0/24 lookup $UP" || \
      ip rule add from "$PREFIX.0/24" lookup "$UP" pref 16000 2>/dev/null
    iptables -t nat -C POSTROUTING -s "$PREFIX.0/24" -j MASQUERADE 2>/dev/null || \
      iptables -t nat -A POSTROUTING -s "$PREFIX.0/24" -j MASQUERADE 2>/dev/null
    # netd 的 tetherctrl_FORWARD 默认 DROP，非“已共享”接口会被拦掉
    iptables -C FORWARD -s "$PREFIX.0/24" -j ACCEPT 2>/dev/null || \
      iptables -I FORWARD -s "$PREFIX.0/24" -j ACCEPT 2>/dev/null
    iptables -C FORWARD -d "$PREFIX.0/24" -j ACCEPT 2>/dev/null || \
      iptables -I FORWARD -d "$PREFIX.0/24" -j ACCEPT 2>/dev/null
  fi

  # 清掉与上级网关冲突的 192.168.0.1/24
  if echo "$A" | $BB awk '$2=="wlan0" && $4=="192.168.0.1/24"{f=1} END{exit !f}'; then
    ip addr del 192.168.0.1/24 dev wlan0 2>/dev/null
    A=$(ip -o -4 addr show)
  fi

  OLDGW=$($BB cat "$DATA/gw" 2>/dev/null)
  # netd 只给它自己配过的网段加本地路由规则，改网段后必须自己补
  ip rule show | $BB grep -q "to $PREFIX.0/24 lookup main" || \
    ip rule add to "$PREFIX.0/24" lookup main prio 4000 2>/dev/null
  DS=$(downstream)
  for i in $($BB cat "$DATA/ifaces" 2>/dev/null); do
    ip link show "$i" >/dev/null 2>&1 && DS="$DS $i"
  done
  DS=$(echo $DS | $BB tr ' ' '\n' | $BB sort -u | $BB tr '\n' ' ' | $BB sed 's/^ *//;s/ *$//')

  # 有下游时，wlan0 上的 192.168.2.1 只是残留
  if [ -n "$DS" ]; then
    for a in $(echo "$A" | $BB awk '$2=="wlan0" && ($4=="192.168.2.1/24"||$4=="192.168.42.1/24"){print $4}'); do
      ip addr del "$a" dev wlan0 2>/dev/null
      A=$(ip -o -4 addr show)
    done
  fi

  # USB 共享端由模块接管地址；热点端用系统自己的网段，不碰
  USBDS=""
  for i in $DS; do
    case "$i" in
      rndis*|ncm*|usb[0-9]*)
        # 用户手动关了共享就不再接管地址
        if [ "$(usb_off_flag)" = 1 ]; then continue; fi
        # 系统 tethering 已经接管这个接口时，地址与 DHCP 都归系统管。
        # 实测 vivo 开 ncm,adb 后 system_server 立刻在 rndis0 上跑自己的 DHCP
        # （网段 192.168.66.x），模块若同时把接口改成 192.168.8.1，
        # 对端拿到 66.x 却连不上 8.1，等于把能用的链路改坏。
        if sys_dhcp_on "$i"; then
          ip link set "$i" up 2>/dev/null
          USBDS="$USBDS $i"
          continue
        fi
        for a in $(echo "$A" | $BB awk -v d="$i" -v g="$GW/24" '
            $2==d && $4!=g && $4 !~ /^169\.254\./ {print $4}'); do
          ip addr del "$a" dev "$i" 2>/dev/null
          A=$(ip -o -4 addr show)
        done
        if ! echo "$A" | $BB awk -v d="$i" -v w="$GW/" 'index($4,w)==1 && $2==d{f=1} END{exit !f}'; then
          ip addr add "$GW/24" dev "$i" 2>/dev/null
          A=$(ip -o -4 addr show)
        fi
        # 只配地址不够：切换 sys.usb.config 后 rndis0/ncm0 可能停在 DOWN，
        # 地址在但包发不出去，对端永远拿不到 DHCP 回应（实测 vivo rndis0 就是 DOWN）
        ip link set "$i" up 2>/dev/null
        USBDS="$USBDS $i"
        ;;
    esac
  done

  [ -n "$DS" ] && echo "$DS" > "$DATA/ifaces"
  echo "$GW" > "$DATA/gw"
  log_chg ifaces "$DS" "网络: 下游接口 ${DS:-无}"
  log_chg gw "$GW/$POOL_START-$POOL_END" "网络: 网段 $GW/24 池 .$POOL_START-.$POOL_END · USB 接管 ${USBDS:-无}"

  # 热点网段与 USB 网段互访：热点客户端要能直接访问 USB 那台设备的端口
  HSIP=$(ip -o -4 addr show dev "$(ap_iface)" 2>/dev/null | $BB awk '{sub(/\/.*/,"",$4); print $4; exit}')
  if [ -n "$HSIP" ]; then
    HNET=$(echo "$HSIP" | $BB awk -F. '{print $1"."$2"."$3".0/24"}')
    echo "$HNET" > "$DATA/hnet"
    ip rule show | $BB grep -q "to $HNET lookup main" || \
      ip rule add to "$HNET" lookup main pref 3500 2>/dev/null
    for spec in "-s $HNET -d $PREFIX.0/24" "-s $PREFIX.0/24 -d $HNET"; do
      iptables -C FORWARD $spec -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD $spec -j ACCEPT 2>/dev/null
    done
  fi

  # 热点设备访问本机指定端口的流量，按页面里的列表转给 USB 端那台固定设备
  sync_fwd

  # 三种情况下模块不启 dnsmasq：
  # 1) 热点开着 —— 系统热点自己绑 67，抢了就起不来
  # 2) 系统 tethering 正在服务 USB 接口 —— 它已经给了地址，我们再去抢只会
  #    每轮 bind 失败刷错误日志（实测 vivo：system_server 占 0.0.0.0%rndis0:67）
  # 3) 没有下游接口
  if [ "$(ap_running)" = 1 ]; then
    date +%s > "$DATA/yield.ts" 2>/dev/null
    # 热点开着时顺带确认系统 DHCP 是否在热点接口上服务——没服务的话，
    # 连上来的设备拿不到地址，就是「热点开着但没网」的直接原因。
    if ap_dhcp_on; then
      log_chg apdhcp "on" "热点: DHCP 由系统服务（接口 $(ap_iface)）"
    else
      log_chg apdhcp "off" "热点: 系统 DHCP 未在 $(ap_iface) 上服务，连入设备可能拿不到地址"
    fi
    stop_dnsmasq
  elif sys_dhcp_any "$USBDS"; then
    # 系统 tethering 已接管：这是「有服务」而不是「端口被占所以判断失败」，记下来
    log_chg dhcpw "sys" "DHCP: 由系统 tethering 负责（模块让位）"
    date +%s > "$DATA/yield.ts" 2>/dev/null
    stop_dnsmasq
  else
    # 让位迟滞：系统 tethering 建立的那几秒里 sys_dhcp_any 会时有时无，
    # 若每次都立刻切回自建，dnsmasq 会在「让位/自建」之间高频起停，租约永远发不出去。
    # 让位后至少保持 20 秒，确认系统真的没接管了才允许自建。
    yt=$($BB cat "$DATA/yield.ts" 2>/dev/null); [ -z "$yt" ] && yt=0
    if [ $(( $(date +%s) - yt )) -lt 20 ]; then
      log_chg dhcpw "yield" "DHCP: 让位冷却中，暂不自建（等系统 tethering 稳定）"
      : # 不碰 dnsmasq，保持现状
    else
      log_chg dhcpw "self" "DHCP: 模块自建 dnsmasq 服务 ${USBDS:-无}"
      sync_dnsmasq "$USBDS"
    fi
  fi
  ns=$(usb_net_state)
  log_chg usbnet "$ns" "USB 链路: $ns"
  usb_dhcp_tick
}

# ---------- 端口转发 ----------
# 热点设备访问本机这些端口时，转给 USB 端那台固定设备；列表为空＝不转发

# USB 端那台设备的实际地址：优先 ARP 邻居，其次 ip neigh，再次 DHCP 租约。
# 兜底的 $PREFIX.2 只在本机确实持有 $GW（说明地址是模块自己发的）时才成立：
# 系统 tethering 会把对端放到它自己选的网段，这时候写 8.2 等于指向一个不存在的主机，
# 端口转发的 DNAT 目标就成了黑洞。
usb_peer() {
  p=""
  # 邻居表是实时状态，优先；租约文件在 infinite 租约下不一定及时落盘，只能当次选
  for i in $(usb_ifaces); do
    [ -n "$p" ] && break
    p=$($BB awk -v d="$i" '$6==d && $3 ~ /0x[23]/ && $1 !~ /^169\.254/ {print $1; exit}' /proc/net/arp 2>/dev/null)
  done
  for i in $(usb_ifaces); do
    [ -n "$p" ] && break
    p=$(ip neigh show dev "$i" 2>/dev/null | $BB awk '$1 ~ /\./ && $1 !~ /^169\.254/ {print $1; exit}')
  done
  [ -z "$p" ] && [ -f "$DATA/dnsmasq.leases" ] && \
    p=$($BB awk '$3 ~ /^[0-9]+\./ && $3 !~ /^169\.254/ {print $3; exit}' "$DATA/dnsmasq.leases")
  if [ -z "$p" ]; then
    for i in $(usb_ifaces); do
      ip -o -4 addr show dev "$i" 2>/dev/null | $BB grep -q " $GW/" && { p="$PREFIX.2"; break; }
    done
  fi
  echo "$p"
}

# 接口上第一个 IPv4 的 /24（Android 的 tethering 网段都是 /24）
iface_net24() {
  [ -n "$1" ] || return 1
  n=$(ip -o -4 addr show dev "$1" 2>/dev/null | $BB awk '$4 !~ /^127\./ {print $4; exit}')
  [ -n "$n" ] || return 1
  echo "$n" | $BB awk -F'[./]' '{print $1"."$2"."$3".0/24"}'
}

# 对端真实网段。系统 tethering 接管后不是 8 段（实测 16/66/83/103/152 段都出现过），
# 按模块自己的 PREFIX 放行 FORWARD 会漏掉真正在跑的那个网段。
usb_peer_net() {
  for i in $(usb_ifaces); do
    n=$(iface_net24 "$i") && { echo "$n"; return 0; }
  done
  return 1
}

# 热点网段：按热点接口上的真实地址算，不用模块的 PREFIX
ap_net() {
  a=$(ap_iface) || return 1
  iface_net24 "$a"
}

fwd_list() {
  [ -f "$DATA/fwd.list" ] || return 0
  $BB cat "$DATA/fwd.list" | $BB tr '\n' ' ' | $BB sed 's/ *$//'
}

sync_fwd() {
  ports=$(fwd_list)
  tg=$(usb_peer)
  pnet=$(usb_peer_net)
  hnet=$(ap_net)
  iptables -t nat -N NETBATT_FWD 2>/dev/null
  iptables -t nat -N NETBATT_SNAT 2>/dev/null

  # 转发能不能成，前提不在 nat 表，而在另外三处。老版本只动了 nat，
  # 于是在系统 tethering 换过网段之后出现了「规则都在、就是不通」：
  #   1) ip_forward 关着 -> 包根本不过路由
  #   2) 对端网段没有 lookup main 的策略路由 -> 改了目的地址的包找不到出口
  #   3) netd 的 FORWARD 默认 DROP，而这里只放行了模块自己的 8 段
  echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null
  nets=""
  for n in "$hnet" "$pnet" "$PREFIX.0/24"; do
    [ -n "$n" ] || continue
    case " $nets " in *" $n "*) ;; *) nets="$nets $n" ;; esac
    ip rule show | $BB grep -q "to $n lookup main" || \
      ip rule add to "$n" lookup main pref 3500 2>/dev/null
  done
  for a in $nets; do
    for b in $nets; do
      [ "$a" = "$b" ] && continue
      iptables -C FORWARD -s "$a" -d "$b" -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -s "$a" -d "$b" -j ACCEPT 2>/dev/null
    done
  done

  # 热点接口进来的流量先过这个链。接口名按实测取：写死列表会漏掉 wlan1 和
  # 厂商自定义名，那时候规则一条不少、就是没有包进来匹配。
  for i in $(ap_iface) $AP_IFACES; do
    ip link show "$i" >/dev/null 2>&1 || continue
    iptables -t nat -C PREROUTING -i "$i" -j NETBATT_FWD 2>/dev/null || \
      iptables -t nat -I PREROUTING -i "$i" -j NETBATT_FWD 2>/dev/null
  done
  iptables -t nat -C POSTROUTING -j NETBATT_SNAT 2>/dev/null || \
    iptables -t nat -A POSTROUTING -j NETBATT_SNAT 2>/dev/null

  want=0
  for p in $ports; do want=$((want + 2)); done
  got=$(iptables -t nat -S NETBATT_FWD 2>/dev/null | $BB grep -c -- '--dport')
  oldtg=$($BB cat "$DATA/fwd.target" 2>/dev/null)
  [ "$got" = "$want" ] && [ "$oldtg" = "$tg" ] && return 0

  iptables -t nat -F NETBATT_FWD 2>/dev/null
  iptables -t nat -F NETBATT_SNAT 2>/dev/null
  # 回程包：对端不一定有回热点网段的路由，源地址统一换成本机 USB 侧地址，
  # 由 conntrack 反向还原，比按端口写 SNAT 稳（端口只是目的，回程对不上号）
  for i in $(usb_ifaces); do
    [ -n "$hnet" ] && iptables -t nat -A NETBATT_SNAT -o "$i" -s "$hnet" -j MASQUERADE 2>/dev/null
    [ -n "$pnet" ] && iptables -t nat -A NETBATT_SNAT -o "$i" -s "$pnet" -j MASQUERADE 2>/dev/null
  done
  # 没有目标地址就别下 DNAT：指向空地址的规则会让「已开启」变成一句空话
  if [ -n "$tg" ]; then
    for p in $ports; do
      iptables -t nat -A NETBATT_FWD -p tcp --dport "$p" -j DNAT --to-destination "$tg:$p" 2>/dev/null
      iptables -t nat -A NETBATT_FWD -p udp --dport "$p" -j DNAT --to-destination "$tg:$p" 2>/dev/null
    done
  fi
  echo "$tg" > "$DATA/fwd.target"
}

# 转发到底有没有在跑：页面用它给一句话结论，免得只看到「已开启」却不通
fwd_state() {
  [ -n "$(fwd_list)" ] || { echo off; return 0; }
  [ -n "$(usb_ifaces)" ] || { echo no_usb; return 0; }
  [ -n "$(usb_peer)" ] || { echo no_peer; return 0; }
  n=$(iptables -t nat -S NETBATT_FWD 2>/dev/null | $BB grep -c -- '--dport')
  [ "${n:-0}" -gt 0 ] && echo on || echo no_rule
}


fwd_add() {
  p="$1"
  case "$p" in ''|*[!0-9]*) return 1;; esac
  [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || return 1
  cur=$(fwd_list)
  case " $cur " in *" $p "*) return 0;; esac
  echo "$cur $p" | $BB sed 's/^ *//' > "$DATA/fwd.list"
  log "端口转发: 添加 $p -> $(usb_peer)"
  sync_fwd
}

fwd_del() {
  p="$1"
  cur=$(fwd_list); new=""
  for x in $cur; do [ "$x" = "$p" ] || new="$new $x"; done
  echo $new > "$DATA/fwd.list"
  log "端口转发: 移除 $p"
  sync_fwd
}

lease_host() {
  [ -f "$DATA/dnsmasq.leases" ] || return 0
  $BB awk -v m="$1" '$2==m && $4!="*"{print $4; exit}' "$DATA/dnsmasq.leases"
}

clients_json() {
  ds=$(downstream)
  lines=""
  LF=""
  [ -f "$DATA/dnsmasq.leases" ] && LF="$DATA/dnsmasq.leases"
  # 只按下游接口过滤：USB 端是 192.168.8.x，热点端是系统网段（10.x 等），不能按网段筛
  # 同一 MAC 的旧 ARP 地址（换过网段留下的）按租约去重，只留当前这个
  [ -n "$ds" ] && lines=$($BB awk -v ds="$ds" '
    BEGIN{n=split(ds,a," ");for(i=1;i<=n;i++)ok[a[i]]=1}
    FILENAME ~ /dnsmasq\.leases$/ { if ($4!="*" && NF>=4) lm[$2]=$3; next }
    FNR>1 && ($6 in ok) && ($3 ~ /0x2/) && $1 !~ /^169\.254\./ {
      if (($4 in lm) && lm[$4] != $1) next
      print $1"|"$4"|"$6
    }
  ' $LF /proc/net/arp 2>/dev/null)

  if [ -z "$lines" ]; then
    echo "[]"
    return 0
  fi
  printf '%s\n' "$lines" | while IFS='|' read ip mac dev; do
    h=$(lease_host "$mac")
    printf '{"ip":"%s","mac":"%s","dev":"%s","host":"%s"}\n' "$ip" "$mac" "$dev" "$h"
  done | $BB awk 'BEGIN{printf "["} NF{if(c++)printf ",";printf "%s",$0} END{printf "]"}'
}

# ---------- 充电 ----------

chg_active() { [ -f "$DATA/chg.on" ] && echo 1 || echo 0; }

# 首次安装默认开启；用户手动停止后 chg.off 会跨重启保留
chg_init() {
  [ -f "$DATA/chg.on" ] || [ -f "$DATA/chg.off" ] || touch "$DATA/chg.on"
}

# root 下 [ -w ] 恒真，只能看权限位；权限位取不到时退化成“写回原值”探测
chg_writable() {
  [ -f "$1" ] || return 1
  p=$(stat -c %A "$1" 2>/dev/null)
  case "$p" in
    *w*) return 0 ;;
    "")  ;;
    *)   return 1 ;;
  esac
  v=$(cat "$1" 2>/dev/null) || return 1
  printf '%s\n' "$v" > "$1" 2>/dev/null || return 1
  return 0
}

# 判通道：CHG_CH=switch|soc|none，CHG_NODE=实际节点；switch 时一并定好 on/off 极性
chg_detect() {
  case "$CHG_MODE" in
    switch) CHG_CH=switch; CHG_NODE=$CHG_SWITCH; return 0 ;;
    soc)    CHG_CH=soc;    CHG_NODE=$SOC_PATH;   return 0 ;;
  esac

  # 有目标电量节点就先走 soc：这类机型通常不给开关节点写权限
  if chg_writable "$SOC_PATH"; then
    CHG_CH=soc; CHG_NODE=$SOC_PATH; return 0
  fi

  for spec in \
    "/sys/class/qcom-battery/input_suspend:0:1" \
    "/sys/class/power_supply/battery/input_suspend:0:1" \
    "/sys/class/power_supply/charger/charging_enabled:1:0" \
    "/sys/class/power_supply/battery/charging_enabled:1:0" \
    "/sys/class/power_supply/battery/batt_slate_mode:0:1" \
    "$CHG_SWITCH:$CHG_ON:$CHG_OFF"
  do
    p=${spec%%:*}; r=${spec#*:}; on=${r%%:*}; off=${r#*:}
    chg_writable "$p" || continue
    CHG_CH=switch; CHG_NODE=$p; CHG_ON=$on; CHG_OFF=$off
    return 0
  done

  CHG_CH=none; CHG_NODE=""
  return 1
}

chg_platform() {
  b=$(getprop ro.board.platform 2>/dev/null)
  case "$b" in
    msm*|sdm*|sm[0-9]*|kona*|lahaina*|waipio*|taro*|blair*|sun*|cape*) echo qcom ;;
    mt[0-9]*|mtk*) echo mtk ;;
    *) [ -n "$b" ] && echo other || echo unknown ;;
  esac
}

# chg_apply on|off|restore —— 唯一碰硬件的地方
#   on/off  : 控制器自己决定
#   restore : 控制器停用，把 soc 通道还原成接管前的值（vivo 出厂充电保护之类）
chg_apply() {
  chg_detect || return 1

  if [ "$CHG_CH" = soc ]; then
    # 第一次接管时记住原值，停用控制器时还原
    [ -f "$DATA/soc.orig" ] || cat "$CHG_NODE" 2>/dev/null > "$DATA/soc.orig"
    case "$1" in
      off) v=$CHG_SOC_OFF ;;
      restore)
        v=$(cat "$DATA/soc.orig" 2>/dev/null)
        [ -z "$v" ] && v=$CHG_SOC_ON ;;
      *) v=$CHG_SOC_ON ;;
    esac
  else
    case "$1" in off) v=$CHG_OFF ;; *) v=$CHG_ON ;; esac
  fi

  [ "$(cat "$CHG_NODE" 2>/dev/null)" = "$v" ] && return 0
  printf '%s\n' "$v" > "$CHG_NODE" 2>/dev/null
  log "充电: 写入 $CHG_NODE=$v（$CHG_CH ${1}）"
}

# 周期采样入口：loop 每 5 秒调一次，内部按 SAMPLE_INT 降采样。控制器关不关都记，
# 因为采样是想看清整条充放电曲线，跟阈值控制是两个独立诉求。
sample_once() {
  cap=$(cat $BATT/capacity 2>/dev/null); [ -z "$cap" ] && return 0
  st=$(cat $BATT/status 2>/dev/null); [ -z "$st" ] && st="?"
  rawt=$(cat $BATT/temp 2>/dev/null); [ -z "$rawt" ] && rawt=0
  t=$($BB awk -v t="$rawt" 'BEGIN{printf "%.1f", t/10}')
  cur=$(cat $BATT/current_now 2>/dev/null); [ -z "$cur" ] && cur=0
  case "$st" in
    Charging)    [ "$cur" -lt 0 ] && cur=$((cur * -1)) ;;
    Discharging) [ "$cur" -gt 0 ] && cur=$((cur * -1)) ;;
  esac
  vol=$(cat $BATT/voltage_now 2>/dev/null); [ -z "$vol" ] && vol=3800000
  [ "$vol" = 0 ] && vol=3800000
  watt=$($BB awk -v v="$vol" -v c="$cur" 'BEGIN{printf "%.2f", v*c/1e12}')
  case "$st" in
    Charging) dir=充 ;;
    Discharging) dir=放 ;;
    Full) dir=满 ;;
    *) dir=闲 ;;
  esac
  ma=$($BB awk -v c="$cur" 'BEGIN{printf "%d", c/1000}')
  sample_now "$cap" "$dir" "$watt" "$ma" "$t"
}

chg_once() {
  # 周期采样独立于控制器开关：关掉充电控制时采样照记
  sample_once

  # 控制器没开：还原到接管前的状态，不做阈值判断
  if [ ! -f "$DATA/chg.on" ]; then
    chg_apply restore >/dev/null 2>&1
    return 0
  fi

  cap=$(cat $BATT/capacity 2>/dev/null); [ -z "$cap" ] && return 0
  rawt=$(cat $BATT/temp 2>/dev/null); [ -z "$rawt" ] && rawt=0
  t=$((rawt / 10))

  if [ "$cap" -le 15 ]; then
    want=on                      # 电量过低，强制恢复充电
  elif [ "$t" -ge "$MAX_TEMP" ]; then
    want=off                     # 高温暂停
  elif [ "$cap" -ge "$PAUSE_CAP" ]; then
    want=off
  elif [ "$cap" -le "$RESUME_CAP" ]; then
    want=on
  else
    want=$(cat "$DATA/chg.state" 2>/dev/null)
    [ -z "$want" ] && want=on
  fi

  prev=$($BB cat "$DATA/chg.state" 2>/dev/null)
  chg_apply "$want"
  echo "$want" > "$DATA/chg.state"
  # 只在结论变化时记一行：每 5 秒一轮，无条件记会把日志刷满
  if [ "$prev" != "$want" ]; then
    log "充电控制: ${prev:-?} -> $want（${cap}% ${t}℃ 上限 $PAUSE_CAP 恢复 $RESUME_CAP）"
  fi
}

chg_ctl() {
  case "$1" in
    start)
      rm -f "$DATA/chg.off"
      touch "$DATA/chg.on"
      chg_once
      log "充电控制: 启动"
      ;;
    stop)
      rm -f "$DATA/chg.on"
      touch "$DATA/chg.off"
      chg_apply restore
      echo on > "$DATA/chg.state"
      log "充电控制: 停止并还原硬件"
      ;;
    restart)
      rm -f "$DATA/chg.on" "$DATA/chg.off"
      chg_apply restore
      sleep 1
      touch "$DATA/chg.on"
      chg_once
      log "充电控制: 重启"
      ;;
    *) return 1 ;;
  esac
  return 0
}

batt_json() {
  cap=$(cat $BATT/capacity 2>/dev/null); [ -z "$cap" ] && cap=0
  st=$(cat $BATT/status 2>/dev/null); [ -z "$st" ] && st="unknown"
  rawt=$(cat $BATT/temp 2>/dev/null); [ -z "$rawt" ] && rawt=0
  temp=$($BB awk -v t="$rawt" 'BEGIN{printf "%.1f", t/10}')
  cur=$(cat $BATT/current_now 2>/dev/null); [ -z "$cur" ] && cur=0
  # 符号各平台不一致（vivo/MTK 充电时给负值），统一成 正=充入 负=放出
  case "$st" in
    Charging)    [ "$cur" -lt 0 ] && cur=$((cur * -1)) ;;
    Discharging) [ "$cur" -gt 0 ] && cur=$((cur * -1)) ;;
  esac
  ma=$($BB awk -v c="$cur" 'BEGIN{printf "%d", c/1000}')
  # 电流有符号：正=充入，负=放出；功率 = 电压 × 电流
  vol=$(cat $BATT/voltage_now 2>/dev/null); [ -z "$vol" ] && vol=3800000
  [ "$vol" = 0 ] && vol=3800000
  amp=$($BB awk -v c="$cur" 'BEGIN{printf "%.2f", c/1000000}')
  watt=$($BB awk -v v="$vol" -v c="$cur" 'BEGIN{printf "%.2f", v*c/1e12}')
  case "$st" in
    Charging) dir=chg ;;
    Discharging) dir=dis ;;
    Full) dir=full ;;
    *)
      if [ "$cur" -gt 30000 ]; then dir=chg
      elif [ "$cur" -lt -30000 ]; then dir=dis
      else dir=idle; fi
      ;;
  esac
  umax=$(cat /sys/class/power_supply/usb/current_max 2>/dev/null); [ -z "$umax" ] && umax=0
  # 当前走哪条通道、落在哪个节点、平台是什么，前端要显示出来
  chg_detect >/dev/null 2>&1
  [ -z "$CHG_NODE" ] && CHG_NODE=$CHG_SWITCH
  sw=$(cat "$CHG_NODE" 2>/dev/null); [ -z "$sw" ] && sw="?"
  socv=$(cat "$DATA/soc.orig" 2>/dev/null)
  [ -z "$socv" ] && socv=$(cat "$CHG_NODE" 2>/dev/null)
  [ -z "$socv" ] && socv=0
  printf '{"cap":%s,"status":"%s","temp":%s,"ma":%s,"a":%s,"w":%s,"dir":"%s","usb_max":%s,"pc":%s,"rc":%s,"enabled":%s,"sw":"%s","state":"%s","ch":"%s","node":"%s","plat":"%s","soc_orig":%s}' \
    "$cap" "$st" "$temp" "$ma" "$amp" "$watt" "$dir" "$umax" "$PAUSE_CAP" "$RESUME_CAP" "$(chg_active)" "$sw" \
    "$(cat $DATA/chg.state 2>/dev/null || echo on)" "$CHG_CH" "$CHG_NODE" "$(chg_platform)" "$socv"
}

# ---------- 状态 / 控制 ----------

# 热点接口名各家不同：高通/小米多是 wlan2，联发科/vivo 是 ap0，
# 有的 ROM 用 swlan0、softap0、wlan1。只看一个名字会在别家机器上永远判成"热点未开"，
# 连带 USB DHCP 调度和网页状态一起失效。
AP_IFACES="wlan2 ap0 swlan0 softap0 wlan1"
ap_iface() {
  for i in $AP_IFACES; do
    ip link show "$i" >/dev/null 2>&1 && { echo "$i"; return 0; }
  done
  # 兜底：任何接口带 AP 模式的（部分 ROM 名字完全自定义）
  i=$(iw dev 2>/dev/null | $BB awk '/Interface/{n=$2} /type AP/{print n; exit}')
  [ -n "$i" ] && { echo "$i"; return 0; }
  return 1
}

ap_running() {
  # 只看接口存在是不够的：热点关闭后 ap0 会残留成 state DOWN、无地址，
  # 实测 vivo 上就是这样，会把「热点已关」误判成「热点开着」，
  # 进而触发 DHCP 接管 -> 关热点 -> 等 67 超时 -> 假失败并杀掉刚起的 dnsmasq
  a=$(ap_iface)
  [ -z "$a" ] && { echo 0; return; }
  ip -o -4 addr show dev "$a" 2>/dev/null | $BB grep -q 'inet ' && echo 1 || echo 0
}

# wait_for 需要的是退出码（0=开，1=关），ap_running 输出的是字符串不能直接当条件用
ap_is_up() {
  a=$(ap_iface) || return 1
  ip -o -4 addr show dev "$a" 2>/dev/null | $BB grep -q 'inet '
}

ap_down() { ap_is_up && return 1; return 0; }

# 系统 tethering 是否已在某个接口上提供 DHCP：绑定形式为 0.0.0.0%<iface>:67，
# 持有者是 system_server。命中说明系统自己把这条链路服务得很好，模块必须让位。
sys_dhcp_on() {
  [ -n "$1" ] || return 1
  ss -lunp 2>/dev/null | $BB grep -F "0.0.0.0%$1:67" | $BB grep -q 'system_server'
}

# 热点接口上系统是否在发 DHCP。热点开着但设备连上没网，先查这个：
# system_server 没在 ap 接口绑 67，说明系统热点的地址分配根本没起来。
ap_dhcp_on() {
  a=$(ap_iface) || return 1
  ss -lunp 2>/dev/null | $BB grep -F "0.0.0.0%$a:67" | $BB grep -q 'system_server'
}

# 给定的接口集合里有没有系统 DHCP 在服务（默认查全部 USB 接口）
sys_dhcp_any() {
  for i in ${1:-$(usb_ifaces)}; do
    sys_dhcp_on "$i" && return 0
  done
  return 1
}

# 让特权应用去开/关共享：hs <wifi|usb> <0|1>
hs() {
  t=0
  [ "$1" = usb ] && t=1
  log_chg "hs$t" "$2" "hs: 请求 $1 on=$2"
  # 开热点前先把我们的 DHCP 让出来，否则系统 DHCP 绑不上 67，热点直接起不来
  if [ "$t" = 0 ] && [ "$2" != "0" ]; then stop_dnsmasq; sleep 1; fi

  if [ "$t" = 1 ]; then
    if [ "$2" = "0" ]; then
      touch "$DATA/usb.off"
      # native 模式下系统开过 tethering，得让它先收回去
      am broadcast -n com.netbatt.console/.TetherReceiver --ei type 1 --ez on 0 >/dev/null 2>&1
      # 复合配置切回纯数据，网卡才会消失；adb 保留，别把自己关在门外
      if usb_has_func adb; then setprop sys.usb.config mtp,adb; else setprop sys.usb.config mtp; fi
      log "hs: USB 共享关闭 config=$(getprop sys.usb.config)"
      return 0
    fi
    rm -f "$DATA/usb.off"
    # 一律先走系统 tethering。实测 vivo 这类 ROM 直接写 sys.usb.config 只会建出
    # functions/rndis.gs4 目录，不会把它链接进 configs/b.1，内核因此不建网卡：
    # getprop 回显 rndis,adb，但 ip link 里什么都没有，对端自然什么都看不到。
    # 系统 tethering 走厂商 HAL，会真正重建配置，网卡才出得来。
    am broadcast -n com.netbatt.console/.TetherReceiver --ei type 1 --ez on 1 >/dev/null 2>&1
    if wait_for 12 usb_iface_any; then
      echo native > "$DATA/usb.mode"
      log "hs: 系统 tethering 建成 接口=$(usb_ifaces) config=$(getprop sys.usb.config)"
      apply
      return 0
    fi
    if [ "$USB_NATIVE" = 1 ]; then
      echo "" > "$DATA/usb.mode"
      log "hs: 系统 tethering 未建出接口，配置为仅原生，不做自建回退"
      return 0
    fi
    # 系统那边不干活才退回自建：直接写 function，只对接受 sys.usb.config 的 ROM 有效
    log "hs: 系统 tethering 未建出接口，回退自建 function"
    usb_apply_funcs "$(usb_net_pick)"
    wait_for 10 usb_iface_any
    echo manual > "$DATA/usb.mode"
    apply
    log "hs: 自建共享 config=$(getprop sys.usb.config) 已链接=$(usb_func_linked) 接口=$(usb_ifaces)"
    return 0
  fi

  am broadcast -n com.netbatt.console/.TetherReceiver --ei type 0 --ez on "$2" >/dev/null 2>&1
  # 热点开关是异步的：系统 TetheringManager 要 1-2 秒才把 ap0 配好地址，
  # 立刻返回会让页面下一轮 status 还看到「未开启」。这里短等一拍，让 ap_running
  # 尽快反映真实状态；失败不阻塞，apply 的 5 秒循环会兜底校正。
  if [ "$2" = "0" ]; then
    wait_for 3 ap_down 2>/dev/null
  else
    wait_for 3 ap_is_up 2>/dev/null
  fi
}

# 用户手动关过 USB 共享后，保活不要再自动拉起
usb_off_flag() { [ -f "$DATA/usb.off" ] && echo 1 || echo 0; }

# ---------- USB 网络功能 ----------
# 对端看不到网卡＝手机这端给的 USB 网络 class 对端不认，跟 DHCP 一点关系都没有。
# gadget 支持哪种网络 function，取决于对端内核装了哪个驱动：
#   rndis  最广，Android/Windows/Linux 都认，随身 WiFi 基本都是这一类
#   ncm    需要 cdc_ncm，Windows 10+ 自带，车机和老 Linux 常常没有
#   ecm    对端表现为 cdc_ether(eth*)，但本机 gadget 得真有这个 function
usb_gadget_dir() {
  for d in /config/usb_gadget/*; do
    [ -d "$d/functions" ] && { echo "$d"; return 0; }
  done
  return 1
}

# 本机真实存在的 function，去掉 .instance 后缀
usb_funcs() {
  g=$(usb_gadget_dir) || return 1
  ls "$g/functions" 2>/dev/null | $BB sed 's/\..*//' | $BB sort -u | $BB tr '\n' ' '
}

usb_has_func() {
  case " $(usb_funcs) " in *" $1 "*) return 0;; esac
  # adb 在 configfs 里的实例名是 ffs.adb，去掉后缀后成了 ffs
  if [ "$1" = adb ]; then
    case " $(usb_funcs) " in *" ffs "*) return 0;; esac
  fi
  return 1
}

# 实际要用的网络 function：显式指定就照办，auto 按对端兼容性排序
usb_net_pick() {
  case "$USB_NET" in
    rndis|ncm|ecm) echo "$USB_NET"; return 0 ;;
  esac
  for f in rndis ecm ncm; do
    usb_has_func "$f" && { echo "$f"; return 0; }
  done
  echo rndis
}

# function 是否真的被链接进 configuration。只看"目录存在"不够：
# vivo 这类 ROM 会建出 functions/rndis.gs4 却不链进 configs/b.1，
# 于是 getprop 回显 rndis,adb、对端却什么都看不到。
usb_func_linked() {
  g=$(usb_gadget_dir) || { echo 0; return 1; }
  fn=$(usb_net_pick)
  for l in "$g"/configs/*/f*; do
    [ -L "$l" ] || continue
    case "$(readlink "$l" 2>/dev/null)" in
      *"/functions/$fn".*) echo 1; return 0 ;;
    esac
  done
  echo 0
}

# 切换 USB 功能组合。adb 必须一起保留，否则切完就丢了调试通道。
usb_apply_funcs() {
  fn="$1"; [ -n "$fn" ] || fn=$(usb_net_pick)
  # 配置里存的类型换机后可能不存在，回退到本机真有的
  f=$(usb_funcs)
  if [ -n "$f" ] && ! usb_has_func "$fn"; then
    for x in rndis ecm ncm; do
      usb_has_func "$x" && { fn="$x"; break; }
    done
  fi
  # 已经是这个配置就不要重建，白白断一次 adb
  case "$(getprop sys.usb.config)" in
    *"$fn"*) return 0 ;;
  esac

  want="$fn"
  usb_has_func adb && want="$fn,adb"
  log "USB 功能切换: $(getprop sys.usb.config) -> $want"
  # svc usb setFunctions 走 UsbDeviceManager，配置描述符重建最完整。
  # 但它未必存在（老 ROM 的 svc 没有这个子命令，且可能返回 0），
  # 所以以 sys.usb.config 里真的出现目标 function 为准，否则退回直接写属性。
  svc usb setFunctions "$want" >/dev/null 2>&1
  i=0
  while [ $i -lt 10 ]; do
    case "$(getprop sys.usb.config)" in
      *"$fn"*) log "USB 功能生效: $(getprop sys.usb.config)"; return 0 ;;
    esac
    $BB sleep 0.2 2>/dev/null || sleep 1
    i=$((i + 1))
  done
  setprop sys.usb.config "$want"
  log "USB 功能切换回退 setprop: $(getprop sys.usb.config)"
}

usb_iface_any() { [ -n "$(usb_ifaces)" ]; }

# 升级后对齐：旧配置可能还是 ncm，而模块现在默认 rndis。
# 只在「当前已经是某种网络配置」时纠正类型，不会把没开共享的 mtp,adb 擅自切成网卡。
usb_sync_func() {
  [ "$USB_NATIVE" = 1 ] && return 0
  [ "$(usb_off_flag)" = 0 ] || return 0
  [ "$(usb_online)" = 1 ] || return 0
  fn=$(usb_net_pick)
  cur=$(getprop sys.usb.config)
  case "$cur" in
    *"$fn"*) return 0 ;;
    *rndis*|*ncm*|*ecm*) log "启动对齐: 当前 $cur 与配置 $fn 不符"; usb_apply_funcs "$fn" ;;
  esac
}

usb_online() {
  [ "$(cat /sys/class/power_supply/usb/online 2>/dev/null)" = "1" ] && echo 1 || echo 0
}

# USB 共享是否真的在链路上：复合配置里得有网络 function，否则对端看不到网卡
usb_up() {
  case "$(getprop sys.usb.config)$(getprop sys.usb.state)" in
    *rndis*|*ncm*|*ecm*) echo 1; return 0 ;;
  esac
  echo 0
}

# ---------- USB DHCP 调度（状态机） ----------
# 为什么必须让系统让出 67：热点开着时 DHCP 由 system_server 持有，绑在
# 0.0.0.0%ap0:67（带 SO_BINDTODEVICE）。实测 dnsmasq 2.51 的 DHCP socket 固定绑
# 0.0.0.0:67，-i 指定接口、-a 指定地址、--bind-interfaces 三种写法全部返回
# EADDRINUSE，没有按接口绑定的能力，因此两者不可能同时存在。
# 这里做的是「临时接管」：系统让位 → 我们发地址 → 立刻还回去。
# 它不是常驻 DHCP：租约到期/续租都没人应答，长期依赖客户端保留地址或改用静态 IP。
DHCP_LOCK="$DATA/dhcp.lock"
DHCP_STATE="$DATA/dhcp.state"
DHCP_STAMP="$DATA/dhcp.stamp"
DHCP_APORIG="$DATA/ap.orig"
DHCP_CYCLE="$DATA/dhcp.cycle"      # 本 USB 连接周期是否已尝试过接管
DHCP_ACKBASE="$DATA/dhcp.ackbase"  # 接管前 logcat 的 ACK 计数基线，用来排除旧记录
DHCP_LAST="$DATA/dhcp.last"
DHCP_NET="$DATA/usb.net"           # USB 链路的落地状态，与上行无关

usb_ifaces() {
  for i in rndis0 ncm0 usb0; do
    ip link show "$i" >/dev/null 2>&1 && echo "$i"
  done
}

# 67 上是否有人监听；ss 取不到时退回 /proc/net/udp
port67_busy() {
  if command -v ss >/dev/null 2>&1; then
    ss -lun 2>/dev/null | $BB awk 'NR>1{for(i=1;i<=NF;i++) if ($i ~ /:67$/) {f=1; exit}} END{exit !f}'
  else
    $BB awk 'NR>1{split($2,a,":"); if (a[2]=="0043") f=1} END{exit !f}' /proc/net/udp
  fi
}
port67_free() { port67_busy && return 1; return 0; }

# ---------- 三层判定 ----------
# 第一层：DHCP 服务真的起来了（进程活着 + 67 被它占住）
dhcp_serving() {
  [ -f "$DATA/dnsmasq.pid" ] || return 1
  kill -0 "$(cat "$DATA/dnsmasq.pid")" 2>/dev/null || return 1
  port67_busy
}

# 第二层：DHCP ACK 已发出——这是「地址确实分配成功」的唯一硬证据。
# dnsmasq 在 Android 上把日志交给 logd（实测 -l 指定的文件只有缓冲后的残片，不实时），
# 所以只能从 logcat 读。行格式实测：
#   I/dnsmasq ( 9291): 287454020 DHCPACK(veth0) 192.168.8.2 aa:17:2c:06:b3:5b
dhcp_ack_lines() {
  logcat -d -s dnsmasq 2>/dev/null | $BB grep -F "DHCPACK("
}

dhcp_ack_count() {
  n=$(dhcp_ack_lines | $BB wc -l 2>/dev/null)
  [ -z "$n" ] && n=0
  echo "$n"
}

# 只认「接管开始之后新增的」ACK，避免把上一次的旧记录当成这次成功
dhcp_acked() {
  base=$($BB cat "$DHCP_ACKBASE" 2>/dev/null); [ -z "$base" ] && base=0
  now=$(dhcp_ack_count)
  if [ "$now" -gt "$base" ]; then
    lines=$(dhcp_ack_lines | $BB tail -n $((now - base)))
  elif [ "$now" -eq "$base" ]; then
    # 没有新增就是没有新增，绝不能退回去拿旧记录充数
    return 1
  else
    # now < base：logcat 缓冲区已经滚过一轮，只能看最近几条
    lines=$(dhcp_ack_lines | $BB tail -n 20)
  fi
  [ -z "$lines" ] && return 1
  for i in $(usb_ifaces); do
    echo "$lines" | $BB grep -qF "DHCPACK($i) $PREFIX." && return 0
  done
  return 1
}

# 第三层：客户端已参与网络通信。
# 这里必须读 ip neigh 的 NUD 状态；/proc/net/arp 的 Flags 只有 0x0/0x2，
# 没有 REACHABLE/STALE 之类的状态位，拿它当「已解析」是错的。
usb_neigh_ok() {
  # 默认只认本网段；系统 tethering 接管时对端在它自己的网段（实测 66 段），传 * 表示不限
  pat="${1:-$PREFIX.}"
  for i in $(usb_ifaces); do
    ip neigh show dev "$i" 2>/dev/null | $BB awk -v p="$pat" '
      (p=="*" || index($1,p)==1) && $1 !~ /^169\.254/ && ($0 ~ /REACHABLE|STALE|DELAY|PROBE|PERMANENT/) {ok=1}
      END{exit !ok}' && return 0
  done
  return 1
}

# 兼容保留：ARP 表里出现本网段地址，只算「有过交互」的弱信号，不作为成功依据
usb_arp_seen() {
  for i in $(usb_ifaces); do
    $BB awk -v d="$i" -v p="$PREFIX." '$6==d && $3 ~ /0x[23]/ && $1 !~ /^169\.254/ && index($1,p)==1 {ok=1} END{exit !ok}' /proc/net/arp && return 0
  done
  return 1
}

# 客户端已经能正常用（日常判据：邻居表里有本网段地址且已解析）
usb_client_ok() { usb_neigh_ok; }

# wait_for <秒> <函数>：轮询直到成功或超时，不靠固定 sleep 猜
wait_for() {
  t=$1; fn=$2
  i=0; lim=$((t * 5))
  while [ "$i" -lt "$lim" ]; do
    $fn && return 0
    $BB sleep 0.2 2>/dev/null || sleep 1
    i=$((i + 1))
  done
  return 1
}

dhcp_lock() {
  i=0
  while ! mkdir "$DHCP_LOCK" 2>/dev/null; do
    ts=$($BB cat "$DHCP_LOCK/ts" 2>/dev/null); [ -z "$ts" ] && ts=0
    # 陈旧锁（上一步被 kill 掉）超过 120 秒直接接管
    [ $(( $(date +%s) - ts )) -gt 120 ] && { rm -rf "$DHCP_LOCK"; continue; }
    i=$((i + 1)); [ "$i" -ge 8 ] && return 1
    $BB sleep 1
  done
  date +%s > "$DHCP_LOCK/ts"
  echo $$ > "$DHCP_LOCK/pid"
}

dhcp_unlock() { rm -rf "$DHCP_LOCK"; }

# 冷却：一次失败后 180 秒内不再折腾，避免热点刚起来又被关
dhcp_cooling() {
  last=$($BB cat "$DHCP_STAMP" 2>/dev/null); [ -z "$last" ] && last=0
  [ $(( $(date +%s) - last )) -lt 180 ]
}

# ---------- 落地校验 ----------
# 「临时分配成功」不等于「长期可用」。热点重新接管 DHCP 之后必须回头确认三件事：
#   a) USB 接口的网关地址还在（系统有没有顺手把接口地址改掉）
#   b) 热点网段有没有和 USB 网段撞车（撞了就是两个 DHCP 抢同一个 /24）
#   c) 客户端是否还能解析到（infinite 租约不等于服务端重新接管后仍认可这个地址）
usb_net_state() {
  ifs=$(usb_ifaces); [ -z "$ifs" ] && { echo down; return 0; }

  # 系统 tethering 服务这条链路时，网关地址不是我们的 $GW（实测是 192.168.66.x），
  # 只要对端拿到了地址就算通，不要因为「不是 8 段」判成 no_gw
  if sys_dhcp_any "$ifs"; then
    usb_neigh_ok '*' && { echo ok; return 0; }
    echo no_peer
    return 0
  fi

  gwok=0
  for i in $ifs; do
    ip -o -4 addr show dev "$i" 2>/dev/null | $BB grep -q " $GW/" && gwok=1
  done
  [ "$gwok" = 1 ] || { echo no_gw; return 0; }

  clash=$(ip -o -4 addr show 2>/dev/null | $BB awk -v p="$PREFIX." -v usb="$ifs" '
    index($4,p)==1 {
      d=$2; own=0
      n=split(usb,a," "); for(i=1;i<=n;i++) if(a[i]==d) own=1
      if(!own){print d; exit}
    }')
  [ -n "$clash" ] && { echo conflict; return 0; }

  usb_neigh_ok || { echo no_peer; return 0; }
  echo ok
}

# 上行（能不能上网）和 USB 链路是两个独立指标：单 Wi-Fi 通道机型开热点会让 wlan0 掉线，
# 那不是 USB DHCP 的失败，不能混成一个结论。60 秒缓存，避免每轮都 ping。
uplink_state() {
  now=$(date +%s)
  ts=$($BB cat "$DATA/uplink.ts" 2>/dev/null); [ -z "$ts" ] && ts=0
  if [ $((now - ts)) -lt 60 ]; then
    r=$($BB cat "$DATA/uplink.res" 2>/dev/null); [ -z "$r" ] && r=unknown
    echo "$r"; return 0
  fi
  if ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 || ping -c 1 -W 2 114.114.114.114 >/dev/null 2>&1; then
    echo ok > "$DATA/uplink.res"
  else
    echo down > "$DATA/uplink.res"
  fi
  echo "$now" > "$DATA/uplink.ts"
  $BB cat "$DATA/uplink.res"
}

# ---------- 崩溃恢复 ----------
# 断电、进程被 kill、USB 突然拔出都可能停在中间阶段，正常流程里的回滚不会执行。
# 所以每次启动都要独立检查一次：以真实系统状态为准，不盲信阶段文件。
dhcp_recover() {
  st=$($BB cat "$DHCP_STATE" 2>/dev/null); [ -z "$st" ] && st=idle
  [ "$st" = idle ] && return 0

  # 1) 残留的 dnsmasq 一律清掉（按真实进程判断，不看阶段文件）
  stop_dnsmasq
  wait_for 6 port67_free

  # 2) 热点按介入前的真实记录还原：原本开着才开回来，原本关着不动
  orig=$($BB cat "$DHCP_APORIG" 2>/dev/null)
  if [ "$orig" = 1 ] && [ "$(ap_running)" = 0 ]; then
    hs wifi 1
    wait_for 15 port67_busy
  fi

  # 3) 清锁与阶段，留一条恢复记录
  rm -rf "$DHCP_LOCK"
  echo idle > "$DHCP_STATE"
  echo "recovered:$st" > "$DHCP_LAST"
  log "崩溃恢复: 停在 $st，已清锁并还原（热点原状态 ${orig:-?}）"
}

# 同一个 USB 连接周期只允许一次接管：反复插拔才会重新进入，避免来回关热点
usb_cycle_reset() {
  [ "$(usb_online)" = 1 ] || rm -f "$DHCP_CYCLE"
}

usb_dhcp_fail() {
  stop_dnsmasq
  # USB 拔了不算失败：静默收场，不留冷却
  if [ "$(usb_online)" != 1 ]; then
    echo idle > "$DHCP_STATE"
    dhcp_unlock
    log "DHCP: USB 已拔出，放弃本次接管（$1）"
    return 0
  fi
  echo "fail:$1" > "$DHCP_LAST"
  echo cooldown > "$DHCP_STATE"
  log "DHCP 接管失败: $1（接口 $(usb_ifaces) 系统DHCP $(sys_dhcp_any "$(usb_ifaces)" && echo 在 || echo 无)）"
  # 回滚：先让出 67，再把热点还原成本来的样子
  wait_for 6 port67_free
  [ "$($BB cat "$DHCP_APORIG" 2>/dev/null)" = 1 ] && hs wifi 1
  wait_for 10 port67_busy
  date +%s > "$DHCP_STAMP"
  dhcp_unlock
  return 1
}

# 上一轮被强杀留下的锁：持锁进程没了、锁又过期，就地恢复，不必等重启
usb_dhcp_reap() {
  [ -d "$DHCP_LOCK" ] || return 0
  ts=$($BB cat "$DHCP_LOCK/ts" 2>/dev/null); [ -z "$ts" ] && ts=0
  [ $(( $(date +%s) - ts )) -lt 120 ] && return 0
  dhcp_recover
}

usb_dhcp_tick() {
  usb_cycle_reset
  usb_dhcp_reap
  [ "$(usb_online)" = 1 ] || return 0
  [ "$(usb_off_flag)" = 0 ] || return 0
  ifs=$(usb_ifaces); [ -z "$ifs" ] && return 0
  # 接管要先把热点关掉才能拿到 67，代价太大，默认不做。
  # 实测这正是「开了无线 ADB 之后热点起不来」的来源：adbd 重启会让 USB 重新枚举，
  # 触发一轮接管，热点被关掉之后系统那边的 tethering 状态还没回来，页面就一直是未开启。
  if [ "$USB_DHCP_TAKEOVER" != 1 ]; then
    # 关键：这里用独立的 take key，不能碰 dhcpw。dhcpw 是 apply 的 DHCP 三分支
    # （热点开→stop / 系统接管→stop / 否则自建）在维护的状态标记，值在 self/sys 之间
    # 来回跳。若这里再写 log_chg dhcpw "off"，两个函数共用一把 key，每 5 秒互相覆盖，
    # apply 下一轮又看到值变了就再 sync_dnsmasq 一遍 —— dnsmasq 起了又停、起了又停，
    # 租约永远发不出去，热点连上的设备没网、USB 对端拿不到 IP，就是这个震荡。
    log_chg take "off" "DHCP: 接管关闭（默认），USB 地址交给系统或按 apply 自建"
    return 0
  fi
  # 热点没开时不存在 67 竞争，apply 里常规的 sync_dnsmasq 就够了；
  # 这里只处理「热点开着 + USB 对端拿不到地址」这一种情况
  [ "$(ap_running)" = 1 ] || return 0
  # 系统 tethering 已经在服务这条链路，地址由它负责，接管既无必要也抢不到端口
  sys_dhcp_any "$ifs" && return 0
  usb_client_ok && return 0
  # 本周期已经试过：后续触发只更新状态，不再重复开关热点
  [ -f "$DHCP_CYCLE" ] && return 0
  dhcp_cooling && return 0
  dhcp_lock || return 0
  touch "$DHCP_CYCLE"

  # 记录介入前热点是否真的在开，原来关着就不擅自打开
  ap_orig=$(ap_running)
  echo "$ap_orig" > "$DHCP_APORIG"
  log "DHCP 接管开始: 接口 $ifs · 热点此前 ap_orig=$ap_orig · 系统DHCP 无"

  # 1) 让系统释放 67
  echo hotspot_stopping > "$DHCP_STATE"
  [ "$ap_orig" = 1 ] && hs wifi 0
  echo wait_port > "$DHCP_STATE"
  wait_for 10 port67_free || { usb_dhcp_fail "release_timeout"; return 1; }

  # 2) 临时起 dnsmasq，只服务 USB 侧；先记 ACK 基线，只认新增的
  dhcp_ack_count > "$DHCP_ACKBASE"
  echo dnsmasq_starting > "$DHCP_STATE"
  sync_dnsmasq "$ifs"
  if ! wait_for 3 dhcp_serving; then
    usb_dhcp_fail "dnsmasq_start_failed"
    return 1
  fi

  # 3) 以 DHCPACK 为成功依据；邻居解析只作辅助验证
  echo wait_client > "$DHCP_STATE"
  if wait_for 25 dhcp_acked; then
    log "DHCP: 收到 ACK，对端地址 $(usb_peer)"
  elif usb_neigh_ok; then
    # 邻居已解析但没抓到 ACK：地址确实下发过，如实记一笔，不推翻结果
    echo ack_missing > "$DHCP_LAST"
    log "DHCP: 未抓到 ACK，但邻居已解析 $(usb_peer)，按已下发处理"
  else
    usb_dhcp_fail "no_client_ip"
    return 1
  fi

  # 4) 撤掉 dnsmasq，确认 67 真的释放
  echo dnsmasq_stopping > "$DHCP_STATE"
  stop_dnsmasq
  wait_for 6 port67_free

  # 5) 还原热点并等系统 DHCP 重新接管 67
  echo hotspot_restoring > "$DHCP_STATE"
  if [ "$ap_orig" = 1 ]; then
    hs wifi 1
    wait_for 15 port67_busy
  fi

  # 6) 落地校验：最容易「当场成功、长期偶发失效」的一步
  echo verify_restored > "$DHCP_STATE"
  nets=$(usb_net_state)
  echo "$nets" > "$DHCP_NET"
  [ "$nets" = ok ] || echo "verify:$nets" > "$DHCP_LAST"
  log "DHCP 接管完成: 落地校验 $nets · 热点 ap=$(ap_running) · 对端 $(usb_peer)"

  echo idle > "$DHCP_STATE"
  date +%s > "$DHCP_STAMP"
  dhcp_unlock
  return 0
}

# 永久保活：被系统关掉就重新拉起
keepalive() {
  if [ "$KEEP_WIFI" = 1 ] && [ "$(ap_running)" = 0 ]; then
    # 热点掉线诊断：记下当时的上下文，方便判断是系统主动关的、还是上行断了
    # 单 WiFi 通道机型开热点会让 wlan0 掉线，若又没有蜂窝数据，热点下的设备全都上不了网。
    log_chg apdrop "$(uplink_state):$(usb_online):$(getprop sys.usb.config)" \
      "热点: 检测到已关闭，保活重新拉起（上行 $(uplink_state) USB $(usb_online) config=$(getprop sys.usb.config)）"
    hs wifi 1
  fi
  if [ "$KEEP_USB" = 1 ] && [ "$(usb_online)" = 1 ] && [ "$(usb_off_flag)" = 0 ]; then
    # native 模式由系统自己维持，模块插手重建 gadget 只会打断它的 tethering
    [ "$USB_NATIVE" = 1 ] && return 0
    fn=$(usb_net_pick)
    # 系统插拔后会回落成 mtp,adb，网卡就没了，这里按选定类型补回来
    case "$(getprop sys.usb.config)" in
      *"$fn"*) ;;
      *) hs usb 1 ;;
    esac
  fi
}

set_keep() {
  case "$1" in
    wifi) cfg_set KEEP_WIFI "$2"; KEEP_WIFI="$2"; log "保活: 热点 ${2}"; echo 0 ;;
    usb)  cfg_set KEEP_USB "$2";  KEEP_USB="$2";  log "保活: USB 共享 ${2}"; echo 0 ;;
    *) echo 1 ;;
  esac
}

# ---------- 无线 ADB ----------
# 老做法是把 persist.adb.tcp.port=5555 写进 persist 分区，代价是 vivo 的
# 开发者选项一读到这条属性就直接拒绝进入，而且禁用 Magisk 模块也不会把它清掉。
# 这里只用运行时属性 service.adb.tcp.port（重启即失效），"永久"由模块开机恢复，
# 系统属性层面不留痕，开发者选项随时能进。
adb_listening() {
  p=$(getprop service.adb.tcp.port); [ -z "$p" ] && p=$ADB_PORT
  ss -ltn 2>/dev/null | $BB grep -q ":$p "
}

adb_closed() { adb_listening && return 1; return 0; }

adbd_running() { [ "$(getprop init.svc.adbd)" = "running" ]; }

# 0=关闭 1=监听中 2=配置了但没监听（adbd 没起来或被 ROM 顶掉）
adb_tcp_code() {
  p=$(getprop service.adb.tcp.port)
  [ -z "$p" ] && { echo 0; return; }
  ss -ltn 2>/dev/null | $BB grep -q ":$p " && echo 1 || echo 2
}

adb_tcp_on() {
  p="$1"; [ -z "$p" ] && p=$ADB_PORT
  case "$p" in ''|*[!0-9]*) return 1;; esac
  [ "$p" -ge 1024 ] && [ "$p" -le 65535 ] || return 1
  setprop service.adb.tcp.port "$p"
  # ctl.restart 是 init 的属性服务控制，比 stop/start 少一次状态竞争；
  # 个别 ROM 不认这个触发器，退回 stop/start
  setprop ctl.restart adbd 2>/dev/null
  if ! wait_for 4 adb_listening; then
    stop adbd 2>/dev/null
    start adbd 2>/dev/null
    wait_for 5 adb_listening
  fi
  cfg_set ADB_TCP 1
  cfg_set ADB_PORT "$p"
  ADB_TCP=1; ADB_PORT="$p"
  log "无线 ADB: 开启 tcp:$p · 监听 $(adb_tcp_code)（1=正常 2=已配置未监听）"
  return 0
}

adb_tcp_off() {
  # resetprop 能把属性真正删掉；setprop 空值在个别 ROM 上会被忽略
  if [ -x /data/adb/magisk/resetprop ]; then
    /data/adb/magisk/resetprop --delete service.adb.tcp.port 2>/dev/null
  elif command -v resetprop >/dev/null 2>&1; then
    resetprop --delete service.adb.tcp.port 2>/dev/null
  else
    setprop service.adb.tcp.port ""
  fi
  setprop ctl.restart adbd 2>/dev/null
  if ! wait_for 4 adb_closed; then
    stop adbd 2>/dev/null
    start adbd 2>/dev/null
    wait_for 5 adb_closed
  fi
  cfg_set ADB_TCP 0
  ADB_TCP=0
  log "无线 ADB: 已关闭，service.adb.tcp.port 清空"
  return 0
}

# 开机自启开关：只影响下次开机的恢复动作，不动当前这次监听
adb_boot_set() {
  v="$1"; [ "$v" = "1" ] || v=0
  cfg_set ADB_BOOT "$v"
  ADB_BOOT="$v"
  if [ "$v" = "1" ]; then
    log "无线 ADB: 开机自启已开"
  else
    log "无线 ADB: 开机自启已关"
  fi
  return 0
}

# 老模块（adb_tcp_5555）把 5555 写进了 persist 分区，禁用模块不会清掉它，
# 开发者在选项页读到非空就直接拒绝进入。属性文件和内存属性都要清，
# 只删内存的话重启会从 /data/property 里读回来。
adb_persist_clear() {
  had=$(getprop persist.adb.tcp.port 2>/dev/null)
  rm -f /data/property/persist.adb.tcp.port 2>/dev/null
  if [ -x /data/adb/magisk/resetprop ]; then
    /data/adb/magisk/resetprop --delete persist.adb.tcp.port 2>/dev/null
  else
    setprop persist.adb.tcp.port "" 2>/dev/null
  fi
  if [ -z "$(getprop persist.adb.tcp.port)" ]; then
    log "persist 残留清理: ${had:-无残留} -> 已清空"
    return 0
  fi
  log "persist 残留清理失败: 仍为 $(getprop persist.adb.tcp.port)"
  return 1
}

# 开机恢复：等 adbd 真起来再改端口，太早设会被 init 覆盖
adb_tcp_restore() {
  [ "$ADB_BOOT" = 1 ] || return 0
  [ "$ADB_TCP" = 1 ] || return 0
  wait_for 40 adbd_running
  # 起来之后再让几秒：adbd 刚 ready 时设端口，偶尔会被 init 的默认值盖回去
  $BB sleep 5 2>/dev/null || sleep 5
  if adb_tcp_on "$ADB_PORT" >/dev/null 2>&1; then
    log "无线 ADB: 开机恢复端口 $ADB_PORT 成功"
  else
    log "无线 ADB: 开机恢复端口 $ADB_PORT 失败（adbd=$(getprop init.svc.adbd)）"
  fi
}

# 控制台地址：热点开着时用热点接口的真实 IP。
# 系统热点的网段由 TetheringManager 自己选（实测 vivo 选了 192.168.138.x），
# 跟模块设的 192.168.8.x 不是一回事，写死 $GW 会让连上热点的人打不开页面。
# 手机连路由器时的局域网地址：同网段的电脑可以直接连
wlan_ip() {
  for i in wlan0 wlan1; do
    ip4=$(ip -o -4 addr show dev "$i" 2>/dev/null | $BB awk '$4 !~ /^127\./ {print $4; exit}' | $BB cut -d/ -f1)
    [ -n "$ip4" ] && { echo "$ip4"; return 0; }
  done
  return 1
}

web_url() {
  a=$(ap_iface)
  if [ -n "$a" ]; then
    ip4=$(ip -o -4 addr show dev "$a" 2>/dev/null | $BB awk '{print $4}' | $BB cut -d/ -f1)
    [ -n "$ip4" ] && { echo "http://$ip4:$PORT"; return; }
  fi
  # 没开热点时，系统 tethering 给 USB 接口的地址才是对端能访问的地址
  # （网段由系统选，不再是固定的 8 段，写死 GW 会给出一个打不开的链接）
  for i in $(usb_ifaces 2>/dev/null); do
    ip4=$(ip -o -4 addr show dev "$i" 2>/dev/null | $BB awk '{print $4}' | $BB cut -d/ -f1)
    [ -n "$ip4" ] && { echo "http://$ip4:$PORT"; return; }
  done
  # 连路由器时，同一局域网的电脑用 wlan0 的地址
  ip4=$(wlan_ip)
  [ -n "$ip4" ] && { echo "http://$ip4:$PORT"; return; }
  # 什么都没共享：不要编一个 8.1 出来，那个地址此时根本不存在
  echo ""
}

# 两个真正拿得出手的地址：接 USB 的对端用哪个、连热点的设备用哪个。
# 127.0.0.1 是手机自己，写出来对用户没有任何意义，页面不再显示。
web_url_ap() {
  a=$(ap_iface) || return 0
  ip4=$(ip -o -4 addr show dev "$a" 2>/dev/null | $BB awk '$4 !~ /^127\./ {print $4; exit}' | $BB cut -d/ -f1)
  [ -n "$ip4" ] && echo "http://$ip4:$PORT"
}

web_url_usb() {
  for i in $(usb_ifaces 2>/dev/null); do
    ip4=$(ip -o -4 addr show dev "$i" 2>/dev/null | $BB awk '$4 !~ /^127\./ {print $4; exit}' | $BB cut -d/ -f1)
    [ -n "$ip4" ] && { echo "http://$ip4:$PORT"; return 0; }
  done
}

status_json() {
  ij=""
  # 列出全部 IPv4 接口（排除 lo）：USB 端固定 192.168.8.x，热点端用系统网段（10.x 等）
  for i in $(ip -o -4 addr show | $BB awk '$2!="lo" && $4 !~ /^127\./ {print $2}' | $BB sort -u); do
    ip4=$(ip -o -4 addr show dev "$i" | $BB awk '$2=="'"$i"'" && $4 !~ /^127\./ {print $4; exit}')
    case "$i" in
      wlan0)               role=up ;;
      wlan2|softap*|ap*)   role=hotspot ;;
      rndis*|ncm*|usb*)    role=usb ;;
      ccmni*|rmnet*|wwan*|pdp*) role=mobile ;;
      *)                   role=other ;;
    esac
    ij="$ij{\"dev\":\"$i\",\"role\":\"$role\",\"ip\":\"$ip4\"},"
  done
  ij=$(echo "$ij" | $BB sed 's/,$//')

  cj=$(clients_json)
  cnt=$(echo "$cj" | $BB grep -o '"ip"' | $BB wc -l)

  fl=$(fwd_list)
  fj="[]"
  [ -n "$fl" ] && fj="[$(echo $fl | $BB tr ' ' ',')]"
  tg=$(usb_peer)

  cat <<EOF
{"prefix":"$PREFIX","gw":"$GW","pool_start":$POOL_START,"pool_end":$POOL_END,"build":$(nb_build),
"ifaces":[$ij],"clients":$cj,"count":$cnt,"fwd":$fj,"target":"$tg",
"batt":$(batt_json),"ap":$(ap_running),
"usb":$(usb_up),"usb_online":$(usb_online),"keep_wifi":$KEEP_WIFI,"keep_usb":$KEEP_USB,
"usb_func":"$(usb_net_pick)","usb_net_cfg":"$USB_NET","usb_native":$USB_NATIVE,"usb_linked":$(usb_func_linked),"usb_mode":"$( [ -n "$(usb_ifaces 2>/dev/null)" ] && $BB cat "$DATA/usb.mode" 2>/dev/null | $BB tr -d '\n' )",
"usb_types":"$(usb_funcs)","usb_peer":"$(usb_peer)","usb_peer_net":"$(usb_peer_net)",
"fwd_state":"$(fwd_state)","fwd_rules":"$(iptables -t nat -S NETBATT_FWD 2>/dev/null | $BB grep -c -- '--dport')",
"web_usb":"$(web_url_usb)","web_ap":"$(web_url_ap)",
"adb_tcp":$(adb_tcp_code),"adb_port":"$(getprop service.adb.tcp.port)","adb_boot":$ADB_BOOT,"adb_persist":"$(getprop persist.adb.tcp.port)",
"dhcp":"$($BB cat "$DATA/dhcp.state" 2>/dev/null || echo idle)",
"dhcp_last":"$($BB cat "$DHCP_LAST" 2>/dev/null)",
"usb_net":"$(usb_net_state)","uplink":"$(uplink_state)",
"sys_dhcp":$(sys_dhcp_any && echo 1 || echo 0),
"log_size":$(log_size "$LOG"),"log_old":$(log_size "$LOG1"),"log_max":${LOG_MAX:-3145728},
"dnsmasq":$([ -f "$DATA/dnsmasq.pid" ] && kill -0 "$(cat $DATA/dnsmasq.pid)" 2>/dev/null && echo 1 || echo 0)}
EOF
}

start_web() {
  pgrep -f "httpd -f -p $PORT" >/dev/null 2>&1 && return 0
  # CGI 目录由 busybox httpd 固定映射为 $HOME/cgi-bin，不需要也不能用 -c（-c 是配置文件路径）
  # 但 api.sh 必须有执行位，否则 httpd 对 CGI 一律 404（首页仍正常，很容易误判成路由问题）
  [ -x "$MODDIR/webroot/cgi-bin/api.sh" ] || chmod 755 "$MODDIR/webroot/cgi-bin/api.sh" 2>/dev/null
  $BB setsid $BB httpd -f -p "$PORT" -h "$MODDIR/webroot" > "$DATA/httpd.log" 2>&1 &
  sleep 1
  pgrep -f "httpd -f -p $PORT" > "$DATA/httpd.pid"
  if [ -s "$DATA/httpd.pid" ]; then
    log "控制台: 监听 $PORT，地址 $(web_url)"
  else
    log "控制台: 启动失败，httpd 日志 $($BB head -3 "$DATA/httpd.log" 2>/dev/null | $BB tr '\n' ' ')"
  fi
}

stop_web() {
  [ -f "$DATA/httpd.pid" ] && kill "$(cat $DATA/httpd.pid)" 2>/dev/null
  pkill -f "httpd -f -p $PORT" 2>/dev/null
  rm -f "$DATA/httpd.pid"
}

set_net() {
  p="$1"; s="$2"; e="$3"
  echo "$p" | $BB grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' || return 1
  [ "$s" -ge 2 ] && [ "$e" -le 254 ] && [ "$s" -lt "$e" ] || return 1
  OLDGW="$GW"
  $BB sed -i "s/^PREFIX=.*/PREFIX=$p/;s/^POOL_START=.*/POOL_START=$s/;s/^POOL_END=.*/POOL_END=$e/" "$CFG"
  . "$CFG"
  GW="$PREFIX.1"
  if [ "$OLDGW" != "$GW" ]; then
    ip -o -4 addr show | $BB awk -v w="$OLDGW/" 'index($4,w)==1{print $2"|"$4}' |
    while IFS='|' read d a; do ip addr del "$a" dev "$d" 2>/dev/null; done
  fi
  rm -f "$DATA/dnsmasq.leases"
  stop_dnsmasq
  log "网段修改: $OLDGW -> $GW，池 .$POOL_START-.$POOL_END"
  apply
  return 0
}

# 写配置项：文件里没有该键时追加
cfg_set() {
  if $BB grep -q "^$1=" "$CFG" 2>/dev/null; then
    $BB sed -i "s/^$1=.*/$1=$2/" "$CFG"
  else
    echo "$1=$2" >> "$CFG"
  fi
}

# set_batt <上限> [下限]  下限省略时默认取 上限-5
set_batt() {
  p="$1"; r="$2"
  [ "$p" -ge 20 ] && [ "$p" -le 100 ] || return 1
  [ -z "$r" ] && r=$((p - 5))
  [ "$r" -ge 5 ] && [ "$r" -le 99 ] || return 1
  [ "$r" -lt "$p" ] || return 1
  cfg_set PAUSE_CAP "$p"
  cfg_set RESUME_CAP "$r"
  PAUSE_CAP=$p
  RESUME_CAP=$r
  log "充电阈值: 上限 $p% 恢复 $r%"
  chg_once
  return 0
}
