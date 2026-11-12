#!/system/bin/sh
# NetBatt 常驻调度：每 POLL_INT 秒跑一次 nb_tick（采集 -> 决策 -> 执行）
# 替代旧版的 loop.sh + netbatt.sh（旧版每 5 秒 fork 四个 sh，日志噪声大）

BINDIR=${0%/*}
# 注意：nb-core.sh 会把 MODDIR 改成模块根目录（它读 module.prop 用），
# 所以这里必须用独立的 BINDIR，source 完 core 之后再取同目录文件。
. "$BINDIR/nb-core.sh"
. "$BINDIR/nb-facts.sh"
. "$BINDIR/nb-decide.sh"
. "$BINDIR/nb-hs.sh"
. "$BINDIR/nb-chg.sh"
. "$BINDIR/nb-adb.sh"
. "$BINDIR/nb-web.sh"

# 单独子命令：开机恢复无线 ADB（要等 adbd 起来，不能挡住主循环）
if [ "$1" = "adb-restore" ]; then
  adb_tcp_restore
  exit 0
fi

# 单实例：旧进程还活着就先杀掉，避免两个状态机互相抢热点
pidf=$DATA/daemon.pid
if [ -f "$pidf" ]; then
  old=$($BB cat "$pidf" 2>/dev/null)
  [ -n "$old" ] && [ "$old" != "$$" ] && kill "$old" 2>/dev/null
fi
printf '%s\n' "$$" > "$pidf" 2>/dev/null

# 开机第一轮直接采信当前供电状态。
# service.sh 已经等了 8 秒，节点是稳的；如果沿用上次关机前留下的
# power.state，会出现“车没通电却先按有电跑 120 秒”的假象。
rm -f "$DATA/power.state" 2>/dev/null

log_boot
chg_init
start_web

while true; do
  nb_tick
  ensure_web
  iv=${POLL_INT:-10}
  case "$iv" in ''|*[!0-9]*) iv=10 ;; esac
  [ "$iv" -lt 5 ] && iv=5
  sleep "$iv"
done
