# Build stage for qemu-system-arm
FROM debian:stable-slim AS qemu-builder
ARG QEMU_VERSION=6.1.0
ENV QEMU_TARBALL="qemu-${QEMU_VERSION}.tar.xz"
WORKDIR /qemu

# Update package lists
RUN apt-get update

# Pull source
RUN apt-get -y install wget
RUN wget "https://download.qemu.org/${QEMU_TARBALL}"

# Verify signatures
RUN apt-get -y install gpg
RUN wget "https://download.qemu.org/${QEMU_TARBALL}.sig"
RUN gpg --keyserver keyserver.ubuntu.com --recv-keys CEACC9E15534EBABB82D3FA03353C9CEF108B584
RUN gpg --verify "${QEMU_TARBALL}.sig" "${QEMU_TARBALL}"

# Extract source tarball
RUN apt-get -y install pkg-config
RUN tar xvf "${QEMU_TARBALL}"

# Build source
# These seem to be the only deps actually required for a successful  build
RUN apt-get -y install python build-essential libglib2.0-dev libpixman-1-dev ninja-build
# These don't seem to be required but are specified here: https://wiki.qemu.org/Hosts/Linux
RUN apt-get -y install libfdt-dev zlib1g-dev
# Not required or specified anywhere but supress build warnings
RUN apt-get -y install flex bison
RUN "qemu-${QEMU_VERSION}/configure" --static --target-list=aarch64-softmmu
RUN make -j$(nproc)

# Strip the binary, this gives a substantial size reduction!
RUN strip "aarch64-softmmu/qemu-system-aarch64" "qemu-img"


# Build stage for fatcat
FROM debian:stable-slim AS fatcat-builder
ARG FATCAT_VERSION=v1.1.0
ARG FATCAT_CHECKSUM="303efe2aa73cbfe6fbc5d8af346d0f2c70b3f996fc891e8859213a58b95ad88c"
ENV FATCAT_TARBALL="${FATCAT_VERSION}.tar.gz"
WORKDIR /fatcat

# Update package lists
RUN apt-get update

# Pull source
RUN apt-get -y install wget
RUN wget "https://github.com/Gregwar/fatcat/archive/${FATCAT_TARBALL}"
RUN echo "${FATCAT_CHECKSUM} ${FATCAT_TARBALL}" | sha256sum --check

# Extract source tarball
RUN tar xvf "${FATCAT_TARBALL}"

# Build source
RUN apt-get -y install build-essential cmake
RUN cmake fatcat-* -DCMAKE_CXX_FLAGS='-static'
RUN make -j$(nproc)

# Build the dockerpi image
FROM debian:stable-slim AS image-builder
ARG FILESYSTEM_IMAGE_URL="http://downloads.raspberrypi.org/raspios_lite_arm64/images/raspios_lite_arm64-2022-04-07/2022-04-04-raspios-bullseye-arm64-lite.img.xz"
ARG FILESYSTEM_IMAGE_CHECKSUM="35f1d2f4105e01f4ca888ab4ced6912411e82a2539c53c9e4e6b795f25275a1f"

COPY --from=qemu-builder /qemu/qemu-img /usr/local/bin/qemu-img

# Update package lists
RUN apt-get update

# Pull image file
RUN apt-get -y install wget
RUN wget $FILESYSTEM_IMAGE_URL -O /filesystem.img.xz
RUN echo "$FILESYSTEM_IMAGE_CHECKSUM  /filesystem.img.xz" | sha256sum -c

# Extract image file
RUN apt-get -y install xz-utils
RUN unxz /filesystem.img.xz

# Configure image using guestfish
RUN apt-get -y install libguestfs-tools
# Enable SSH and root user with password "raspberry"
RUN guestfish add /filesystem.img : run : \
    mount /dev/sda1 / : \
    write /ssh "" : \
    write /userconf "root:\$6$/4.VdYgDm7RJ0qM1\$FwXCeQgDKkqrOU3RIRuDSKpauAbBvP11msq9X58c8Que2l1Dwq3vdJMgiZlQSbEXGaY5esVHGBNbCxKLVNqZW1"

# Enable root login via SSH
RUN guestfish add /filesystem.img : run : \
    mount /dev/sda2 / : \
    download /etc/ssh/sshd_config /tmp/sshd_config
RUN sed -i "s/#\(PermitRootLogin\).*/\1 yes/" /tmp/sshd_config
RUN guestfish add /filesystem.img : run : \
    mount /dev/sda2 / : \
    upload /tmp/sshd_config /etc/ssh/sshd_config

# Resize image to be a power of two
RUN qemu-img resize /filesystem.img 2G

# Extract the kernel and dtb files from the filesystem image
FROM busybox:1.34 AS kernel-dtb-builder
COPY --from=fatcat-builder /fatcat/fatcat /usr/local/bin/fatcat
COPY --from=image-builder /filesystem.img /filesystem.img

RUN fdisk -l /filesystem.img \
  | awk "/^[^ ]*1/{print \"dd if=/filesystem.img of=./fat.img bs=512 skip=\"\$4\" count=\"\$6}" \
  | sh

RUN mkdir -p /fat
RUN fatcat -x /fat ./fat.img

# Build the dockerpi VM image
# FROM busybox:1.34 AS dockerpi
FROM ubuntu:latest AS dockerpi

COPY --from=qemu-builder /qemu/aarch64-softmmu/qemu-system-aarch64 /usr/local/bin/qemu-system-aarch64
COPY --from=image-builder /filesystem.img /filesystem.img
COPY --from=kernel-dtb-builder /fat/kernel8.img /kernel8.img
COPY --from=kernel-dtb-builder /fat/bcm2710-rpi-3-b-plus.dtb /bcm2710-rpi-3-b-plus.dtb

CMD qemu-system-aarch64 \
  --machine raspi3b \
  --cpu cortex-a53 \
  --m 1024m \
  --drive format=raw,file=/filesystem.img \
  --dtb /bcm2710-rpi-3-b-plus.dtb \
  --kernel /kernel8.img \
  --append "rw earlyprintk loglevel=8 console=ttyAMA0,115200 dwc_otg.lpm_enable=0 root=/dev/mmcblk0p2 rootwait panic=1 dwc_otg.fiq_fsm_enable=0" \
  --no-reboot \
  --display none \
  -netdev user,id=net0,hostfwd=tcp::5022-:22 \
  -device usb-net,netdev=net0
