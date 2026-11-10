#!/system/bin/sh
M=/data/adb/modules/netbatt/bin/netbatt.sh
while true; do
  sh $M apply
  sh $M chg
  sh $M keep
  sh $M web
  sleep 5
done
