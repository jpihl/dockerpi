#!/bin/sh

# exit if anything fails.
set -e

GIB_IN_BYTES="1073741824"

image_path="/filesystem.img"

qemu-img info $image_path
image_size_in_bytes=$(qemu-img info --output json $image_path | grep "virtual-size" | awk '{print $2}' | sed 's/,//')
if [[ "$(($image_size_in_bytes % ($GIB_IN_BYTES * 2)))" != "0" ]]; then
  new_size_in_gib=$((($image_size_in_bytes / ($GIB_IN_BYTES * 2) + 1) * 2))
  echo "Rounding image size up to ${new_size_in_gib}GiB so it's a multiple of 2GiB..."
  qemu-img resize $image_path "${new_size_in_gib}G"
fi

fat_path="/fat.img"
echo "Extracting partitions"
fdisk -l ${image_path} \
  | awk "/^[^ ]*1/{print \"dd if=${image_path} of=${fat_path} bs=512 skip=\"\$4\" count=\"\$6}" \
  | sh

echo "Extracting boot filesystem"
fat_folder="/fat"
mkdir -p "${fat_folder}"
fatcat -x "${fat_folder}" "${fat_path}"

kernel_pattern=kernel8.img
echo "Searching for kernel='${kernel_pattern}'"
kernel=$(find "${fat_folder}" -name "${kernel_pattern}")

dtb_pattern=bcm2710-rpi-3-b-plus.dtb
echo "Searching for dtb='${dtb_pattern}'"
dtb=$(find "${fat_folder}" -name "${dtb_pattern}")

echo "Booting QEMU machine raspi3b with kernel=${kernel} dtb=${dtb}"
exec qemu-system-aarch64 \
  --machine raspi3b \
  --cpu cortex-a53 \
  --m 1024m \
  --drive "format=raw,file=${image_path}" \
  --dtb "${dtb}" \
  --kernel "${kernel}" \
  --append "rw earlyprintk loglevel=8 console=ttyAMA0,115200 dwc_otg.lpm_enable=0 root=/dev/mmcblk0p2 rootwait panic=1 dwc_otg.fiq_fsm_enable=0" \
  --no-reboot \
  --display none \
  --serial mon:stdio \
  -netdev user,id=net0,hostfwd=tcp::5022-:22 \
  -device usb-net,netdev=net0
