#!/bin/sh

# exit if anything fails.
set -e

GIB_IN_BYTES="1073741824"

target="${1:-pi1}"
image_path="/sdcard/filesystem.img"
xz_path="/filesystem.img.xz"

if [ ! -e $image_path ]; then
  echo "No filesystem detected at ${image_path}!"
  if [ -e $xz_path ]; then
      echo "Extracting fresh filesystem..."
      unxz $xz_path
      mv -- *.img $image_path
  else
    exit 1
  fi
fi

mount_point="./mountpoint"
# Create mount point
mkdir -p $mount_point

# Enable SSH and set root user password

# Find offset of filesystem
offset=$(fdisk -l $image_path | grep "Win95" | awk '{print $4}')
# Multiply offset by 512
offset=$(($offset * 512))

# Mount filesystem
mount -v -o offset=$offset $image_path $mount_point

# Add empty ssh file to enable ssh on the pi
touch $mount_point/ssh

echo "root:\$6$/4.VdYgDm7RJ0qM1\$FwXCeQgDKkqrOU3RIRuDSKpauAbBvP11msq9X58c8Que2l1Dwq3vdJMgiZlQSbEXGaY5esVHGBNbCxKLVNqZW1" >> $mount_point/userconf

# Unmount filesystem
umount $mount_point

# Enable root SSH login

mount_point2="./mountpoint2"
# Create mount point
mkdir -p $mount_point2


# Find offset of filesystem
offset=$(fdisk -l $image_path | grep "Linux" | awk '{print $4}')
# Multiply offset by 512
offset=$(($offset * 512))

# Mount filesystem
mount -v -o offset=$offset $image_path $mount_point2

sed -i "s/#\(PermitRootLogin\).*/\1 yes/" $mount_point2/etc/ssh/sshd_config

# Unmount filesystem
umount $mount_point2

qemu-img info $image_path
image_size_in_bytes=$(qemu-img info --output json $image_path | grep "virtual-size" | awk '{print $2}' | sed 's/,//')
if [[ "$(($image_size_in_bytes % ($GIB_IN_BYTES * 2)))" != "0" ]]; then
  new_size_in_gib=$((($image_size_in_bytes / ($GIB_IN_BYTES * 2) + 1) * 2))
  echo "Rounding image size up to ${new_size_in_gib}GiB so it's a multiple of 2GiB..."
  qemu-img resize $image_path "${new_size_in_gib}G"
fi

if [ "${target}" = "pi1" ]; then
  emulator=qemu-system-arm
  cpu=arm1176
  kernel="/root/qemu-rpi-kernel/kernel-qemu-4.19.50-buster"
  dtb="/root/qemu-rpi-kernel/versatile-pb.dtb"
  machine=versatilepb
  memory=256m
  root=/dev/sda2
  nic="--net nic --net user,hostfwd=tcp::5022-:22"
elif [ "${target}" = "pi2" ]; then
  emulator=qemu-system-arm
  cpu=arm1176
  machine=raspi2b
  memory=1024m
  kernel_pattern=kernel7.img
  dtb_pattern=bcm2709-rpi-2-b.dtb
  append="dwc_otg.fiq_fsm_enable=0"
  nic="-netdev user,id=net0,hostfwd=tcp::5022-:22 -device usb-net,netdev=net0"
elif [ "${target}" = "pi3" ]; then
  emulator=qemu-system-aarch64
  machine=raspi3b
  cpu=cortex-a53
  memory=1024m
  kernel_pattern=kernel8.img
  dtb_pattern=bcm2710-rpi-3-b-plus.dtb
  append="dwc_otg.fiq_fsm_enable=0"
  nic="-netdev user,id=net0,hostfwd=tcp::5022-:22 -device usb-net,netdev=net0"
else
  echo "Target ${target} not supported"
  echo "Supported targets: pi1 pi2 pi3"
  exit 2
fi

if [ "${kernel_pattern}" ] && [ "${dtb_pattern}" ]; then
  fat_path="/fat.img"
  echo "Extracting partitions"
  fdisk -l ${image_path} \
    | awk "/^[^ ]*1/{print \"dd if=${image_path} of=${fat_path} bs=512 skip=\"\$4\" count=\"\$6}" \
    | sh

  echo "Extracting boot filesystem"
  fat_folder="/fat"
  mkdir -p "${fat_folder}"
  fatcat -x "${fat_folder}" "${fat_path}"

  root=/dev/mmcblk0p2

  echo "Searching for kernel='${kernel_pattern}'"
  kernel=$(find "${fat_folder}" -name "${kernel_pattern}")

  echo "Searching for dtb='${dtb_pattern}'"
  dtb=$(find "${fat_folder}" -name "${dtb_pattern}")
fi

if [ "${kernel}" = "" ] || [ "${dtb}" = "" ]; then
  echo "Missing kernel='${kernel}' or dtb='${dtb}'"
  exit 2
fi

echo "Booting QEMU machine \"${machine}\" with kernel=${kernel} dtb=${dtb}"
exec ${emulator} \
  --machine "${machine}" \
  --cpu "${cpu}" \
  --m "${memory}" \
  --drive "format=raw,file=${image_path}" \
  ${nic} \
  --dtb "${dtb}" \
  --kernel "${kernel}" \
  --append "rw earlyprintk loglevel=8 console=ttyAMA0,115200 dwc_otg.lpm_enable=0 root=${root} rootwait panic=1 ${append}" \
  --no-reboot \
  --display none \
  --serial mon:stdio
