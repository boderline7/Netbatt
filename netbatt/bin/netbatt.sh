#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/nb-lib.sh"

case "$1" in
  init)   log_boot; chg_init; stop_dnsmasq; fwd_cleanup ;;
  apply)  apply ;;
  chg)    chg_once ;;
  keep)   keepalive ;;
  web)    start_web ;;
  stop)   stop_web; stop_dnsmasq ;;
  status) status_json ;;
  recover) stop_dnsmasq ;;
  *) echo "usage: netbatt.sh init|apply|chg|keep|web|stop|status|recover" ;;
esac
