FROM docker.io/library/ubuntu:questing

ARG DEBIAN_FRONTEND=noninteractive

RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root --mount=type=tmpfs,dst=/boot apt update -y && \
  apt install -y nano snapd sudo openssh-server btrfs-progs dosfstools e2fsprogs fdisk linux-firmware linux-image-generic skopeo systemd systemd-boot* xfsprogs && \
  cp /boot/vmlinuz-* "$(find /usr/lib/modules -maxdepth 1 -type d | tail -n 1)/vmlinuz" && \
  ln -s /usr/lib/systemd/system/ssh.service /etc/systemd/system/multi-user.target.wants/ssh.service && \
  ln -s /usr/lib/systemd/system/systemd-networkd.service /usr/lib/systemd/system/multi-user.target.wants/systemd-networkd.service && \
  ln -s /usr/lib/systemd/system/systemd-resolved.service /usr/lib/systemd/system/multi-user.target.wants/systemd-resolved.service && \
  apt clean -y

# Create a tmpfiles configuration to manage the symlink at boot time
RUN mkdir -p /usr/lib/tmpfiles.d && \
    printf "L /etc/resolv.conf - - - - /run/systemd/resolve/stub-resolv.conf" > /usr/lib/tmpfiles.d/resolved-fix.conf
    printf "d /var/lib/snapd 0755 root root -\nd /var/cache/snapd 0755 root root -\nd /var/snap 0755 root root -" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf"

# 1. Create the systemd-networkd config directory
RUN mkdir -p /etc/systemd/network/

# 2. Write the native .network file (equivalent to your DHCP YAML)
RUN printf '[Match]\nName=e*\n\n[Network]\nDHCP=yes\n' > /etc/systemd/network/10-eth-dhcp.network

# Setup a temporary root passwd (changeme) for dev purposes
# RUN apt update -y && apt install -y whois
# RUN usermod -p "$(echo "changeme" | mkpasswd -s)" root

ENV CARGO_HOME=/tmp/rust
ENV RUSTUP_HOME=/tmp/rust
RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root --mount=type=tmpfs,dst=/boot \
    apt update -y && \
    apt install -y git curl make build-essential go-md2man libzstd-dev pkgconf dracut libostree-dev ostree && \
    curl --proto '=https' --tlsv1.2 -sSf "https://sh.rustup.rs" | sh -s -- --profile minimal -y && \
    git clone "https://github.com/bootc-dev/bootc.git" /tmp/bootc && \
    sh -c ". ${RUSTUP_HOME}/env ; make -C /tmp/bootc bin install-all" && \
    printf "systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n" | tee "/usr/lib/dracut/dracut.conf.d/30-bootcrew-fix-bootc-module.conf" && \
    printf 'reproducible=yes\nhostonly=no\ncompress=zstd\nadd_dracutmodules+=" bootc "' | tee "/usr/lib/dracut/dracut.conf.d/30-bootcrew-bootc-container-build.conf" && \
    dracut --force "$(find /usr/lib/modules -maxdepth 1 -type d | tail -n 1)/initramfs.img" && \
    apt purge -y git curl make build-essential go-md2man libzstd-dev pkgconf libostree-dev && \
    apt autoremove -y && \
    apt clean -y

# Necessary for general behavior expected by image-based systems
RUN echo "HOME=/var/home" | tee -a "/etc/default/useradd" && \
    rm -rf /boot /home /root /usr/local /srv /var && \
    mkdir -p /sysroot /boot /usr/lib/ostree /var && \
    ln -s sysroot/ostree /ostree && ln -s var/roothome /root && ln -s var/srv /srv && ln -s var/opt /opt && ln -s var/mnt /mnt && ln -s var/home /home && \
    echo "$(for dir in opt home srv mnt usrlocal ; do echo "d /var/$dir 0755 root root -" ; done)" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf" && \
    printf "d /var/roothome 0700 root root -\nd /run/media 0755 root root -" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf" && \
    printf '[composefs]\nenabled = yes\n[sysroot]\nreadonly = true\n' | tee "/usr/lib/ostree/prepare-root.conf"

# https://bootc-dev.github.io/bootc/bootc-images.html#standard-metadata-for-bootc-compatible-images
LABEL containers.bootc 1

RUN bootc container lint
