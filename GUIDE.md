# Ubuntu 26.04 LTS with bootc -- Getting Started Guide

This guide walks you through converting an Ubuntu 26.04 LTS VM into a bootc-managed
system using composefs. By the end you will have an immutable, image-based Ubuntu
system that can be updated atomically via container images.

## Prerequisites

### Host requirements

You need a Linux host with KVM support and the following packages:

```bash
# Fedora
sudo dnf install qemu-kvm edk2-ovmf genisoimage libguestfs-tools

# Ubuntu/Debian
sudo apt install qemu-system-x86 ovmf genisoimage libguestfs-tools
```

### Why not the stock Ubuntu 26.04 kernel and base image?

There are two upstream issues that prevent using Ubuntu 26.04 with bootc/composefs
out of the box. Both have workarounds built into the image used in this guide:

1. **PAX tar headers (composefs-rs bug)** -- Ubuntu 26.04 is the first release
   built with Canonical's [Rockcraft/umoci](https://canonical-rockcraft.readthedocs-hosted.com/)
   tooling, which produces PAX format tars with sub-second mtime headers. composefs-rs
   cannot round-trip these PAX headers, causing `Layer has incorrect checksum` during install.
   **Workaround:** the image is built from a [squashed base image](https://github.com/jmarrero/ubuntu-resolute-squashed)
   that strips PAX headers. ([composefs-rs#290](https://github.com/composefs/composefs-rs/issues/290))

2. **Linux 7.0 fsverity regression (kernel bug)** -- Ubuntu 26.04 ships kernel 7.0
   which has a regression breaking composefs boot with `Failed to execute /sbin/init`.
   This does not affect kernel 6.x.
   **Workaround:** the image uses kernel 6.17 from Ubuntu 25.10 (questing) repositories.
   ([bootc#2174](https://github.com/bootc-dev/bootc/issues/2174))

Both workarounds are built into the `ghcr.io/jmarrero/ubuntu-bootc:latest` image.
The Ubuntu 26.04 userspace is unchanged -- only the base image format and kernel are different.

## Step 1: Set up the working directory

```bash
mkdir -p ~/ubuntu-bootc-test/cloud-init
cd ~/ubuntu-bootc-test
```

## Step 2: Download the Ubuntu 26.04 cloud image

```bash
wget https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img \
  -O ubuntu-26.04-server-cloudimg-amd64.img
```

This is a ~818 MB base image. You only need to download it once.

## Step 3: Create the VM disk

The Ubuntu cloud image has a 106 MB EFI System Partition (ESP) which is too
small for bootc rollback (two kernel+initramfs sets). Use `virt-resize` to
expand the ESP to 1 GB and the root partition to fill the disk:

```bash
qemu-img create -f qcow2 ubuntu-26.04-bootc-test.qcow2 30G

virt-resize \
  --resize /dev/sda15=1G \
  --expand /dev/sda1 \
  ubuntu-26.04-server-cloudimg-amd64.img \
  ubuntu-26.04-bootc-test.qcow2
```

> **Note:** `virt-resize` requires `libguestfs-tools`. Install with
> `sudo dnf install libguestfs-tools` (Fedora) or
> `sudo apt install libguestfs-tools` (Ubuntu).

## Step 4: Create cloud-init configuration

Cloud-init provisions the VM on first boot with SSH key access and container tools.

```bash
cat > cloud-init/meta-data << 'EOF'
instance-id: ubuntu-bootc-test
local-hostname: ubuntu-bootc-test
EOF

cat > cloud-init/user-data << EOF
#cloud-config
ssh_authorized_keys:
  - $(cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub)
# Uncomment below for password access instead of SSH keys:
# password: ubuntu
# chpasswd:
#   expire: false
# ssh_pwauth: true
packages:
  - podman
  - skopeo
  - buildah
EOF
```

> **Note:** This injects your SSH public key into the `ubuntu` user's
> `authorized_keys`. If you don't have an SSH key, generate one with
> `ssh-keygen -t ed25519` or uncomment the password lines above.

## Step 5: Build the cloud-init ISO

```bash
genisoimage -output cloud-init.iso -volid cidata -joliet -rock \
  cloud-init/user-data cloud-init/meta-data
```

## Step 6: Copy UEFI firmware variables

```bash
cp /usr/share/edk2/ovmf/OVMF_VARS.fd .
```

> On Ubuntu hosts the path may be `/usr/share/OVMF/OVMF_VARS.fd`.

## Step 7: Launch the VM

```bash
qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -cpu host \
    -m 16G \
    -smp 6 \
    -nographic \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file=OVMF_VARS.fd \
    -drive file=ubuntu-26.04-bootc-test.qcow2,format=qcow2,if=virtio \
    -drive file=cloud-init.iso,format=raw,if=virtio \
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \
    -device virtio-net-pci,netdev=net0 \
    -serial mon:stdio
```

> **Tip:** To run in the background, prefix the command with `nohup` and append
> `> vm-console.log 2>&1 &`.

Wait for the login prompt to appear. Cloud-init will install podman, skopeo,
and buildah during the first boot (takes 1-2 minutes).

## Step 8: Connect via SSH

From another terminal:

```bash
ssh -o StrictHostKeyChecking=no -p 2222 ubuntu@localhost
```

> If you configured password auth instead of SSH keys, the password is `ubuntu`.

Wait for cloud-init to finish before proceeding:

```bash
cloud-init status --wait
```

## Step 9: Pull the bootc image

Inside the VM:

```bash
sudo podman pull ghcr.io/jmarrero/ubuntu-bootc:latest
```

> **Note:** If the pull is slow through QEMU's user-mode networking, you can
> pipe the image from the host instead:
> ```bash
> # From the host
> podman save --format oci-archive <image> | \
>   sshpass -p ubuntu ssh -p 2222 ubuntu@localhost 'sudo podman load'
> ```

## Step 10: Enable ext4 verity

The target filesystem needs verity support for composefs:

```bash
# Find the root partition (the one mounted as /)
ROOT_DEV=$(findmnt -no SOURCE /)
sudo tune2fs -O verity "${ROOT_DEV}"
```

## Step 11: Unmount /boot

```bash
sudo umount /boot/efi 2>/dev/null
sudo umount /boot 2>/dev/null
```

## Step 12: Install bootc

```bash
sudo podman run --privileged --pid=host --ipc=host --rm \
  -v /var/lib/containers:/var/lib/containers \
  -v /dev:/dev \
  --security-opt label=type:unconfined_t \
  -v /:/target \
  ghcr.io/jmarrero/ubuntu-bootc:latest \
  bootc install to-existing-root \
  --acknowledge-destructive \
  --skip-fetch-check \
  --composefs-backend \
  --allow-missing-verity \
  --bootloader systemd \
  --root-ssh-authorized-keys /target/home/ubuntu/.ssh/authorized_keys \
  --karg console=tty0 \
  --karg console=ttyS0,115200
```

You should see `Installation complete!` at the end.

> **Note:** The `--root-ssh-authorized-keys` flag injects your SSH keys into
> the root account via a systemd-tmpfiles rule. The path `/target/home/ubuntu/.ssh/authorized_keys`
> reads from the host filesystem (mounted at `/target`) where cloud-init
> already wrote your SSH key. After reboot, SSH as `root` using the same key.

### Install flags explained

| Flag | Purpose |
|------|---------|
| `--acknowledge-destructive` | Confirms this will overwrite the boot partition |
| `--skip-fetch-check` | Skips verifying registry access (image is already local) |
| `--composefs-backend` | Uses composefs for the root filesystem |
| `--allow-missing-verity` | Makes fsverity optional (needed for some ext4 configs) |
| `--bootloader systemd` | Uses systemd-boot instead of GRUB |
| `--root-ssh-authorized-keys` | Injects SSH keys for root access after reboot |
| `--karg console=ttyS0,115200` | Enables serial console output for headless VMs |

## Step 13: Resize the ESP filesystem

`virt-resize` expanded the ESP partition to 1 GB in Step 3, but the FAT
filesystem inside is still 106 MB. Recreate it to fill the partition:

```bash
# Find the ESP partition
ESP_DEV=$(lsblk -nlo NAME,PARTTYPE /dev/vda | grep -i c12a7328 | awk '{print "/dev/"$1}')

# Backup, recreate, restore
sudo mkdir -p /tmp/esp-backup
sudo mount "${ESP_DEV}" /mnt
sudo cp -a /mnt/* /tmp/esp-backup/
sudo umount /mnt
sudo mkfs.fat -F 32 -n UEFI "${ESP_DEV}"
sudo mount "${ESP_DEV}" /mnt
sudo cp -a /tmp/esp-backup/* /mnt/
sudo umount /mnt
```

## Step 14: Fix the EFI boot order

The install writes systemd-boot to the ESP but does not update the EFI boot
order. The existing GRUB entry still takes priority, so you need to add
systemd-boot and set it as the default:

```bash
# Find the ESP partition number
ESP_PART=$(lsblk -nlo NAME,PARTTYPE /dev/vda | grep -i c12a7328 | grep -o 'vda[0-9]*' | grep -o '[0-9]*')

# Create a new EFI boot entry for systemd-boot
sudo efibootmgr --create --disk /dev/vda --part "${ESP_PART}" \
  --label "Linux Boot Manager" \
  --loader "\EFI\systemd\systemd-bootx64.efi"

# Get the new entry number and the old Ubuntu entry
NEW=$(sudo efibootmgr | grep "Linux Boot Manager" | head -1 | sed 's/Boot\([0-9A-F]*\).*/\1/')
OLD=$(sudo efibootmgr | grep "Ubuntu" | head -1 | sed 's/Boot\([0-9A-F]*\).*/\1/')

# Set systemd-boot first, keep old Ubuntu as fallback
sudo efibootmgr --bootorder "${NEW},${OLD}"
```

> **Why is this needed?** `bootc install to-existing-root` runs inside a
> container and cannot modify EFI variables directly.

## Step 15: Reboot

```bash
sudo reboot
```

## Step 16: Verify the bootc system

After reboot, connect via SSH as root (the `--root-ssh-authorized-keys` flag
injected your SSH key into the root account):

```bash
ssh -o StrictHostKeyChecking=no -p 2222 root@localhost
```

Check the system:

```bash
# OS version
cat /etc/os-release | head -4

# Kernel (should be 6.17.x, not 7.0)
uname -r

# bootc status
sudo bootc status | head -15

# Root filesystem (should show composefs overlay)
mount | grep "on / "

# DNS and internet
cat /etc/resolv.conf | head -2
wget -q --spider https://google.com && echo "Internet works"

# Networking
ip addr show | grep "inet "
```

Expected output:

```
PRETTY_NAME="Ubuntu 26.04 LTS"
6.17.0-23-generic

composefs:... on / type overlay (ro,relatime,...,verity=require)
```

## Updating the system

The ESP is automatically mounted at `/boot` on every boot. You can update
the system with:

```bash
# Check for updates
sudo bootc upgrade --check

# Apply updates
sudo bootc upgrade

# Or switch to a different image
sudo bootc switch <new-image>

# Reboot to activate
sudo reboot
```

After reboot, `bootc status` will show the new image as booted and the
previous image as rollback.

## What you have now

- An Ubuntu 26.04 LTS system managed by bootc
- Immutable root filesystem via composefs with EROFS
- Atomic updates via `sudo bootc upgrade` or `sudo bootc switch <new-image>`
- Rollback support (previous image kept as fallback)
- The previous Ubuntu installation accessible at `/sysroot`
- systemd-boot as the bootloader
- systemd-networkd for DHCP networking
- SSH access enabled

## Building your own image

The image used in this guide is built from:
https://github.com/jmarrero/ubuntu-bootc

To build your own:

```bash
git clone https://github.com/jmarrero/ubuntu-bootc.git
cd ubuntu-bootc
podman build -t my-ubuntu-bootc:latest -f ./Containerfile .
```

The Containerfile adds cloud-init, OpenSSH, systemd-networkd, and other
services on top of the base bootc image. You can customize it by adding
packages, configuration files, or systemd services.

## Troubleshooting

### No serial output after reboot

If you see systemd-boot load but no kernel output, the BLS entry is missing
console kernel arguments. Fix with `guestfish`:

```bash
# From the host (VM must be stopped)
# Find the ESP partition (look for the vfat filesystem)
ESP=$(guestfish --ro -a ubuntu-26.04-bootc-test.qcow2 run : list-filesystems | grep vfat | cut -d: -f1)
guestfish -a ubuntu-26.04-bootc-test.qcow2 <<EOF
run
mount ${ESP} /
download /loader/entries/bootc_ubuntu-26.04-1.conf /tmp/bls.conf
EOF
sed -i 's|^options |options console=tty0 console=ttyS0,115200 |' /tmp/bls.conf
guestfish -a ubuntu-26.04-bootc-test.qcow2 <<EOF
run
mount ${ESP} /
upload /tmp/bls.conf /loader/entries/bootc_ubuntu-26.04-1.conf
EOF
```

### System boots into old Ubuntu instead of bootc

The EFI boot order was not updated. See [Step 13](#step-13-fix-the-efi-boot-order).

### `Layer has incorrect checksum` during install

The base image uses PAX tar format. Use a squashed base image or build with
`podman build --squash-all`. See the [Known Issues](#known-issues-as-of-may-2026) section.

### `Failed to execute /sbin/init` after switch-root

The kernel has the Linux 7.0 fsverity regression. Use kernel 6.17 from
Ubuntu 25.10 (questing) repositories. The image at
`ghcr.io/jmarrero/ubuntu-bootc:latest` already includes this workaround.

### Starting fresh

To reset the VM completely:

```bash
rm -f ubuntu-26.04-bootc-test.qcow2 OVMF_VARS.fd
qemu-img create -f qcow2 ubuntu-26.04-bootc-test.qcow2 30G
virt-resize --resize /dev/sda15=1G --expand /dev/sda1 \
  ubuntu-26.04-server-cloudimg-amd64.img ubuntu-26.04-bootc-test.qcow2
cp /usr/share/edk2/ovmf/OVMF_VARS.fd .
```

The cloud image itself is never modified.
