SKIPUNZIP=0

ui_print "========================================"
ui_print "  MarblePerf Runtime Tuner (POCO F5)    "
ui_print "  Evolution X A17 / Snapdragon 7+ Gen 2 "
ui_print "========================================"
ui_print "- Installing runtime engine & KernelSU WebUI..."
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/apply.sh" 0 0 0755
set_perm "$MODPATH/webroot/index.html" 0 0 0644
ui_print "- Done! Open WebUI in KernelSU-Next Manager -> Modules."
