#!/system/bin/sh
# 充电执行器：只接收电量、温度与用户配置，输出“充/停”，并负责写节点与还原。
# 不判断车辆是否在用，也不改动热点决策依据。
# 依赖 nb-core.sh。

chg_active() { [ -f "$DATA/chg.on" ] && echo 1 || echo 0; }

# 限流通道：只把充电电流压到 0，不动充电输入。
# 走 input_suspend 会让充电器重新协商 PD（batterysecret 要重新鉴权），
# 车机那头表现为 USB 反复断开重连（“咚咚”）；限流不碰输入，PD 合同一直有效。
CHG_CUR=${CHG_CUR:-/sys/class/power_supply/battery/constant_charge_current}
CHG_CUR_ON=${CHG_CUR_ON:-3000000}

# 当前通道（带缓存），供电判定也要用它
chg_channel() { chg_detect >/dev/null 2>&1; echo "$CHG_CH"; }

# 首次安装默认开启；用户手动停止后 chg.off 跨重启保留
chg_init() {
  [ -f "$DATA/chg.on" ] || [ -f "$DATA/chg.off" ] || touch "$DATA/chg.on" 2>/dev/null
}

# root 下 [ -w ] 恒真，只能看权限位；取不到时退化成“写回原值”探测
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

# 探测结果缓存。网页每 5 秒拉一次状态，探测会读写 sysfs，不能每次都探。
# 读不到缓存时立即可用；想强制重探就删掉这个文件。
chg_cache_load() {
  [ -f "$DATA/chg.node" ] || return 1
  . "$DATA/chg.node" 2>/dev/null
  # 旧缓存可能把能限流的机型记成了开关通道，主版本变了就重探一次
  [ "$CHG_CACHE_V" = "3" ] || return 1
  [ -n "$CHG_NODE" ] && [ -e "$CHG_NODE" ]
}

chg_cache_save() {
  {
    echo "CHG_CACHE_V=3"
    echo "CHG_CH=$CHG_CH"
    echo "CHG_NODE=$CHG_NODE"
    echo "CHG_ON=$CHG_ON"
    echo "CHG_OFF=$CHG_OFF"
  } > "$DATA/chg.node" 2>/dev/null
}

