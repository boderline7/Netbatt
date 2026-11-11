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
POOL_END=2
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

. "$CFG"

GW="$PREFIX.1"

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

  # 永久租约：热点开时会抢走 67 端口，此时没法续租，只能让客户端一次拿到就不再续
  # 池只有一个地址（.2），谁接 USB 谁就固定拿它
  # 注意 -L（租约文件）和 -l（日志文件）是两个选项，不能混用
  # --log-dhcp：把四步交互写进 logd，ACK 判定靠它（文件日志有缓冲延迟，不可实时读）
  set -- -k -R -n -K -x "$DATA/dnsmasq.pid" -u dns_tether \
         -L "$DATA/dnsmasq.leases" --log-dhcp \
         -F "$PREFIX.$POOL_START,$PREFIX.$POOL_END,infinite" \
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
}

apply() {
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

  # USB 共享端由模块接管地址；热点端（wlan2）用系统自己的网段，不碰
  USBDS=""
  for i in $DS; do
    case "$i" in
      rndis*|ncm*|usb[0-9]*)
        # 用户手动关了共享就不再接管地址
        if [ "$(usb_off_flag)" = 1 ]; then continue; fi
        for a in $(echo "$A" | $BB awk -v d="$i" -v g="$GW/24" '
            $2==d && $4!=g && $4 !~ /^169\.254\./ {print $4}'); do
          ip addr del "$a" dev "$i" 2>/dev/null
          A=$(ip -o -4 addr show)
        done
        if ! echo "$A" | $BB awk -v d="$i" -v w="$GW/" 'index($4,w)==1 && $2==d{f=1} END{exit !f}'; then
          ip addr add "$GW/24" dev "$i" 2>/dev/null
          A=$(ip -o -4 addr show)
        fi
        USBDS="$USBDS $i"
        ;;
    esac
  done

  [ -n "$DS" ] && echo "$DS" > "$DATA/ifaces"
  echo "$GW" > "$DATA/gw"

  # 热点网段与 USB 网段互访：热点客户端要能直接访问 USB 那台设备的端口
  HSIP=$(ip -o -4 addr show dev wlan2 2>/dev/null | $BB awk '{sub(/\/.*/,"",$4); print $4; exit}')
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

  # 系统热点会用 67 端口起自己的 DHCP，抢了它热点就起不来，只能二选一
  if [ "$(ap_running)" = 1 ]; then stop_dnsmasq; else sync_dnsmasq "$USBDS"; fi
  usb_dhcp_tick
}

# ---------- 端口转发 ----------
# 热点设备访问本机这些端口时，转给 USB 端那台固定设备；列表为空＝不转发

# USB 端那台设备的实际地址：优先 DHCP 租约，其次 ARP 邻居，都没有才兜底 .2
usb_peer() {
  p=""
  # 邻居表是实时状态，优先；租约文件在 infinite 租约下不一定及时落盘，只能当次选
  for i in $(usb_ifaces); do
    [ -n "$p" ] && break
    p=$($BB awk -v d="$i" '$6==d && $3 ~ /0x[23]/ && $1 !~ /^169\.254/ {print $1; exit}' /proc/net/arp 2>/dev/null)
  done
  [ -z "$p" ] && [ -f "$DATA/dnsmasq.leases" ] && \
    p=$($BB awk '$3 ~ /^[0-9]+\./ && $3 !~ /^169\.254/ {print $3; exit}' "$DATA/dnsmasq.leases")
  [ -z "$p" ] && p="$PREFIX.2"
  echo "$p"
}

fwd_list() {
  [ -f "$DATA/fwd.list" ] || return 0
  $BB cat "$DATA/fwd.list" | $BB tr '\n' ' ' | $BB sed 's/ *$//'
}

sync_fwd() {
  ports=$(fwd_list)
  tg=$(usb_peer)
  # 用独立链；端口列表和目标地址都没变就不重建，否则计数器每 5 秒被清零
  iptables -t nat -N NETBATT_FWD 2>/dev/null
  iptables -t nat -N NETBATT_SNAT 2>/dev/null
  # 热点接口进来的流量先过这个链；列表为空时链是空的，等于不转发
  for i in wlan2 ap0 softap0 swlan0; do
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
  for p in $ports; do
    iptables -t nat -A NETBATT_FWD -p tcp --dport "$p" -j DNAT --to-destination "$tg:$p" 2>/dev/null
    iptables -t nat -A NETBATT_FWD -p udp --dport "$p" -j DNAT --to-destination "$tg:$p" 2>/dev/null
    iptables -t nat -A NETBATT_SNAT -o ncm0 -p tcp --dport "$p" -j MASQUERADE 2>/dev/null
    iptables -t nat -A NETBATT_SNAT -o ncm0 -p udp --dport "$p" -j MASQUERADE 2>/dev/null
  done
  echo "$tg" > "$DATA/fwd.target"
}

fwd_add() {
  p="$1"
  case "$p" in ''|*[!0-9]*) return 1;; esac
  [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || return 1
  cur=$(fwd_list)
  case " $cur " in *" $p "*) return 0;; esac
  echo "$cur $p" | $BB sed 's/^ *//' > "$DATA/fwd.list"
  sync_fwd
}

fwd_del() {
  p="$1"
  cur=$(fwd_list); new=""
  for x in $cur; do [ "$x" = "$p" ] || new="$new $x"; done
  echo $new > "$DATA/fwd.list"
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
}

chg_once() {
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

  chg_apply "$want"
  echo "$want" > "$DATA/chg.state"
}

