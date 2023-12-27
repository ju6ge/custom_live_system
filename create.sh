#!/bin/zsh

create_script_path=$(realpath "$0")
source_dir=$(dirname $create_script_path)

iso_label=$(tr -dc 'A-Z' < /dev/urandom | head -c 16)

build_dir=/tmp/rescue_system

mkdir -p $build_dir

rescue_img=$build_dir/rescue.img
rescue_iso=$build_dir/rescue.iso

dd if=/dev/zero of=$rescue_img bs=1M count=10000 2>/dev/null
echo "Created $rescue_img"

# partition image
sed -e 's/\s*\([\+0-9a-zA-Z]*\).*/\1/' << EOF | fdisk $rescue_img
  g # clear the in memory partition table
  n # new partition
  1 # partition number 1
    # default - start at beginning of disk
  +100M # 100 MB boot parttion
  t # change partion type
  1 # set to efi system partition
  n # new partition
  2 # partion number 2
    # default, start immediately after preceding partition
    # default, extend partition to end of disk
  p # print the in-memory partition table
  w # write the partition table
EOF

efi_offset=$(sfdisk -J $rescue_img | jq '.partitiontable.partitions.[0].start')
efi_size=$(sfdisk -J $rescue_img | jq '.partitiontable.partitions.[0].size')
root_offset=$(sfdisk -J $rescue_img | jq '.partitiontable.partitions.[1].start')
root_size=$(sfdisk -J $rescue_img | jq '.partitiontable.partitions.[1].size')

efi_loop=$(losetup -o $(($efi_offset*512)) --sizelimit $((($efi_size-1)*512)) -f $rescue_img --show)
root_loop=$(losetup -o $(($root_offset*512)) --sizelimit $((($root_size-1)*512)) -f $rescue_img --show)

root_mount=$build_dir/root
efi_mount=$root_mount/boot/efi

mkfs.fat -F 32 $efi_loop
mkfs.ext4 $root_loop

mkdir -p $root_mount
mount $root_loop $root_mount

mkdir -p $efi_mount
mount $efi_loop $efi_mount

pacstrap $root_mount base \
                     base-devel \
                     dracut \
                     linux-lts \
                     linux-lts-headers \
                     linux-firmware \
                     util-linux \
                     dkms \
                     zfs-dkms \
                     squashfs-tools \
                     vim \
                     rust \
                     git \
                     efibootmgr \
                     efivar \
                     gnu-netcat \
                     iwd \
                     jq \
                     curl \
                     fakeroot \
                     clang \
                     zsh \
                     cdrkit

efi_tool_url=$(curl https://api.github.com/repos/ju6ge/dracut-efi-manager/releases/latest | jq -r ' .assets[] | select( .name | endswith("zip") ) | .browser_download_url ')

curl -sSL $efi_tool_url -o /tmp/dracut-efi-manager.zip && unzip -o /tmp/dracut-efi-manager.zip dracut-efi-manager -d $root_mount/bin && rm /tmp/dracut-efi-manager.zip
fi_tool_url

#copy dracut module source to system
cp -r $source_dir/89ventoy $root_mount/usr/lib/dracut/modules.d
cp -r $source_dir $root_mount/root/create_rescue_iso

echo "rescuesystem" > $root_mount/etc/hostname
echo "KEYMAP=de" > $root_mount/etc/vconsole.conf
echo "KEYMAP_TOGGLE=neo" >> $root_mount/etc/vconsole.conf

mkdir -p $root_mount/etc/systemd/system/getty@tty1.service.d
cat <<EOF > $root_mount/etc/systemd/system/getty@tty1.service.d/autologin.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin root %I $TERM
EOF

arch-chroot $root_mount bash -c 'echo "root:rescuesystem" | chpasswd'
arch-chroot $root_mount ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
arch-chroot $root_mount localectl set-keymap de neo
arch-chroot $root_mount localectl set-x11-keymap de neo
mkdir -p $efi_mount/EFI/BOOT

kernel_version=$(ls $root_mount/usr/lib/modules | jq -R | jq -s -c | jq -r '.[0]')

# create efi kernel for iso booting
cat <<EOF > $root_mount/etc/dracut.conf.d/liveiso.conf
hostonly=no
filesystem=" squashfs "
add_drivers=" amdgpu "
add_dracutmodules=" systemd-udevd ventoy dmsquash-live "
kernel_cmdline=" root=live:CDLABEL=$iso_label rd.live.squashimg=rootfs.sfs rd.live.overlay.overlayfs ro ventoy-label=$iso_label "
EOF
#kernel_cmdline=" rescue "
arch-chroot $root_mount dracut --force --uefi --uefi-stub /usr/lib/systemd/boot/efi/linuxx64.efi.stub /boot/efi/EFI/BOOT/BOOTX64.EFI --kver $kernel_version
sync

iso_dir=$build_dir/iso
mkdir -p $iso_dir

dd if=$efi_loop of=$iso_dir/efi.img status=progress

disk_ptuuid=$(blkid -s PTUUID -o value $rescue_img)

# overwrite efi kernel image for disk image boot
root_fs_uuid=$(blkid -s UUID -o value $root_loop)
rm $root_mount/etc/dracut.conf.d/liveiso.conf
cat <<EOF > $root_mount/etc/dracut.conf.d/default.conf
hostonly=no
add_drivers=" amdgpu "
add_dracutmodules=" systemd-udevd ventoy "
kernel_cmdline="root=UUID=$root_fs_uuid ventoy-ptuuid=$disk_ptuuid "
EOF
arch-chroot $root_mount dracut --force --uefi --uefi-stub /usr/lib/systemd/boot/efi/linuxx64.efi.stub /boot/efi/EFI/BOOT/BOOTX64.EFI --kver $kernel_version

rm $root_mount/etc/fstab

mkdir -p $iso_dir/LiveOS
rm $iso_dir/LiveOS/rootfs.sfs
mksquashfs $root_mount $iso_dir/LiveOS/rootfs.sfs -comp xz
mkdir -p $iso_dir/isolinux
cp /usr/lib/syslinux/bios/isolinux.bin $iso_dir/isolinux

xorriso -as mkisofs \
  -V $iso_label \
  -o $rescue_iso \
  -isohybrid-mbr /usr/lib/syslinux/bios/isohdpfx.bin \
  -b isolinux/isolinux.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e efi.img \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  $iso_dir

genfstab -U $root_mount > $root_mount/etc/fstab

umount $efi_mount
umount $root_mount
losetup -d $efi_loop
losetup -d $root_loop
