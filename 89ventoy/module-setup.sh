#!/bin/bash

# tell dracut this module is only used on manual include
check() {
   # for live images hostonly makes no sense
   [[ $hostonly ]] && return 1
   return 255
}

# setup hooks and dependencies
install() {
    inst_hook cmdline 29 "$moddir/parse-ventoy-file.sh"
    inst_script "$moddir/ventoy-mount.sh" "/sbin/ventoy-mount"
    dracut_need_initqueue
}
