### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers
## Configured for Xiaomi POCO F5 (marble) - GKI 2.0 (Image-only flash)

properties() { '
kernel.string=MarblePerf Kernel (Evolution X A17 / 5.10 GKI)
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=marble
device.name2=marblein
supported.versions=14-17
supported.patchlevels=
supported.vendorpatchlevels=
'; }

### AnyKernel setup
# import properties
. tools/ak3-core.sh;

# boot install (GKI 2.0: replace kernel Image only, keep ROM ramdisk & DTB intact)
block=boot;
is_slot_device=1;
ramdisk_compression=auto;
patch_vbmeta_flag=auto;

# reset for boot patching
reset_ak;

split_boot;
flash_boot;
## end boot install