# 判通道：CHG_CH=switch|soc|none，CHG_NODE=实际节点；switch 时一并定好极性。
#
# 两条通道的写入语义完全不同，不能按“谁先可写”来挑：
#   骁龙 input_suspend 类：0/1 = 允许/暂停充电
#   天玑 keep_chg_soc ：写目标电量，充到即停（写 0/1 毫无意义）
# 所以先按平台定优先级，再验证节点存在/可写，最后才走通用探测列表。
chg_detect() {
  chg_cache_load && return 0

  # 强制指定时也要节点存在，否则写进空路径等于永远没生效
  case "$CHG_MODE" in
    switch)
      if [ -e "$CHG_SWITCH" ]; then
        CHG_CH=switch; CHG_NODE=$CHG_SWITCH; chg_cache_save; return 0
      fi
      ;;
    soc)
      if [ -e "$SOC_PATH" ]; then
        CHG_CH=soc; CHG_NODE=$SOC_PATH; chg_cache_save; return 0
      fi
      ;;
  esac

  plat=$(chg_platform)
  if [ "$plat" = mtk ]; then
    # 天玑/联发科：目标电量通道
    if chg_writable "$SOC_PATH"; then
      CHG_CH=soc; CHG_NODE=$SOC_PATH; chg_cache_save; return 0
    fi
  else
    # 高通：优先限流通道。它不碰充电输入，充电器不会重新协商 PD，
    # USB 也就不会跟着断开重连。个别机型写了 0 无效，会留 chg.fallback=2
    # 标记，之后直接用开关通道，不再反复试。
    if [ "$($BB cat "$DATA/chg.fallback" 2>/dev/null)" != "2" ] && chg_writable "$CHG_CUR"; then
      CHG_CH=current; CHG_NODE=$CHG_CUR; CHG_ON=0; CHG_OFF=0
      # 从旧的开关通道切过来时，input_suspend 可能还停在“暂停”。
      # 那不是现在的控制手段，必须放开，否则插上电也永远不充。
      if [ -e "$CHG_SWITCH" ] && [ "$(cat "$CHG_SWITCH" 2>/dev/null)" = "1" ]; then
        printf '0\n' > "$CHG_SWITCH" 2>/dev/null
        log "充电: 旧开关通道已放开（$CHG_SWITCH=0），改用限流控制"
      fi
      chg_cache_save; return 0
    fi
    # 兜底：开关通道，语义是 0=充 1=停
    if chg_writable "$CHG_SWITCH"; then
      CHG_CH=switch; CHG_NODE=$CHG_SWITCH; CHG_ON=0; CHG_OFF=1
      chg_cache_save; return 0
    fi
  fi

  for spec in \
    "/sys/class/qcom-battery/input_suspend:0:1" \
    "/sys/class/power_supply/battery/input_suspend:0:1" \
    "/sys/class/power_supply/charger/charging_enabled:1:0" \
    "/sys/class/power_supply/battery/charging_enabled:1:0" \
    "/sys/class/power_supply/battery/batt_slate_mode:0:1" \
    "$SOC_PATH:::"
  do
    # 变量名不能用 p：chg_writable 内部也用 p，会把路径冲掉
    np=${spec%%:*}; r=${spec#*:}; non=${r%%:*}; noff=${r#*:}
    chg_writable "$np" || continue
    if [ "$np" = "$SOC_PATH" ]; then
      CHG_CH=soc; CHG_NODE=$np
    else
      CHG_CH=switch; CHG_NODE=$np; CHG_ON=$non; CHG_OFF=$noff
    fi
    chg_cache_save
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

# 充电器在不在。不能只看 status：停充时它也可能还写着 Charging。
# 这里看 power_supply 下的 online 节点，VBUS 在位就算插着。
chg_plugged() {
  for n in usb wireless dc ac; do
    [ -e "$BATT/../$n/online" ] || continue
    [ "$(cat "$BATT/../$n/online" 2>/dev/null)" = "1" ] && { echo 1; return 0; }
  done
  echo 0
}

# 把所有已知节点写回“允许充电”。切通道、恢复、自愈都走这里：
# 任何一个残留（input_suspend=1 或 constant_charge_current=0）都会让机器
# 插着电也不充，而且 status 还一直显示 Charging，只看状态根本发现不了。
chg_restore_all() {
  if [ -e "$CHG_SWITCH" ] && [ "$(cat "$CHG_SWITCH" 2>/dev/null)" != "0" ]; then
    printf '0\n' > "$CHG_SWITCH" 2>/dev/null
    log "充电: 放开开关节点 $CHG_SWITCH=0"
  fi
  [ -e "$CHG_CUR" ] || return 0
  cur=$($BB cat "$CHG_CUR" 2>/dev/null)
  [ "$cur" = "0" ] || return 0
  o=$($BB cat "$DATA/ccc.orig" 2>/dev/null)
  case "$o" in ''|0) o=$CHG_CUR_ON ;; esac
  printf '%s\n' "$o" > "$CHG_CUR" 2>/dev/null
  log "充电: 限流节点停在 0，已写回 ${o}µA"
}

