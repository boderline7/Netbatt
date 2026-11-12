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

# 充电器物理存在 / 在线。present 只看插着没有，不受停充影响。
raw_power() {
  for n in usb ac dc wireless; do
    p=/sys/class/power_supply/$n
    [ -f "$p/present" ] && [ "$(cat "$p/present" 2>/dev/null)" = "1" ] && return 0
    [ -f "$p/online" ]  && [ "$(cat "$p/online" 2>/dev/null)" = "1" ] && return 0
  done
  return 1
}

# 电池正在进电。停充后这个信号会消失，所以只作兜底，且要避开 CHG_HELD。
raw_charging() {
  st=$(cat "$BATT/status" 2>/dev/null)
  case "$st" in
    Charging|Full) return 0 ;;
  esac
  c=$(cat "$BATT/current_now" 2>/dev/null)
  case "$c" in ''|*[!0-9-]*) return 1 ;; esac
  [ "$c" -gt 0 ]
}

# 软件主动停充中。只用来排除“自己停充导致的假断电”，不参与任何热点决策。
chg_held() {
  [ -f "$DATA/chg.on" ] || return 1
  [ "$(cat "$DATA/chg.state" 2>/dev/null)" = "off" ]
}

# 供电确认（回滞）：原始信号持续 ON_CONFIRM 秒才算有电，
# 持续 OFF_CONFIRM 秒才算断电；抖一下不改结论。
# 状态一行：RAW SINCE POWER
power_update() {
  now=$(date '+%s')

  raw=0
  raw_power && raw=1
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
