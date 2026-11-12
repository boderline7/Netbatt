#!/system/bin/sh
# NetBatt 公共库：路径 / 配置 / 日志 / 工具
# 只放基础设施，不碰网络也不碰硬件；那些在 nb-facts / nb-decide / nb-hs / nb-chg / nb-adb / nb-web。

MODDIR=/data/adb/modules/netbatt
DATA=/data/adb/netbatt
BB=/data/adb/magisk/busybox
[ -x "$BB" ] || BB=/system/bin/busybox
CFG=$DATA/config.sh
PORT=8080
BATT=/sys/class/power_supply/battery
LOG="$DATA/netbatt.log"
LOG1="$DATA/netbatt.log.1"

mkdir -p "$DATA" 2>/dev/null

# ---------- 配置 ----------
# 默认值。config.sh 里的同名项会覆盖，缺项一律回落到这里，不会出现空值。
NB_DEFAULTS='
HS_MODE=auto
ON_CONFIRM=5
OFF_CONFIRM=120
IDLE_OFF_MIN=15
POLL_INT=10
PAUSE_CAP=88
RESUME_CAP=83
MAX_TEMP=45
CHG_MODE=auto
CHG_SWITCH=/sys/class/qcom-battery/input_suspend
CHG_ON=0
CHG_OFF=1
SOC_PATH=/sys/class/power_supply/battery/keep_chg_soc
CHG_SOC_OFF=5
CHG_SOC_ON=100
ADB_TCP=0
ADB_PORT=5555
LOG_MAX=3145728
LOG_ON=1
SAMPLE_INT=15
'

# v5 重写：热点改为「采集 / 决策 / 执行」三段，配置只留 HS_MODE。
# 旧的 AUTO_HS、HOTSPOT_MODE、PAUSE_UNTIL 不再存在，迁移时换算成 HS_MODE：
#   AUTO_HS=0            → off
#   HOTSPOT_MODE=always_on → on
#   其它                 → auto
# CFG_V5 标记保证只做一次。
nb_cfg_seed() {
  [ -f "$CFG" ] || : > "$CFG" 2>/dev/null
  $BB grep -q '^CFG_V5=' "$CFG" 2>/dev/null && return 0

  old_auto=$($BB sed -n 's/^AUTO_HS=//p' "$CFG" 2>/dev/null | $BB head -1)
  old_mode=$($BB sed -n 's/^HOTSPOT_MODE=//p' "$CFG" 2>/dev/null | $BB head -1)
  case "$old_mode" in
    always_on) newmode=on ;;
    auto)      newmode=auto ;;
    *)         newmode=auto ;;
  esac
  [ "$old_auto" = "0" ] && newmode=off

  keep=""
  for k in PAUSE_CAP RESUME_CAP MAX_TEMP CHG_MODE CHG_SWITCH CHG_ON CHG_OFF \
           SOC_PATH CHG_SOC_OFF CHG_SOC_ON ADB_TCP ADB_PORT LOG_MAX LOG_ON SAMPLE_INT; do
    v=$($BB sed -n "s/^$k=//p" "$CFG" 2>/dev/null | $BB head -1)
    [ -n "$v" ] && keep="$keep
$k=$v"
  done
  {
    # keep 放前面：awk 按 key 去重、保留先出现的，旧值优先、默认值补缺
    [ -n "$keep" ] && printf '%s\n' "$keep"
    printf '%s\n' "$NB_DEFAULTS" | $BB sed "s|^HS_MODE=.*|HS_MODE=$newmode|"
    echo "CFG_V5=1"
  } | $BB awk -F= 'NF && !seen[$1]++' > "$CFG.new" 2>/dev/null
  [ -s "$CFG.new" ] && mv -f "$CFG.new" "$CFG" 2>/dev/null
  rm -f "$CFG.new" 2>/dev/null

  # v4 的热点状态文件已作废，留着只会让排障时看错
  rm -f "$DATA/pw.hold" "$DATA/pw.on_since" "$DATA/pw.off_since" "$DATA/pw.try" 2>/dev/null
}

eval "$NB_DEFAULTS"
nb_cfg_seed
. "$CFG" 2>/dev/null

# 守护进程每轮重新读一次配置，网页改完立刻生效，不用重启
nb_cfg_reload() { . "$CFG" 2>/dev/null; }