# chg_apply on|off|restore —— 唯一碰硬件的地方
chg_apply() {
  chg_detect || return 1

  # 允许充电时先把所有已知节点写回一遍，清掉别的通道可能残留的“暂停”。
  # 放在值比较之前，否则节点本来就是 0 时会提前返回，残留就永远清不掉。
  [ "$1" != "off" ] && chg_restore_all

  if [ "$CHG_CH" = current ]; then
    if [ "$1" = "off" ]; then
      # 停充前先记住原本的电流上限；各机型内核自己也会调，恢复时不能写死
      [ -f "$DATA/ccc.orig" ] || cat "$CHG_NODE" 2>/dev/null > "$DATA/ccc.orig"
      v=0
    else
      v=$($BB cat "$DATA/ccc.orig" 2>/dev/null)
      case "$v" in ''|0) v=$CHG_CUR_ON ;; esac
    fi
  elif [ "$CHG_CH" = soc ]; then
    [ -f "$DATA/soc.orig" ] || cat "$CHG_NODE" 2>/dev/null > "$DATA/soc.orig"
    case "$1" in
      off) v=$CHG_SOC_OFF ;;
      restore)
        v=$(cat "$DATA/soc.orig" 2>/dev/null)
        [ -z "$v" ] && v=$CHG_SOC_ON
        ;;
      *) v=$CHG_SOC_ON ;;
    esac
  else
    case "$1" in off) v=$CHG_OFF ;; *) v=$CHG_ON ;; esac
  fi

  [ "$(cat "$CHG_NODE" 2>/dev/null)" = "$v" ] && return 0
  printf '%s\n' "$v" > "$CHG_NODE" 2>/dev/null
  log "充电: 写入 $CHG_NODE=$v（$CHG_CH ${1}）"

  # 限流到底有没有生效，交给 chg_once 每轮判定（要连续多轮确认）。
  # v5.0.13 及之前在这里单次采样就下结论：停充时 current_now 在 0 上下抖
  # （实测出现 +476mA 的尖峰），一次超阈值就切 input_suspend —— 那是把充电输入
  # 直接掐断，usb_online 变 0、手机插着线反而放电，用户看到的就是充电忽停忽开。
  return 0
}

# 周期采样：控制器关不关都记，采样是想看清整条充放电曲线
sample_once() {
  cap=$(cat "$BATT/capacity" 2>/dev/null); [ -z "$cap" ] && return 0
  st=$(cat "$BATT/status" 2>/dev/null); [ -z "$st" ] && st="?"
  rawt=$(cat "$BATT/temp" 2>/dev/null); [ -z "$rawt" ] && rawt=0
  t=$($BB awk -v t="$rawt" 'BEGIN{printf "%.1f", t/10}')
  cur=$(cat "$BATT/current_now" 2>/dev/null); [ -z "$cur" ] && cur=0
  case "$st" in
    Charging)    [ "$cur" -lt 0 ] && cur=$((cur * -1)) ;;
    Discharging) [ "$cur" -gt 0 ] && cur=$((cur * -1)) ;;
  esac
  vol=$(cat "$BATT/voltage_now" 2>/dev/null); [ -z "$vol" ] && vol=3800000
  [ "$vol" = 0 ] && vol=3800000
  watt=$($BB awk -v v="$vol" -v c="$cur" 'BEGIN{printf "%.2f", v*c/1e12}')
  case "$st" in
    Charging) dir=充 ;;
    Discharging) dir=放 ;;
    Full) dir=满 ;;
    *) dir=闲 ;;
  esac
  ma=$($BB awk -v c="$cur" 'BEGIN{printf "%d", c/1000}')
  # 与 batt_json 同一套判定：控制器在停充时限流通道的 status 仍写 Charging，
  # 日志里再写「充 0.00W 0mA」会自相矛盾，标成「停」更贴近事实。
  if [ "$dir" = "充" ] && [ -f "$DATA/chg.on" ] && [ "$($BB cat "$DATA/chg.state" 2>/dev/null)" = "off" ]; then
    m=${ma#-}
    case "$m" in ''|*[!0-9]*) m=0 ;; esac
    [ "$m" -lt 800 ] && dir=停
  fi
  sample_now "$cap" "$dir" "$watt" "$ma" "$t"
}

