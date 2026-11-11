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
  set -- -k -R -n -K -x "$DATA/dnsmasq.pid" -u dns_tether -l "$DATA/dnsmasq.leases" \
         -F "$PREFIX.$POOL_START,$PREFIX.$POOL_END,infinite" \
         -O "3,$GW" -O "6,$DNS1,$DNS2" \
         --dhcp-option-force=43,ANDROID_METERED \
         -S "$DNS1" -S "$DNS2"
  for i in $want; do set -- "$@" -i "$i"; done

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
  repair_usb
}

# ---------- 端口转发 ----------
# 热点设备访问本机这些端口时，转给 USB 端那台固定设备；列表为空＝不转发

# USB 端那台设备的实际地址：优先 DHCP 租约，其次 ARP 邻居，都没有才兜底 .2
usb_peer() {
  p=""
  [ -f "$DATA/dnsmasq.leases" ] && p=$($BB awk '$3 ~ /^[0-9]+\./ && $3 !~ /^169\.254/ {print $3; exit}' "$DATA/dnsmasq.leases")
  [ -z "$p" ] && p=$($BB awk '$6=="ncm0" && $1 !~ /^169\.254/ {print $1; exit}' /proc/net/arp 2>/dev/null)
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

# USB 客户端拿不到地址：热点占着 67，或者刚插上时热点正开着
usb_needs_fix() {
  [ "$(usb_online)" = 1 ] || return 1
  [ "$(usb_off_flag)" = 0 ] || return 1
  ip link show ncm0 >/dev/null 2>&1 || return 1
  # 已经有本网段的客户端 → 正常
  $BB awk -v p="$PREFIX." '$6=="ncm0" && $3 ~ /0x2/ && index($1,p)==1 {ok=1} END{exit !ok}' /proc/net/arp && return 1
  # 有 169.254 客户端 → 说明 DHCP 失败过，需要让出端口补发
  $BB awk '$6=="ncm0" && $3 ~ /0x2/ && $1 ~ /^169\.254\./ {f=1} END{exit !f}' /proc/net/arp
}

# 短暂让出 67：关热点 → 发地址 → 再开热点
repair_usb() {
  usb_needs_fix || return 0
  [ "$(ap_running)" = 1 ] || return 0
  now=$(date +%s 2>/dev/null); [ -z "$now" ] && now=0
  last=$($BB cat "$DATA/repair.ts" 2>/dev/null); [ -z "$last" ] && last=0
  [ $((now - last)) -lt 120 ] && return 0
  echo "$now" > "$DATA/repair.ts"
  usbif=""
  for i in rndis0 ncm0 usb0; do ip link show "$i" >/dev/null 2>&1 && usbif="$usbif $i"; done
  hs wifi 0
  sleep 4
  sync_dnsmasq "$usbif"
  sleep 8
  hs wifi 1
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
