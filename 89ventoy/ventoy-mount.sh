#!//bin/sh

type getarg > /dev/null 2>&1 || . /lib/dracut-lib.sh

PATH=/usr/sbin:/usr/bin:/sbin:/bin

id_type=$1
id=$2

echo $id_type
echo $id

[ -z "$id_type" ] && exit 1
[ -z "$id" ] && exit 1

ismounted "/run/initramfs/ventoy" && exit 0

mkdir -p "/run/initramfs/ventoy"

do_ventoy_mount() {
    echo "try mounting Ventoy storage"
    if [ -e "/dev/disk/by-label/Ventoy" ]; then
        mount -t auto "/dev/disk/by-label/Ventoy" "/run/initramfs/ventoy"
        local _id
        local ventoy_file
        for ventoy_file in /run/initramfs/ventoy/*; do
            echo "probing file "$ventoy_file
           _id=$(blkid -s $id_type -o value $ventoy_file)
           if [ "$_id" == "$id" ]; then
               losetup -P -f $ventoy_file
               rm -f -- "$job"
               exit 0
           fi
        done
    fi
}

do_ventoy_mount

rmdir "/run/initramfs/ventoy"
exit 1