chg_once() {
  sample_once

  if [ ! -f "$DATA/chg.on" ]; then
    chg_apply restore >/dev/null 2>&1
    return 0
  fi

  cap=$(cat "$BATT/capacity" 2>/dev/null); [ -z "$cap" ] && return 0
  rawt=$(cat "$BATT/temp" 2>/dev/null); [ -z "$rawt" ] && rawt=0
  t=$((rawt / 10))

  if [ "$cap" -le 15 ]; then
    want=on
  elif [ "$t" -ge "$MAX_TEMP" ]; then
    want=off
  elif [ "$cap" -ge "$PAUSE_CAP" ]; then
    want=off
  elif [ "$cap" -le "$RESUME_CAP" ]; then
    want=on
  else
    want=$(cat "$DATA/chg.state" 2>/dev/null)
    [ -z "$want" ] && want=on
  fi

  prev=$($BB cat "$DATA/chg.state" 2>/dev/null)
  now=$(date '+%s')
  last=$($BB cat "$DATA/chg.last" 2>/dev/null)
  # 只在状态变化时写节点，避免每 10 秒无意义地刷 sysfs；
  # 另外每 10 分钟兜底重写一次，防止系统在插拔/息屏后把节点改回去。
  if [ "$prev" != "$want" ] || [ -z "$last" ] || [ $((now - last)) -ge 600 ]; then
    chg_apply "$want"
    printf '%s\n' "$now" > "$DATA/chg.last" 2>/dev/null
  fi
  echo "$want" > "$DATA/chg.state" 2>/dev/null
  if [ "$prev" != "$want" ]; then
    log "充电控制: ${prev:-?} -> $want（${cap}% ${t}℃ 上限 $PAUSE_CAP 恢复 $RESUME_CAP）"
  fi

  # 限流通道兜底：系统温控可能把电流改回去，只有在真的又充起来时补写一次。
  # 这个写入不触碰充电输入，不会连带让 USB 断开，所以多写几次也无妨。
  #
  # 「限流到底有没有生效」也只在这里判，而且要连续多轮：
  #   ① current_now 必须是正向（负值是放电，绝对值再大也不是在充电）
  #   ② status 仍说 Charging、线还插着
  #   ③ 电流 > 800mA（停充时的抖动实测到 ±480mA，阈值低了会误判）
  # 只有连续 3 轮（约 30 秒）都满足才切开关通道 —— 切过去就是把充电输入掐断，
  # 误判的代价是插着电反而掉电，宁可多等几轮。
  if [ "$want" = "off" ] && [ "$(chg_channel)" = "current" ]; then
    raw=$($BB cat "$BATT/current_now" 2>/dev/null)
    c=${raw#-}
    case "$c" in ''|*[!0-9]*) c=0 ;; esac
    st=$($BB cat "$BATT/status" 2>/dev/null)
    case "$raw" in -*) neg=1 ;; *) neg=0 ;; esac

    # ① 节点被改回去了就直接补写：重启、USB 重新协商、温控都会把
    #    constant_charge_current 恢复成默认值（实测重启后变 5850000），
    #    这时状态机因为「状态没变」不会动手，光靠 10 分钟兜底太迟钝。
    node_v=$($BB cat "$CHG_NODE" 2>/dev/null)
    [ "$node_v" != "0" ] && chg_apply off >/dev/null 2>&1

    # ② 「限流到底有没有生效」要连续多轮才下结论
    #    （① 正向电流 ② status 说在充 ③ 线还插着 ④ 超过 800mA）
    if [ "$neg" = "0" ] && [ "$c" -gt 800000 ] && [ "$st" = "Charging" ] && [ "$(chg_plugged)" = "1" ]; then
      n=$($BB cat "$DATA/chg.ineff.n" 2>/dev/null)
      case "$n" in ''|*[!0-9]*) n=0 ;; esac
      n=$((n + 1))
      printf '%s\n' "$n" > "$DATA/chg.ineff.n" 2>/dev/null
      if [ "$n" -ge 3 ]; then
        log "充电: 限流连续 3 轮无效（仍 ${c}µA 在充），改用开关通道"
        chg_restore_all
        printf '2\n' > "$DATA/chg.fallback" 2>/dev/null
        rm -f "$DATA/chg.node" "$DATA/chg.ineff.n" 2>/dev/null
        chg_detect >/dev/null 2>&1
        [ "$CHG_CH" = "switch" ] && chg_apply off
      fi
    else
      rm -f "$DATA/chg.ineff.n" 2>/dev/null
    fi
  fi

  # 自愈：控制器允许充电、线插着、status 说在充，电流却一直是 0，
  # 说明有别的通道残留（典型是 constant_charge_current 停在 0）。
  # 持续 60 秒就把所有节点写回并记一行 fault，不靠人去发现。
  if [ "$want" = "on" ] && [ "$(chg_plugged)" = "1" ] && [ "$(cat "$BATT/status" 2>/dev/null)" = "Charging" ]; then
    c=$($BB cat "$BATT/current_now" 2>/dev/null); c=${c#-}
    case "$c" in ''|*[!0-9]*) c=0 ;; esac
    if [ "$c" -lt 50000 ]; then
      t0=$($BB cat "$DATA/chg.zero.ts" 2>/dev/null)
      if [ -z "$t0" ]; then
        printf '%s\n' "$now" > "$DATA/chg.zero.ts" 2>/dev/null
      elif [ $((now - t0)) -ge 60 ]; then
        chg_restore_all
        rm -f "$DATA/chg.zero.ts" 2>/dev/null
        log "充电: 故障自愈（允许充电却 0mA 超过 60 秒），已写回所有节点"
      fi
    else
      rm -f "$DATA/chg.zero.ts" 2>/dev/null
    fi
  else
    rm -f "$DATA/chg.zero.ts" 2>/dev/null
  fi
  return 0
}

