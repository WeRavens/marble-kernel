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
      updated_vd=0;
      missed_vd=0;
      for existing in "$vdlkm_mnt/lib/modules"/*.ko; do
        [ -f "$existing" ] || continue
        base="$(basename "$existing")";
        if [ -f "$AKHOME/_modules/$base" ]; then
          cp -f "$AKHOME/_modules/$base" "$existing" || {
            umount "$vdlkm_mnt" 2>/dev/null || true;
            abort "Failed copying $base into vendor_dlkm (out of space?)!";
          };
          chmod 0644 "$existing";
          chcon u:object_r:vendor_file:s0 "$existing" 2>/dev/null || true;
          updated_vd=$((updated_vd + 1));
        else
          missed_vd=$((missed_vd + 1));
        fi;
      done;
      sync;
      umount "$vdlkm_mnt";
      rmdir "$vdlkm_mnt" 2>/dev/null || true;
      ui_print "  Updated $updated_vd module(s) in vendor_dlkm (unmatched: $missed_vd).";
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

ui_print " ";
ui_print "- MarbleEvoX Full-Package install complete!";
