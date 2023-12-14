#!/bin/sh

iso_label=$(getarg ventoy-label)
img_ptuuid=$(getarg ventoy-ptuuid)

if [ -n "$iso_label" ]; then
    /sbin/initqueue --settled --unique /sbin/ventoy-mount LABEL $iso_label
fi

if [ -n "$img_ptuuid" ]; then
    /sbin/initqueue --settled --unique /sbin/ventoy-mount PTUUID $img_ptuuid
fi