chg_ctl() {
  case "$1" in
    start)
      rm -f "$DATA/chg.off" 2>/dev/null
      touch "$DATA/chg.on" 2>/dev/null
      chg_once
      log "充电控制: 启动"
      ;;
    stop)
      rm -f "$DATA/chg.on" "$DATA/chg.last" 2>/dev/null
      touch "$DATA/chg.off" 2>/dev/null
      chg_apply restore
      echo on > "$DATA/chg.state" 2>/dev/null
      log "充电控制: 停止并还原硬件"
      ;;
    *) return 1 ;;
  esac
  return 0
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

batt_json() {
  cap=$(cat "$BATT/capacity" 2>/dev/null); [ -z "$cap" ] && cap=0
  st=$(cat "$BATT/status" 2>/dev/null); [ -z "$st" ] && st="unknown"
  rawt=$(cat "$BATT/temp" 2>/dev/null); [ -z "$rawt" ] && rawt=0
  temp=$($BB awk -v t="$rawt" 'BEGIN{printf "%.1f", t/10}')
  cur=$(cat "$BATT/current_now" 2>/dev/null); [ -z "$cur" ] && cur=0
  # 符号各平台不一致（vivo/MTK 充电时给负值），统一成 正=充入 负=放出
  case "$st" in
    Charging)    [ "$cur" -lt 0 ] && cur=$((cur * -1)) ;;
    Discharging) [ "$cur" -gt 0 ] && cur=$((cur * -1)) ;;
  esac
  ma=$($BB awk -v c="$cur" 'BEGIN{printf "%d", c/1000}')
  vol=$(cat "$BATT/voltage_now" 2>/dev/null); [ -z "$vol" ] && vol=3800000
  [ "$vol" = 0 ] && vol=3800000
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
  chg_detect >/dev/null 2>&1
  # 限流通道停充时 status 仍报 Charging（内核不承认自己停了），
  # 按“控制器在停充 + 线还插着”标成 stop，页面才好说人话。
  # 阈值不能卡太紧：停充后 current_now 在 0 上下抖（实测 -136~+249mA），
  # 用 100mA 会让状态每个采样都翻一次，页面上就是「充电中/已停充」来回跳。
  if [ "$dir" = "chg" ] && [ -f "$DATA/chg.on" ] && [ "$($BB cat "$DATA/chg.state" 2>/dev/null)" = "off" ]; then
    m=${ma#-}
    case "$m" in ''|*[!0-9]*) m=0 ;; esac
    [ "$m" -lt 800 ] && [ "$(chg_plugged)" = "1" ] && dir=stop
  fi
  sw="?"; [ -n "$CHG_NODE" ] && sw=$(cat "$CHG_NODE" 2>/dev/null)
  printf '{"cap":%s,"status":"%s","temp":%s,"ma":%s,"w":%s,"dir":"%s","pc":%s,"rc":%s,"enabled":%s,"sw":"%s","state":"%s","ch":"%s","node":"%s","plat":"%s","mt":%s}' \
    "$cap" "$st" "$temp" "$ma" "$watt" "$dir" "$PAUSE_CAP" "$RESUME_CAP" "$(chg_active)" "$sw" \
    "$(cat "$DATA/chg.state" 2>/dev/null || echo on)" "$CHG_CH" "$CHG_NODE" "$(chg_platform)" "$MAX_TEMP"
}
