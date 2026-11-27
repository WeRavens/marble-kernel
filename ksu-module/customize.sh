SKIPUNZIP=0

ui_print "========================================"
ui_print "  MarblePerf Runtime Tuner (POCO F5)    "
ui_print "  Evolution X A17 / Snapdragon 7+ Gen 2 "
ui_print "========================================"
ui_print "- Installing service.sh runtime tuning..."
set_perm "$MODPATH/service.sh" 0 0 0755
ui_print "- Done! Tuning will apply automatically on boot."
