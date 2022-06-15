#!/bin/sh

# exit if anything fails.
set -e

kernel=$(find "/fat" -name "kernel8.img")
dtb=$(find "/fat" -name "bcm2710-rpi-3-b-plus.dtb")

echo "Booting QEMU machine raspi3b with kernel=${kernel} dtb=${dtb}"
exec qemu-system-aarch64 \
  --machine raspi3b \
  --cpu cortex-a53 \
  --m 1024m \
  --drive "format=raw,file=/filesystem.img" \
  --dtb "${dtb}" \
  --kernel "${kernel}" \
  --append "rw earlyprintk loglevel=8 console=ttyAMA0,115200 dwc_otg.lpm_enable=0 root=/dev/mmcblk0p2 rootwait panic=1 dwc_otg.fiq_fsm_enable=0" \
  --no-reboot \
  --display none \
  --serial mon:stdio \
  -netdev user,id=net0,hostfwd=tcp::5022-:22 \
  -device usb-net,netdev=net0
