#!/usr/bin/env bash

set -xeuo pipefail

rm -rf /boot /home /root /usr/local /srv /opt /mnt /var

mkdir -p /sysroot /boot /usr/lib/ostree /var /home /root /opt /mnt /srv

# Only /ostree and /usr/local remain as symlinks; /home /root /opt /mnt /srv
# are real directories backed by systemd bind mount units for snap compatibility
# (snap-confine can't rbind-mount through symlinks on composefs)
ln -sT sysroot/ostree /ostree && ln -sT ../var/usrlocal /usr/local

printf "d /var/lib/snapd/snap 0755 root root -\n" >> /usr/lib/tmpfiles.d/bootc-base-dirs.conf

echo "$(for dir in opt home srv mnt usrlocal ; do echo "d /var/$dir 0755 root root -" ; done)" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf"

printf "d /var/roothome 0700 root root -\nd /run/media 0755 root root -" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf"

printf '[composefs]\nenabled = yes\n[sysroot]\nreadonly = true\n' | tee "/usr/lib/ostree/prepare-root.conf"
