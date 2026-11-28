#!/system/bin/sh
# MarblePerf Runtime Tuner v1.3 - Core Engine (POCO F5 / marble)
# Usage:
#   sh apply.sh apply   -> apply saved profile & toggles
#   sh apply.sh status  -> print live system status & current config

CONF="/data/adb/marbleperf_tuner.conf"
LOG="/data/local/tmp/marbleperf_tuner.log"

load_conf() {
  PROFILE="balanced"
  OPT_NET="1"
  OPT_MGLRU="1"
  OPT_UFS_SSG="1"
  OPT_GPU="1"
  OPT_IDLE_SAVING="1"
  OPT_PRIVACY="1"
  if [ -f "$CONF" ]; then
    . "$CONF" 2>/dev/null || true
  else
    save_conf
  fi
}

save_conf() {
  cat > "$CONF" <<EOF
PROFILE="$PROFILE"
OPT_NET="$OPT_NET"
OPT_MGLRU="$OPT_MGLRU"
OPT_UFS_SSG="$OPT_UFS_SSG"
OPT_GPU="$OPT_GPU"
OPT_IDLE_SAVING="$OPT_IDLE_SAVING"
OPT_PRIVACY="$OPT_PRIVACY"
EOF
  chmod 0644 "$CONF" 2>/dev/null || true
}

write_val() {
  local path="$1"
  local val="$2"
  if [ -w "$path" ]; then
    echo "$val" > "$path" 2>/dev/null && echo "[OK] $path = $val" >> "$LOG"
  fi
}

do_apply() {
  load_conf
  : > "$LOG"
  echo "=== MarblePerf Tuner v1.3 ($(date)) ===" >> "$LOG"
  echo "Kernel: $(uname -r) | Profile: $PROFILE" >> "$LOG"

  # Profile-specific parameters
  case "$PROFILE" in
    battery)
      SWAPPINESS=80; VFS_CACHE=100; INPUT_BOOST=40
      UPMIG="90 98"; DOWNMIG="80 90"
      GPU_POLL=20; GPU_IDLE=50; GPU_NONAP=0; GPU_BUS_SPLIT=1; GPU_THROT=1
      WQ_PE="Y"
      ;;
    gaming)
      SWAPPINESS=40; VFS_CACHE=30; INPUT_BOOST=120
      UPMIG="75 85"; DOWNMIG="65 75"
      GPU_POLL=10; GPU_IDLE=120; GPU_NONAP=1; GPU_BUS_SPLIT=0; GPU_THROT=0
      WQ_PE="N"
      ;;
    *)
      PROFILE="balanced"
      SWAPPINESS=60; VFS_CACHE=50; INPUT_BOOST=80
      UPMIG="85 95"; DOWNMIG="75 85"
      GPU_POLL=10; GPU_IDLE=80; GPU_NONAP=1; GPU_BUS_SPLIT=0; GPU_THROT=0
      WQ_PE="Y"
      ;;
  esac

  # 1. Network: TCP BBR + FQ + Anti-Lag & Stability
  if [ "$OPT_NET" = "1" ]; then
    write_val /proc/sys/net/core/default_qdisc fq
    write_val /proc/sys/net/ipv4/tcp_congestion_control bbr
    write_val /proc/sys/net/ipv4/tcp_fastopen 3
    write_val /proc/sys/net/ipv4/tcp_ecn 1
    write_val /proc/sys/net/ipv4/tcp_notsent_lowat 16384
    write_val /proc/sys/net/ipv4/tcp_slow_start_after_idle 0
    write_val /proc/sys/net/ipv4/tcp_mtu_probing 1
    write_val /proc/sys/net/ipv4/tcp_tw_reuse 1
  else
    write_val /proc/sys/net/ipv4/tcp_slow_start_after_idle 1
  fi

  # 2. Memory, VM & MGLRU + ZRAM page-cluster=0
  write_val /proc/sys/vm/vfs_cache_pressure "$VFS_CACHE"
  write_val /proc/sys/vm/swappiness "$SWAPPINESS"
  write_val /proc/sys/vm/dirty_ratio 15
  write_val /proc/sys/vm/dirty_background_ratio 5
  write_val /proc/sys/vm/stat_interval 10
  if [ "$OPT_MGLRU" = "1" ]; then
    write_val /sys/kernel/mm/lru_gen/enabled y
    write_val /sys/kernel/mm/lru_gen/min_ttl_ms 1000
    write_val /proc/sys/vm/page-cluster 0
  else
    write_val /sys/kernel/mm/lru_gen/min_ttl_ms 0
    write_val /proc/sys/vm/page-cluster 3
  fi

  # 3. UFS 3.1 Storage + SSG I/O Scheduler & Longevity
  if [ "$OPT_UFS_SSG" = "1" ]; then
    write_val /proc/sys/vm/dirty_writeback_centisecs 500
    write_val /proc/sys/vm/dirty_expire_centisecs 3000
    for q in /sys/block/sd*/queue /sys/block/dm-*/queue; do
      [ -d "$q" ] || continue
      if [ -r "$q/scheduler" ] && grep -qw "ssg" "$q/scheduler" 2>/dev/null; then
        write_val "$q/scheduler" ssg
      fi
      write_val "$q/iostats" 0
      write_val "$q/add_random" 0
      write_val "$q/read_ahead_kb" 128
      write_val "$q/nr_requests" 128
    done
  fi

  # 4. WALT Scheduler responsiveness
  write_val /proc/sys/kernel/sched_autogroup_enabled 0
  write_val /proc/sys/walt/input_boost/input_boost_ms "$INPUT_BOOST"
  write_val /proc/sys/kernel/sched_upmigrate "$UPMIG"
  write_val /proc/sys/kernel/sched_downmigrate "$DOWNMIG"

  # 5. Adreno 725 GPU tuning
  if [ "$OPT_GPU" = "1" ]; then
    write_val /sys/class/kgsl/kgsl-3d0/bus_split "$GPU_BUS_SPLIT"
    write_val /sys/class/kgsl/kgsl-3d0/throttling "$GPU_THROT"
    write_val /sys/class/kgsl/kgsl-3d0/force_no_nap "$GPU_NONAP"
    write_val /sys/class/kgsl/kgsl-3d0/idle_timer "$GPU_IDLE"
    write_val /sys/class/kgsl/kgsl-3d0/devfreq/polling_interval "$GPU_POLL"
  else
    write_val /sys/class/kgsl/kgsl-3d0/bus_split 1
    write_val /sys/class/kgsl/kgsl-3d0/throttling 1
    write_val /sys/class/kgsl/kgsl-3d0/force_no_nap 0
  fi

  # 6. Standby power saving & reduce debug overhead
  if [ "$OPT_IDLE_SAVING" = "1" ]; then
    write_val /sys/module/workqueue/parameters/power_efficient "$WQ_PE"
    write_val /sys/kernel/tracing/tracing_on 0
    write_val /proc/sys/kernel/sched_schedstats 0
    write_val /proc/sys/kernel/printk_devkmsg off
  else
    write_val /sys/module/workqueue/parameters/power_efficient N
  fi

  # 7. Privacy & Stealth
  if [ "$OPT_PRIVACY" = "1" ]; then
    write_val /proc/sys/kernel/kptr_restrict 2
    write_val /proc/sys/kernel/dmesg_restrict 1
  else
    write_val /proc/sys/kernel/kptr_restrict 0
    write_val /proc/sys/kernel/dmesg_restrict 0
  fi

  echo "=== Done ===" >> "$LOG"
}