chg_ctl() {
  case "$1" in
    start)
      rm -f "$DATA/chg.off"
      touch "$DATA/chg.on"
      chg_once
      ;;
    stop)
      rm -f "$DATA/chg.on"
      touch "$DATA/chg.off"
      chg_apply restore
      echo on > "$DATA/chg.state"
      ;;
    restart)
      rm -f "$DATA/chg.on" "$DATA/chg.off"
      chg_apply restore
      sleep 1
      touch "$DATA/chg.on"
      chg_once
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

ap_running() {
  ip link show wlan2 >/dev/null 2>&1 && echo 1 || echo 0
}

# 让特权应用去开/关共享：hs <wifi|usb> <0|1>
hs() {
  t=0
  [ "$1" = usb ] && t=1
  # 开热点前先把我们的 DHCP 让出来，否则系统 DHCP 绑不上 67，热点直接起不来
  if [ "$t" = 0 ] && [ "$2" != "0" ]; then stop_dnsmasq; sleep 1; fi
  am broadcast -n com.netbatt.console/.TetherReceiver --ei type $t --ez on "$2" >/dev/null 2>&1
  if [ "$t" = 1 ]; then
    sleep 1
    if [ "$2" = "0" ]; then
      # 系统从没真正 tether 过 USB，只能自己把复合配置切回去，网卡才会消失
      touch "$DATA/usb.off"
      setprop sys.usb.config mtp,adb
    else
      rm -f "$DATA/usb.off"
      setprop sys.usb.config ncm,adb
    fi
  fi
}

# 用户手动关过 USB 共享后，保活不要再自动拉起
usb_off_flag() { [ -f "$DATA/usb.off" ] && echo 1 || echo 0; }

usb_online() {
  [ "$(cat /sys/class/power_supply/usb/online 2>/dev/null)" = "1" ] && echo 1 || echo 0
}

# USB 共享是否真的在链路上：复合配置里必须有 ncm，否则电脑看不到网卡
usb_up() {
  case "$(getprop sys.usb.config)" in *ncm*) echo 1; return 0;; esac
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
  for i in $(usb_ifaces); do
    ip neigh show dev "$i" 2>/dev/null | $BB awk -v p="$PREFIX." '
      index($1,p)==1 && $1 !~ /^169\.254/ && ($0 ~ /REACHABLE|STALE|DELAY|PROBE|PERMANENT/) {ok=1}
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
    return 0
  fi
  echo "fail:$1" > "$DHCP_LAST"
  echo cooldown > "$DHCP_STATE"
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
  # 热点没开时不存在 67 竞争，apply 里常规的 sync_dnsmasq 就够了；
  # 这里只处理「热点开着 + USB 对端拿不到地址」这一种情况
  [ "$(ap_running)" = 1 ] || return 0
  usb_client_ok && return 0
  # 本周期已经试过：后续触发只更新状态，不再重复开关热点
  [ -f "$DHCP_CYCLE" ] && return 0
  dhcp_cooling && return 0
  dhcp_lock || return 0
  touch "$DHCP_CYCLE"

  # 记录介入前热点是否真的在开，原来关着就不擅自打开
  ap_orig=$(ap_running)
  echo "$ap_orig" > "$DHCP_APORIG"

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
    :
  elif usb_neigh_ok; then
    # 邻居已解析但没抓到 ACK：地址确实下发过，如实记一笔，不推翻结果
    echo ack_missing > "$DHCP_LAST"
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

  echo idle > "$DHCP_STATE"
  date +%s > "$DHCP_STAMP"
  dhcp_unlock
  return 0
}

# 永久保活：被系统关掉就重新拉起
keepalive() {
  [ "$KEEP_WIFI" = 1 ] && [ "$(ap_running)" = 0 ] && hs wifi 1
  if [ "$KEEP_USB" = 1 ] && [ "$(usb_online)" = 1 ] && [ "$(usb_off_flag)" = 0 ]; then
    # 系统插拔后会回落成 mtp,adb，网卡就没了，这里补回 ncm
    case "$(getprop sys.usb.config)" in
      *ncm*) ;;
      *) hs usb 1; sleep 1; setprop sys.usb.config ncm,adb ;;
    esac
  fi
}

set_keep() {
  case "$1" in
    wifi) cfg_set KEEP_WIFI "$2"; KEEP_WIFI="$2"; echo 0 ;;
    usb)  cfg_set KEEP_USB "$2";  KEEP_USB="$2";  echo 0 ;;
    *) echo 1 ;;
  esac
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
{"prefix":"$PREFIX","gw":"$GW","pool_start":$POOL_START,"pool_end":$POOL_END,
"ifaces":[$ij],"clients":$cj,"count":$cnt,"fwd":$fj,"target":"$tg",
"batt":$(batt_json),"ap":$(ap_running),
"usb":$(usb_up),"usb_online":$(usb_online),"keep_wifi":$KEEP_WIFI,"keep_usb":$KEEP_USB,
"dhcp":"$($BB cat "$DATA/dhcp.state" 2>/dev/null || echo idle)",
"dhcp_last":"$($BB cat "$DHCP_LAST" 2>/dev/null)",
"usb_net":"$(usb_net_state)","uplink":"$(uplink_state)",
"web":"http://$GW:$PORT","dnsmasq":$([ -f "$DATA/dnsmasq.pid" ] && kill -0 "$(cat $DATA/dnsmasq.pid)" 2>/dev/null && echo 1 || echo 0)}
EOF
}

start_web() {
  pgrep -f "httpd -f -p $PORT" >/dev/null 2>&1 && return 0
  $BB setsid $BB httpd -f -p "$PORT" -h "$MODDIR/webroot" > "$DATA/httpd.log" 2>&1 &
  sleep 1
  pgrep -f "httpd -f -p $PORT" > "$DATA/httpd.pid"
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
  chg_once
  return 0
}
