#!/system/bin/sh
# 采集层：只读硬件与系统状态，不做决策、不写任何硬件节点。
# 对外输出 5 个事实：POWER（已确认的供电）、POWER_RAW、AP_REAL、CLIENTS、CHG_HELD。
# 依赖 nb-core.sh。

# ---------- 热点接口 ----------
# 各家 ROM 的 AP 接口名不同：高通/小米 wlan2，联发科/vivo ap0，也有 swlan0/softap0/wlan1。
AP_IFACES="wlan2 ap0 swlan0 softap0 wlan1"

ap_iface() {
  for i in $AP_IFACES; do
    ip link show "$i" >/dev/null 2>&1 && { echo "$i"; return 0; }
  done
  # 兜底：任何被设成 AP 模式的接口（部分 ROM 自己起名）
  i=$(iw dev 2>/dev/null | $BB awk '/Interface/{n=$2} /type AP/{print n; exit}')
  [ -n "$i" ] && { echo "$i"; return 0; }
  return 1
}

ap_is_up() {
  a=$(ap_iface) || return 1
  ip -o -4 addr show dev "$a" 2>/dev/null | $BB grep -q 'inet '
}

ap_down() { ap_is_up && return 1; return 0; }

# 只看接口存在不够：热点关掉后 ap0 会残留成 DOWN、无地址
ap_running() { ap_is_up && echo 1 || echo 0; }

# 已连上热点的设备数。iw 拿不到时退回 ARP 表。
ap_clients() {
  a=$(ap_iface 2>/dev/null) || { echo 0; return 0; }
  n=$(iw dev "$a" station dump 2>/dev/null | $BB grep -c '^Station')
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" -eq 0 ]; then
    n=$(ip neigh show dev "$a" 2>/dev/null | $BB grep -cE 'REACHABLE|STALE|DELAY')
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
  fi
  echo "$n"
}

# ---------- 供电事实 ----------

# 充电器是否正在供电。
# 只信 online：present 只表示接口/器件存在，高通平台上 usb/present、dc/present
# 常常恒为 1，拿它当“有电”会导致没插线也开热点。present 仅在缺 online 时兜底。
raw_power() {
  for n in usb ac dc wireless; do
    p=/sys/class/power_supply/$n
    if [ -f "$p/online" ]; then
      [ "$(cat "$p/online" 2>/dev/null)" = "1" ] && return 0
    elif [ -f "$p/present" ]; then
      [ "$(cat "$p/present" 2>/dev/null)" = "1" ] && return 0
    fi
  done
  return 1
}

# 结论出自哪个节点，排查误判时看日志用
power_source() {
  for n in usb ac dc wireless; do
    p=/sys/class/power_supply/$n
    if [ -f "$p/online" ]; then
      [ "$(cat "$p/online" 2>/dev/null)" = "1" ] && { echo "$n/online"; return 0; }
    elif [ -f "$p/present" ]; then
      [ "$(cat "$p/present" 2>/dev/null)" = "1" ] && { echo "$n/present"; return 0; }
    fi
  done
  echo "-"
}

# 所有供电节点的一行快照，开机记一次，换设备排查时不用再连 adb
power_snapshot() {
  s=""
  for d in /sys/class/power_supply/*; do
    n=${d##*/}
    for f in online present status; do
      [ -f "$d/$f" ] && s="$s $n.$f=$(cat "$d/$f" 2>/dev/null)"
    done
  done
  echo "$s"
}

# 电池正在进电。current_now 的符号方向各平台不一致（有的放电为正、有的为负），
# 当判据会在骁龙上“没插线也判有电”，所以只看 status。
# 停充后 status 会变成 Not charging，属于“线还插着”，由 CHG_HELD 分支处理。
raw_charging() {
  case "$(cat "$BATT/status" 2>/dev/null)" in
    Charging|Full) return 0 ;;
  esac
  return 1
}