do_status() {
  load_conf
  kver="$(uname -r)"
  tcp="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo -)"
  sched="$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' /sys/block/sda/queue/scheduler 2>/dev/null || echo -)"
  mglru="$(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null || echo n/a)"
  gpu_hz="$(cat /sys/class/kgsl/kgsl-3d0/devfreq/cur_freq 2>/dev/null || echo 0)"
  gpu_mhz=$((gpu_hz / 1000000))
  batt_raw="$(cat /sys/class/power_supply/battery/temp 2>/dev/null || echo 0)"
  batt_c="$((batt_raw / 10)).$((batt_raw % 10))"
  wq_pe="$(cat /sys/module/workqueue/parameters/power_efficient 2>/dev/null || echo -)"

  echo "KERNEL=$kver"
  echo "TCP=$tcp"
  echo "SCHED=$sched"
  echo "MGLRU=$mglru"
  echo "GPU_MHZ=${gpu_mhz} MHz"
  echo "BATT_TEMP=${batt_c} C"
  echo "WQ_PE=$wq_pe"
  echo "PROFILE=$PROFILE"
  echo "OPT_NET=$OPT_NET"
  echo "OPT_MGLRU=$OPT_MGLRU"
  echo "OPT_UFS_SSG=$OPT_UFS_SSG"
  echo "OPT_GPU=$OPT_GPU"
  echo "OPT_IDLE_SAVING=$OPT_IDLE_SAVING"
  echo "OPT_PRIVACY=$OPT_PRIVACY"
}

case "${1:-apply}" in
  status) do_status ;;
  apply|*) do_apply ;;
esac
