#!/system/bin/sh
# MarblePerf Runtime Tuner for POCO F5 (marble / SM7475)
# Runs safely after boot_completed via KernelSU-Next / Magisk

LOG="/data/local/tmp/marbleperf_tuner.log"

write_val() {
  local path="$1"
  local val="$2"
  if [ -w "$path" ]; then
    echo "$val" > "$path" 2>/dev/null && echo "[OK] $path = $val" >> "$LOG"
  fi
}

# Wait until Android finishes booting so vendor init doesn't overwrite our values
while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 2
done
sleep 10

: > "$LOG"
echo "=== MarblePerf Runtime Tuner started at $(date) ===" >> "$LOG"
echo "Kernel: $(uname -r)" >> "$LOG"

# 1. Network: TCP BBR + Fair Queueing + Low Latency
write_val /proc/sys/net/core/default_qdisc fq
write_val /proc/sys/net/ipv4/tcp_congestion_control bbr
write_val /proc/sys/net/ipv4/tcp_fastopen 3
write_val /proc/sys/net/ipv4/tcp_ecn 1
write_val /proc/sys/net/ipv4/tcp_notsent_lowat 16384

# 2. Memory, VM & MGLRU tuning (snappier app cache, thrashing protection)
write_val /proc/sys/vm/vfs_cache_pressure 50
write_val /proc/sys/vm/swappiness 60
write_val /proc/sys/vm/dirty_ratio 15
write_val /proc/sys/vm/dirty_background_ratio 5
write_val /proc/sys/vm/stat_interval 10
write_val /sys/kernel/mm/lru_gen/enabled y
write_val /sys/kernel/mm/lru_gen/min_ttl_ms 1000

# 3. UFS 3.1 Storage I/O optimization (prefer SSG scheduler when available)
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

# 4. WALT Scheduler responsiveness (balanced for snappy UI without thermal runaway)
write_val /proc/sys/kernel/sched_autogroup_enabled 0
write_val /proc/sys/walt/input_boost/input_boost_ms 80
write_val /proc/sys/kernel/sched_upmigrate "85 95"
write_val /proc/sys/kernel/sched_downmigrate "75 85"

# 5. Adreno 725 GPU tuning (verified nodes on marble / kgsl-3d0)
write_val /sys/class/kgsl/kgsl-3d0/bus_split 0
write_val /sys/class/kgsl/kgsl-3d0/throttling 0
write_val /sys/class/kgsl/kgsl-3d0/force_no_nap 1
write_val /sys/class/kgsl/kgsl-3d0/idle_timer 80
write_val /sys/class/kgsl/kgsl-3d0/devfreq/polling_interval 10

echo "=== MarblePerf Runtime Tuner finished ===" >> "$LOG"