# 软件主动停充中。只用来排除“自己停充导致的假断电”，不参与任何热点决策。
chg_held() {
  [ -f "$DATA/chg.on" ] || return 1
  [ "$(cat "$DATA/chg.state" 2>/dev/null)" = "off" ]
}

# 停充会不会把 online 拉成 0。限流通道不动充电输入，online 一直准；
# 只有开关通道（input_suspend）才需要靠 status 猜“线还插着”。
chg_port_held() {
  chg_held || return 1
  [ "$(chg_channel)" != "current" ]
}

# 供电确认（回滞）：原始信号持续 ON_CONFIRM 秒才算有电，
# 持续 OFF_CONFIRM 秒才算断电；抖一下不改结论。
# 状态一行：RAW SINCE POWER
power_update() {
  now=$(date '+%s')

  raw=0
  raw_power && raw=1
  # 开关通道（input_suspend）自己停充会把 online 归零，但线还插着；
  # 限流通道不碰输入，online 一直准，所以只对开关通道做这条兜底。
  # 区分方法：插着不充是 Not charging / Full，真拔线才是 Discharging。
  if [ "$raw" = 0 ] && chg_port_held; then
    case "$(cat "$BATT/status" 2>/dev/null)" in
      Charging|Full|Not\ charging) raw=1 ;;
    esac
  fi
  if [ "$raw" = 0 ] && ! chg_held && raw_charging; then raw=1; fi

  POWER_DROPPED=0
  set -- $($BB cat "$DATA/power.state" 2>/dev/null)
  p_raw=$1
  p_since=$2
  p_pow=$3

  if [ -z "$p_pow" ]; then
    # 首次运行：直接采用当前值，避免开机瞬间凭空判成“刚断电”
    POWER=$raw
    printf '%s %s %s\n' "$raw" "$now" "$raw" > "$DATA/power.state.$$" 2>/dev/null
  else
    case "$p_since" in ''|*[!0-9]*) p_since=$now ;; esac
    if [ "$raw" = "$p_raw" ]; then since=$p_since; else since=$now; fi
    POWER=$p_pow
    if [ "$raw" = 1 ]; then
      [ $((now - since)) -ge "${ON_CONFIRM:-5}" ] && POWER=1
    else
      [ $((now - since)) -ge "${OFF_CONFIRM:-120}" ] && POWER=0
    fi
    printf '%s %s %s\n' "$raw" "$since" "$POWER" > "$DATA/power.state.$$" 2>/dev/null
  fi
  mv -f "$DATA/power.state.$$" "$DATA/power.state" 2>/dev/null

  [ "$raw" != "$p_raw" ] && log "供电信号: raw=$raw 源=$(power_source)"

  POWER_RAW=$raw
  [ "$p_pow" = "1" ] && [ "$POWER" = "0" ] && POWER_DROPPED=1
  return 0
}

# 只读，不推进状态机。给网页状态查询用，避免和守护进程抢着写。
power_read() {
  set -- $($BB cat "$DATA/power.state" 2>/dev/null)
  if [ -n "$3" ]; then
    POWER_RAW=$1
    POWER=$3
  else
    raw_power && POWER_RAW=1 || POWER_RAW=0
    if [ "$POWER_RAW" = 0 ] && chg_port_held; then
      case "$(cat "$BATT/status" 2>/dev/null)" in
        Charging|Full|Not\ charging) POWER_RAW=1 ;;
      esac
    fi
    if [ "$POWER_RAW" = 0 ] && ! chg_held && raw_charging; then POWER_RAW=1; fi
    POWER=$POWER_RAW
  fi
  return 0
}

# 一轮采集，结果放在全局变量里
facts_collect() {
  power_update
  AP_REAL=$(ap_running)
  CLIENTS=0
  [ "$AP_REAL" = 1 ] && CLIENTS=$(ap_clients)
  chg_held && CHG_HELD=1 || CHG_HELD=0
  return 0
}
