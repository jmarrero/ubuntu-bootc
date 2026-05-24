# Ubuntu 26.04 LTS (Resolute Raccoon) bootc image with cloud-init.
#
# Multi-stage build: a separate builder stage compiles bootc from source,
# then the final image installs system packages, copies the bootc binaries,
# and configures the ostree/composefs root layout.
#
# Based on the bootcrew/mono build process.
#
# Uses a squashed Ubuntu base image (ghcr.io/jmarrero/ubuntu-resolute-squashed)
# to work around composefs-rs not handling PAX tar headers from umoci/Rockcraft.
# See: https://github.com/jmarrero/ubuntu-resolute-squashed

FROM scratch AS ctx
COPY shared/ /shared

FROM ghcr.io/jmarrero/ubuntu-resolute-squashed:latest AS base

# --- Stage 1: Build bootc from source ----------------------------------------

FROM base AS builder

ARG DEBIAN_FRONTEND=noninteractive

RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root --mount=type=tmpfs,dst=/boot \
    apt update -y && \
    apt install -y git curl make build-essential go-md2man libzstd-dev pkgconf libostree-dev ostree

ENV CARGO_HOME=/tmp/rust
ENV RUSTUP_HOME=/tmp/rust
WORKDIR /home/build
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    curl --proto '=https' --tlsv1.2 -sSf "https://sh.rustup.rs" | sh -s -- --profile minimal -y && \
    sh -c ". ${RUSTUP_HOME}/env ; /ctx/shared/build.sh"

# --- Stage 2: Final system image ---------------------------------------------

FROM base AS system

ARG DEBIAN_FRONTEND=noninteractive

COPY --from=builder /output /

# Add questing (25.10) repo for kernel 6.17 to work around Linux 7.0 fsverity regression
# See: https://github.com/bootc-dev/bootc/issues/2174
RUN echo "deb http://archive.ubuntu.com/ubuntu questing main" > /etc/apt/sources.list.d/questing.list && \
    echo "deb http://archive.ubuntu.com/ubuntu questing-updates main" >> /etc/apt/sources.list.d/questing.list

# Install system packages including cloud-init
# Pin linux-image-generic and linux-firmware to questing (6.17) to avoid kernel 7.0 fsverity regression
RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root --mount=type=tmpfs,dst=/boot apt update -y && \
  apt install -y cloud-init nano snapd sudo openssh-server \
    btrfs-progs dosfstools e2fsprogs fdisk \
    linux-firmware/questing-updates linux-image-generic/questing-updates \
    podman skopeo systemd systemd-boot* xfsprogs ostree libostree-dev dracut tmux && \
  cp /boot/vmlinuz-* "$(find /usr/lib/modules -maxdepth 1 -type d | tail -n 1)/vmlinuz" && \
  apt clean -y

# Enable cloud-init target
RUN mkdir -p /usr/lib/systemd/system/default.target.wants && \
    ln -sf ../cloud-init.target /usr/lib/systemd/system/default.target.wants/cloud-init.target

# Enable services: ssh, systemd-networkd, systemd-resolved
RUN ln -sf /usr/lib/systemd/system/ssh.service /etc/systemd/system/multi-user.target.wants/ssh.service && \
    ln -sf /usr/lib/systemd/system/systemd-networkd.service /usr/lib/systemd/system/multi-user.target.wants/systemd-networkd.service && \
    ln -sf /usr/lib/systemd/system/systemd-resolved.service /usr/lib/systemd/system/multi-user.target.wants/systemd-resolved.service

# Cloud-init bootc-specific config:
# - growpart targets /sysroot on ostree systems
# - default user home set to /var/home/ubuntu (not /home/ubuntu) because
#   /home is a symlink to /var/home on bootc, and cloud-init's ssh_util
#   rejects symlinks in the authorized_keys path for security
RUN mkdir -p /etc/cloud/cloud.cfg.d && \
    printf "growpart:\n  mode: auto\n  devices: [\"/sysroot\"]\nresize_rootfs: false\nsystem_info:\n  default_user:\n    homedir: /var/home/ubuntu\n" \
    > /etc/cloud/cloud.cfg.d/10_bootc.cfg

# tmpfiles configs: L+ replaces any existing file with a symlink on every boot
# This fixes DNS by ensuring /etc/resolv.conf points to systemd-resolved
RUN mkdir -p /usr/lib/tmpfiles.d && \
    printf "L+ /etc/resolv.conf - - - - /run/systemd/resolve/stub-resolv.conf\n" > /usr/lib/tmpfiles.d/resolved-fix.conf && \
    printf "d /var/lib/snapd 0755 root root -\nd /var/cache/snapd 0755 root root -\nd /var/snap 0755 root root -" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf"

# Auto-mount ESP at /boot so bootc upgrade/switch can write kernel+initramfs
# Uses LABEL=UEFI since /dev/disk/by-parttype/ symlinks are not always available
RUN mkdir -p /usr/lib/systemd/system/local-fs.target.wants && \
    printf '[Unit]\nDescription=EFI System Partition\n\n[Mount]\nWhat=LABEL=UEFI\nWhere=/boot\nType=vfat\nOptions=umask=0077\n\n[Install]\nWantedBy=local-fs.target\n' > /usr/lib/systemd/system/boot.mount && \
    ln -sf ../boot.mount /usr/lib/systemd/system/local-fs.target.wants/boot.mount



# systemd-networkd DHCP config for ethernet interfaces
RUN mkdir -p /etc/systemd/network/ && \
    printf '[Match]\nName=e*\n\n[Network]\nDHCP=yes\n' > /etc/systemd/network/10-eth-dhcp.network

# Generate initramfs with bootc dracut module
RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root \
    --mount=type=bind,from=ctx,source=/,target=/ctx \
    /ctx/shared/initramfs.sh

# Set up ostree/composefs root filesystem layout
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    echo "HOME=/var/home" | tee -a "/etc/default/useradd" && \
    /ctx/shared/bootc-rootfs.sh

# https://bootc-dev.github.io/bootc/bootc-images.html#standard-metadata-for-bootc-compatible-images
LABEL containers.bootc 1

RUN bootc container lint
