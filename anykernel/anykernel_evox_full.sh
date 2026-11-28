### AnyKernel3 Full-Package Mod Script
## Configured for Xiaomi POCO F5 (marble) - Pure Evolution X Full-Package
## Updates: boot (Image) + vendor_boot (first/second-stage .ko) + vendor_dlkm (.ko)

properties() { '
kernel.string=MarbleEvoX Full-Package (Evolution X A17 / 5.10.269)
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=marble
device.name2=marblein
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; }

### 1. Flash boot (Image only, keep ROM ramdisk intact)
BLOCK=boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

. tools/ak3-core.sh;

ui_print " ";
ui_print "- Updating boot Image...";
split_boot;
flash_boot;

### 2. Update vendor_boot ramdisk modules (keep DTB & bootconfig intact)
if [ -d "$AKHOME/_modules" ] && [ "$(ls -A "$AKHOME/_modules" 2>/dev/null)" ]; then
  ui_print " ";
  ui_print "- Updating vendor_boot kernel modules...";
  rm -f "$AKHOME/Image";

  BLOCK=vendor_boot;
  IS_SLOT_DEVICE=1;
  RAMDISK_COMPRESSION=auto;
  PATCH_VBMETA_FLAG=auto;
  NO_MAGISK_CHECK=1;

  reset_ak;
  dump_boot;

  updated_vb=0;
  missed_vb=0;
  for moddir in "$RAMDISK/lib/modules" "$VENDORRD"/*/lib/modules; do
    if [ -d "$moddir" ]; then
      for existing in "$moddir"/*.ko; do
        [ -f "$existing" ] || continue
        base="$(basename "$existing")";
        if [ -f "$AKHOME/_modules/$base" ]; then
          cp -f "$AKHOME/_modules/$base" "$existing" || abort "Failed copying $base into vendor_boot!";
          chmod 0644 "$existing";
          updated_vb=$((updated_vb + 1));
        else
          missed_vb=$((missed_vb + 1));
        fi;
      done;
    fi;
  done;

  ui_print "  Updated $updated_vb module(s) in vendor_boot (unmatched: $missed_vb).";
  if [ "$updated_vb" -eq 0 ]; then
    abort "Zero modules updated in vendor_boot! Aborting...";
  fi;
  repack_ramdisk;
  # Fix upstream ak3-core.sh bug on vendor_boot v4:
  # magiskboot compress=<comp> produces <name>-new.cpio.<comp>, while flash_boot copies <name>-new.cpio.
  for cpio_comp in "$AKHOME"/*-new.cpio.*; do
    [ -f "$cpio_comp" ] || continue
    cpio_base="${cpio_comp%.*}";
    if [ ! -f "$cpio_base" ]; then
      mv -f "$cpio_comp" "$cpio_base";
    fi;
  done;
  flash_boot;
fi;

### 3. Update vendor_dlkm modules (ext4 partition inside super)
if [ -d "$AKHOME/_modules" ] && [ "$(ls -A "$AKHOME/_modules" 2>/dev/null)" ]; then
  ui_print " ";
  ui_print "- Updating vendor_dlkm kernel modules...";
  vdlkm_blk="/dev/block/mapper/vendor_dlkm$SLOT";
  if [ ! -e "$vdlkm_blk" ]; then
    vdlkm_blk="/dev/block/by-name/vendor_dlkm$SLOT";
  fi;

  if [ -e "$vdlkm_blk" ]; then
    blockdev --setrw "$vdlkm_blk" 2>/dev/null || true;
    vdlkm_mnt="$AKHOME/vdlkm_mnt";
    mkdir -p "$vdlkm_mnt";
    umount "$vdlkm_mnt" 2>/dev/null || true;
    umount /vendor_dlkm 2>/dev/null || true;

    if mount -t ext4 -o rw "$vdlkm_blk" "$vdlkm_mnt" 2>/dev/null || mount -o rw "$vdlkm_blk" "$vdlkm_mnt" 2>/dev/null; then
      mount -o remount,rw "$vdlkm_mnt" 2>/dev/null || true;

      # Free ~20 MB immediately by removing unused qca6750 Wi-Fi driver (marble uses qca6490)
      if [ -f "$vdlkm_mnt/lib/modules/qca_cld3_qca6750.ko" ] && [ ! -f "$AKHOME/_modules/qca_cld3_qca6750.ko" ]; then
        rm -f "$vdlkm_mnt/lib/modules/qca_cld3_qca6750.ko" 2>/dev/null || true;
      fi;

      # Build authoritative module list from modules.dep (plus any existing .ko),
      # so re-flashing self-heals even after a previously interrupted install.
      matched_list="$AKHOME/vdlkm_matched.txt";
      all_list="$AKHOME/vdlkm_all.txt";
      rm -f "$matched_list" "$all_list";
      touch "$matched_list" "$all_list";
      if [ -f "$vdlkm_mnt/lib/modules/modules.dep" ]; then
        sed -n 's|^\([^:]*\.ko\):.*|\1|p' "$vdlkm_mnt/lib/modules/modules.dep" | while IFS= read -r p; do
          basename "$p" >> "$all_list";
        done;
      fi;
      for existing in "$vdlkm_mnt/lib/modules"/*.ko; do
        [ -f "$existing" ] || continue
        basename "$existing" >> "$all_list";
      done;

      missed_vd=0;
      sort -u "$all_list" | while IFS= read -r base; do
        [ -n "$base" ] || continue
        if [ -f "$AKHOME/_modules/$base" ]; then
          echo "$base" >> "$matched_list";
        fi;
      done;
      rm -f "$all_list";

      # Free space FIRST: stock vendor_dlkm.img only has ~0.27 MB free,
      # so overwriting in-place fails with ENOSPC on the very first .ko!
      while IFS= read -r base; do
        [ -n "$base" ] || continue
        if [ -f "$vdlkm_mnt/lib/modules/$base" ]; then
          rm_err="$(rm -f "$vdlkm_mnt/lib/modules/$base" 2>&1)" || {
            ui_print "! rm error: $rm_err";
            umount "$vdlkm_mnt" 2>/dev/null || true;
            abort "Failed removing old $base from vendor_dlkm (read-only?)!";
          };
        fi;
      done < "$matched_list";

      updated_vd=0;
      while IFS= read -r base; do
        [ -n "$base" ] || continue
        cp_err="$(cp -f "$AKHOME/_modules/$base" "$vdlkm_mnt/lib/modules/$base" 2>&1)" || {
          ui_print "! cp error: $cp_err";
          ui_print "! df: $(df -h "$vdlkm_mnt" 2>/dev/null | tail -n1)";
          umount "$vdlkm_mnt" 2>/dev/null || true;
          abort "Failed copying $base into vendor_dlkm!";
        };
        chmod 0644 "$vdlkm_mnt/lib/modules/$base";
        chcon u:object_r:vendor_file:s0 "$vdlkm_mnt/lib/modules/$base" 2>/dev/null || true;
        updated_vd=$((updated_vd + 1));
      done < "$matched_list";
      rm -f "$matched_list";
      sync;
      umount "$vdlkm_mnt";
      rmdir "$vdlkm_mnt" 2>/dev/null || true;
      ui_print "  Updated $updated_vd module(s) in vendor_dlkm.";
      if [ "$updated_vd" -eq 0 ]; then
        abort "Zero modules updated in vendor_dlkm! Aborting...";
      fi;
    else
      ui_print "! Warning: Could not mount $vdlkm_blk rw (may be read-only or dm-verity).";
      abort "Failed to mount vendor_dlkm for module update. Aborting...";
    fi;
  else
    abort "Unable to locate vendor_dlkm$SLOT partition. Aborting...";
  fi;
fi;

### 4. Optional interactive install of MarblePerf-Tuner-KSU v1.3 + WebUI (Volume-key prompt)
if [ -f "$AKHOME/_ksu_tuner/module.prop" ] && [ -f "$AKHOME/_ksu_tuner/service.sh" ]; then
  ui_print " ";
  if [ -d "/data/adb" ]; then
    ui_print "================================================";
    ui_print "  Install MarblePerf-Tuner v1.3 + WebUI?";
    ui_print "  (Profil + BBR + MGLRU + SSG + GPU + Standby)";
    ui_print "  [Vol+] = YA (Install ke KernelSU-Next)";
    ui_print "  [Vol-] = TIDAK (Lewati)";
    ui_print "  (Otomatis lewati dalam 10 detik)";
    ui_print "================================================";

    ans_file="$AKHOME/.vol_ans";
    rm -f "$ans_file";
    (
      timeout 10 getevent -lq 2>/dev/null | while IFS= read -r line; do
        case "$line" in
          *KEY_VOLUMEUP*DOWN*)
            echo "yes" > "$ans_file";
            killall getevent 2>/dev/null || true;
            break;
            ;;
          *KEY_VOLUMEDOWN*DOWN*)
            echo "no" > "$ans_file";
            killall getevent 2>/dev/null || true;
            break;
            ;;
        esac;
      done;
    );

    if [ -f "$ans_file" ] && [ "$(cat "$ans_file")" = "yes" ]; then
      mod_dst="/data/adb/modules/marbleperf_tuner";
      mkdir -p "$mod_dst/webroot";
      rm -f "$mod_dst/disable" "$mod_dst/remove";
      cp -f "$AKHOME/_ksu_tuner/module.prop" "$mod_dst/module.prop";
      cp -f "$AKHOME/_ksu_tuner/service.sh" "$mod_dst/service.sh";
      cp -f "$AKHOME/_ksu_tuner/apply.sh" "$mod_dst/apply.sh";
      cp -f "$AKHOME/_ksu_tuner/webroot/index.html" "$mod_dst/webroot/index.html";
      chmod 0755 "$mod_dst" "$mod_dst/webroot" "$mod_dst/service.sh" "$mod_dst/apply.sh";
      chmod 0644 "$mod_dst/module.prop" "$mod_dst/webroot/index.html";
      chcon -R u:object_r:adb_data_file:s0 "$mod_dst" 2>/dev/null || true;
      ui_print "  [OK] MarblePerf-Tuner v1.3 + WebUI terpasang!";
    else
      ui_print "  [-] Instalasi MarblePerf-Tuner dilewati.";
    fi;
    rm -f "$ans_file";
  else
    ui_print "- Melewati MarblePerf-Tuner (/data/adb belum ter-decrypt/tersedia).";
  fi;
fi;

ui_print " ";
ui_print "- MarbleEvoX Full-Package install complete!";
