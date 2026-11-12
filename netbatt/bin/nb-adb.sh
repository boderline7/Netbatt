#!/system/bin/sh
# NetBatt 无线 ADB
# 只设运行时属性 service.adb.tcp.port（重启即失效），"永久"由模块开机恢复。
# 绝不写 persist.adb.tcp.port —— 那条属性会让部分 ROM 的开发者选项直接进不去。

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
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  [ "$p" -ge 1024 ] && [ "$p" -le 65535 ] || return 1
  setprop service.adb.tcp.port "$p"
  # ctl.restart 比 stop/start 少一次状态竞争；个别 ROM 不认这个触发器，退回 stop/start
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

# 老模块把 5555 写进了 persist 分区，禁用模块也不会清掉；
# 属性文件和内存属性都要清，只删内存的话重启会从 /data/property 读回来。
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

# 开机恢复：等 adbd 真起来再改端口，太早设会被 init 覆盖。
# 只有用户上次是「开着」的状态才恢复（ADB_TCP=1 会跨重启保留在配置里）。
adb_tcp_restore() {
  [ "$ADB_TCP" = "1" ] || return 0
  wait_for 40 adbd_running
  # 起来之后再让几秒：adbd 刚 ready 时设端口，偶尔会被 init 的默认值盖回去
  $BB sleep 5 2>/dev/null || sleep 5
  if adb_tcp_on "$ADB_PORT" >/dev/null 2>&1; then
    log "无线 ADB: 开机恢复端口 $ADB_PORT 成功"
  else
    log "无线 ADB: 开机恢复端口 $ADB_PORT 失败（adbd=$(getprop init.svc.adbd)）"
  fi
}