# 写配置项：文件里没有该键时追加
cfg_set() {
  if $BB grep -q "^$1=" "$CFG" 2>/dev/null; then
    $BB sed -i "s|^$1=.*|$1=$2|" "$CFG" 2>/dev/null
  else
    echo "$1=$2" >> "$CFG" 2>/dev/null
  fi
}

# ---------- 运行日志 ----------
# 车机上没法 adb 也导不出 logcat，模块自己落一份到 /data/adb/netbatt。
# 单文件到 LOG_MAX（默认 3MB）滚成 netbatt.log.1，只留一份历史。
log_size() {
  [ -f "$1" ] || { echo 0; return 0; }
  n=$($BB stat -c %s "$1" 2>/dev/null)
  [ -z "$n" ] && n=$($BB wc -c < "$1" 2>/dev/null)
  echo "${n:-0}"
}

# 滚动必须在写之前做，否则无界增长。这里直接 printf，不走 log()，否则递归
log_rotate() {
  [ "${LOG_ON:-1}" = "1" ] || return 0
  [ "$(log_size "$LOG")" -ge "${LOG_MAX:-3145728}" ] || return 0
  mv -f "$LOG" "$LOG1" 2>/dev/null
  : > "$LOG" 2>/dev/null
  printf '%s [log] 超过 %s 字节，已滚动到 %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "${LOG_MAX:-3145728}" "${LOG1##*/}" >> "$LOG" 2>/dev/null
}

log() {
  [ "${LOG_ON:-1}" = "1" ] || return 0
  log_rotate
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
}

# 只在取值变化时记一行，避免每轮刷屏
log_chg() {
  k="$DATA/logv.$1"; v="$2"; shift 2
  [ "$($BB cat "$k" 2>/dev/null)" = "$v" ] && return 0
  printf '%s\n' "$v" > "$k" 2>/dev/null
  log "$*"
}

# 周期采样：按 SAMPLE_INT 降采样，五个值全同就跳过
sample_now() {
  now=$(date '+%s')
  last=$($BB cat "$DATA/sample.ts" 2>/dev/null)
  [ -n "$last" ] && [ $(( now - last )) -lt "${SAMPLE_INT:-15}" ] && return 0
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

log_dump() {
  [ -f "$LOG1" ] && $BB cat "$LOG1" 2>/dev/null
  $BB cat "$LOG" 2>/dev/null
}

log_clear() {
  : > "$LOG" 2>/dev/null
  rm -f "$LOG1" "$DATA"/logv.* "$DATA"/sample.ts "$DATA"/sample.k 2>/dev/null
  log "日志已清空"
}

# 同一天每点一次新开一份，已存在就续 -2、-3，不覆盖已有导出
log_export_name() {
  base="net-$(date '+%Y%m%d')"
  n=1
  name="$base.log"
  while [ -e "$1/$name" ]; do
    n=$((n + 1))
    name="$base-$n.log"
  done
  echo "$name"
}

# WebView 壳没实现 DownloadListener，附件会被静默吞掉，所以直接落盘到 /sdcard/Download
log_export() {
  dst=""
  for d in /sdcard/Download /sdcard/Documents /storage/emulated/0/Download /data/media/0/Download; do
    if [ -d "$d" ] || mkdir -p "$d" 2>/dev/null; then
      dst="$d/$(log_export_name "$d")"
      break
    fi
  done
  [ -z "$dst" ] && return 1
  log_dump > "$dst" 2>/dev/null && { echo "$dst"; return 0; }
  return 1
}

# 模块构建号，页面拿它判断自己是不是 WebView 缓存里的旧副本
nb_build() {
  v=$($BB sed -n 's/^versionCode=//p' "$MODDIR/module.prop" 2>/dev/null | $BB tr -d '\r\n ')
  echo "${v:-0}"
}

nb_ver() {
  v=$($BB sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | $BB tr -d '\r\n ')
  echo "${v:-?}"
}

# 开机记一次快照：排障时第一眼看的就是这几行
log_boot() {
  rel=$(getprop ro.build.version.release 2>/dev/null)
  log "===== 启动 $(nb_ver) · Android $rel ====="
  log "配置: 模式 $(hs_mode) 开确认 ${ON_CONFIRM}s / 关确认 ${OFF_CONFIRM}s / 空转 ${IDLE_OFF_MIN}min"
  a=$(ap_iface 2>/dev/null)
  power_read
  log "当前: 热点 $(ap_running 2>/dev/null) ${a:+($a)} · 供电 $POWER · 设备 $(ap_clients 2>/dev/null)"
}
