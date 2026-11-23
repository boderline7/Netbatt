#!/system/bin/sh
MODDIR=${0%/*}
# 特权应用与权限白名单的属主/权限，必须在 early mount 之后、zygote 之前就位
PRIV="$MODDIR/system/priv-app/NetBattConsole"
mkdir -p "$PRIV"
chown -R root:root "$MODDIR/system" 2>/dev/null
chmod 755 "$MODDIR/system" "$MODDIR/system/priv-app" "$PRIV" 2>/dev/null
chmod 644 "$PRIV"/*.apk 2>/dev/null
chmod 644 "$MODDIR/system/etc/permissions/"*.xml 2>/dev/null
# Magisk 解压不保留 zip 里的执行位，这些必须显式补，
# 否则 api.sh 不可执行 → /cgi-bin/* 全部 404（首页却正常）
chmod 755 "$MODDIR/bin"/*.sh 2>/dev/null
chmod 755 "$MODDIR/webroot/cgi-bin/api.sh" 2>/dev/null
chmod 644 "$MODDIR/webroot/index.html" 2>/dev/null
mkdir -p /data/adb/netbatt

# 网页提前起来：service.sh 必须等 boot_completed 之后再 sleep 8 秒才启动守护，
# 那段空窗（实测约开机后 30 秒）里打开控制台，WebView 连不上 127.0.0.1:8080，
# 而 APP 只在 onCreate 里 loadUrl 一次、失败不重试，于是一直白屏。
# httpd 只依赖 busybox 和模块目录，这里先拉起来，守护进程那边会跳过重复启动。
(
  . "$MODDIR/bin/nb-core.sh"
  . "$MODDIR/bin/nb-facts.sh"
  . "$MODDIR/bin/nb-web.sh"
  start_web
) >/dev/null 2>&1 &
