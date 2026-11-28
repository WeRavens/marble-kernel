#!/system/bin/sh
# MarblePerf Runtime Tuner v1.3 boot service (KernelSU-Next / Magisk)

MODDIR="${0%/*}"

while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 2
done
sleep 10

sh "$MODDIR/apply.sh" apply
