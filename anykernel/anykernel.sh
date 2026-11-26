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
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; }

### AnyKernel setup
# boot shell variables (MUST be uppercase and set before sourcing ak3-core.sh)
BLOCK=boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching
. tools/ak3-core.sh;

# boot install (GKI 2.0: replace kernel Image only, keep ROM ramdisk & DTB intact)
split_boot;
flash_boot;
## end boot install
