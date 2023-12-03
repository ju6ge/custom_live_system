#!/bin/zsh

build_dir=/tmp/rescue_system

mkdir -p $build_dir

rescue_img=$build_dir/rescue_arch_zfs.img

dd if=/dev/zero of=$rescue_img bs=1M count=3000 2>/dev/null
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

pacstrap $root_mount base base-devel dracut linux-lts linux-lts-headers zfs-linux-lts

genfstab -U $root_mount > $root_mount/etc/fstab
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
echo 'kernel_cmdline="iso-scan/filename=rootfs.sfs root=/run/initramfs/isoscandev/rootfs.sfs rootfstype=sqashfs"' > $root_mount/etc/dracut.conf.d/liveiso.conf
arch-chroot $root_mount dracut --force --uefi --uefi-stub /usr/lib/systemd/boot/efi/linuxx64.efi.stub /boot/efi/EFI/BOOT/BOOTX64.EFI --kver $kernel_version
sync

iso_dir=$build_dir/iso
mkdir -p $iso_dir

dd if=$efi_loop of=$iso_dir/efi.img status=progress

# overwrite efi kernel image for disk image boot
root_fs_uuid=$(blkid -s UUID -o value $root_loop)
rm $root_mount/etc/dracut.conf.d/liveiso.conf
echo 'kernel_cmdline="root=UUID='$root_fs_uuid'"' > $root_mount/etc/dracut.conf.d/cmdline.conf
arch-chroot $root_mount dracut --force --uefi --uefi-stub /usr/lib/systemd/boot/efi/linuxx64.efi.stub /boot/efi/EFI/BOOT/BOOTX64.EFI --kver $kernel_version

mksquashfs $root_mount $iso_dir/rootfs.sfs -comp xz
mkdir -p $iso_dir/isolinux
cp /usr/lib/syslinux/bios/isolinux.bin $iso_dir/isolinux

xorriso -as mkisofs \
  -o $build_dir/output.iso \
  -isohybrid-mbr /usr/lib/syslinux/bios/isohdpfx.bin \
  -b isolinux/isolinux.bin \
   -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e efi.img \
   -no-emul-boot \
   -isohybrid-gpt-basdat \
  $iso_dir

umount $efi_mount
umount $root_mount
losetup -d $efi_loop
losetup -d $root_loop

