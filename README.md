# Ubuntu Bootc with Cloud-Init

An Ubuntu 26.04 LTS ("Resolute Raccoon") bootable container image with [cloud-init](https://cloud-init.io/) built-in, based on the [bootcrew ubuntu-bootc](https://github.com/bootcrew-dev/ubuntu-bootc) project.

This image demonstrates how to build cloud-init support into a [bootc](https://github.com/bootc-dev/bootc) container image, enabling automatic instance configuration on first boot in cloud environments.

## What's Included

- Ubuntu 26.04 LTS base image with bootc support
- Cloud-init for automatic instance configuration
- systemd-networkd (DHCP) and systemd-resolved for networking/DNS
- OpenSSH server enabled
- Standard bootc tooling (ostree, composefs, dracut)

## Quick Start: Converting a Running Ubuntu 26.04 VM

This is the recommended workflow. Start from a running Ubuntu 26.04 LTS VM (e.g. a cloud instance or a local VM from the official cloud image) and convert it in-place to a bootc-managed system.

All commands below should be run as root (`sudo -i` or prefix with `sudo`).

### 1. Install podman

```bash
apt update && apt install -y podman
```

### 2. Pull the image

```bash
podman pull ghcr.io/jmarrero/ubuntu-bootc:latest
```

### 3. Enable ext4 verity and unmount /boot

The target filesystem needs verity support for composefs, and bootc needs to
manage `/boot` itself:

```bash
ROOT_DEV=$(findmnt -no SOURCE /)
tune2fs -O verity "${ROOT_DEV}"
umount /boot/efi 2>/dev/null
umount /boot
```

### 4. Run the install

```bash
podman run --privileged --pid=host --ipc=host --rm \
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
    --root-ssh-authorized-keys /target/root/.ssh/authorized_keys \
    --karg console=tty0 \
    --karg console=ttyS0,115200
```

### 5. Fix the EFI boot order

The install writes systemd-boot to the ESP but does not update the EFI boot
order. You must add systemd-boot as the default boot entry manually:

```bash
# Find the ESP partition number
ESP_PART=$(lsblk -nlo NAME,PARTTYPE /dev/vda | grep -i c12a7328 | grep -o 'vda[0-9]*' | grep -o '[0-9]*')

# Create EFI entry for systemd-boot
efibootmgr --create --disk /dev/vda --part "${ESP_PART}" \
  --label "Linux Boot Manager" \
  --loader "\EFI\systemd\systemd-bootx64.efi"

# Set it as the first boot option
NEW=$(efibootmgr | grep "Linux Boot Manager" | head -1 | sed 's/Boot\([0-9A-F]*\).*/\1/')
OLD=$(efibootmgr | grep "Ubuntu" | head -1 | sed 's/Boot\([0-9A-F]*\).*/\1/')
efibootmgr --bootorder "${NEW},${OLD}"
```

> **Why?** `bootc install to-existing-root` runs inside a container and cannot
> modify EFI variables directly.

### 6. Reboot

```bash
reboot
```

After reboot the system runs as a bootc-managed Ubuntu with composefs. The previous root filesystem is accessible at `/sysroot`.

## Install Flags Reference

| Flag | Purpose |
|------|---------|
| `--acknowledge-destructive` | Confirms you understand this will overwrite the boot partition |
| `--skip-fetch-check` | Skips verifying registry access (useful when image is already local) |
| `--composefs-backend` | Uses composefs for the root filesystem |
| `--allow-missing-verity` | Makes fsverity optional (needed for some ext4 configs) |
| `--bootloader systemd` | Uses systemd-boot instead of GRUB |
| `--cleanup` | Cleans up remnants from the previous Linux installation |
| `--root-ssh-authorized-keys` | Injects SSH keys for root access after reboot |
| `--karg console=ttyS0,115200` | Enables serial console output for headless VMs |

## Building the Image Locally

### Using podman

```bash
podman build -t ubuntu-bootc:latest -f ./Containerfile .
```

### Using the Justfile

```bash
just build-containerfile
```

### Generating a bootable disk image

```bash
just generate-bootable-image
```

This creates a `bootable.img` that can be booted directly in QEMU or another hypervisor.

## Setting Up a Test VM (Optional)

If you need a fresh Ubuntu 26.04 VM to test with:

```bash
# Download the cloud image
wget https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img

# Create a 30G disk with 1G ESP (needed for bootc rollback)
qemu-img create -f qcow2 ubuntu-26.04-bootc-test.qcow2 30G
virt-resize --resize /dev/sda15=1G --expand /dev/sda1 \
  resolute-server-cloudimg-amd64.img ubuntu-26.04-bootc-test.qcow2

# Create cloud-init ISO (see cloud-init/ directory for example configs)
genisoimage -output cloud-init.iso -volid cidata -joliet -rock \
  cloud-init/user-data cloud-init/meta-data

# Copy UEFI vars for the VM
cp /usr/share/edk2/ovmf/OVMF_VARS.fd .

# Launch with QEMU
qemu-system-x86_64 \
    -machine q35,accel=kvm -cpu host -m 16G -smp 6 -nographic \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file=OVMF_VARS.fd \
    -drive file=ubuntu-26.04-bootc-test.qcow2,format=qcow2,if=virtio \
    -drive file=cloud-init.iso,format=raw,if=virtio \
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \
    -device virtio-net-pci,netdev=net0 \
    -serial mon:stdio

# Login: ubuntu / ubuntu
# Or SSH: ssh -p 2222 ubuntu@localhost
```

## Known Issues

### Why not the stock Ubuntu 26.04 kernel and base image?

- **PAX tar headers (composefs-rs bug):** Ubuntu 26.04 is the first release built with Canonical's Rockcraft/umoci tooling, which produces PAX format tars. composefs-rs cannot round-trip these, causing `Layer has incorrect checksum` during install. This image uses a [squashed base image](https://github.com/jmarrero/ubuntu-resolute-squashed) that strips PAX headers. ([composefs-rs#290](https://github.com/composefs/composefs-rs/issues/290))
- **Linux 7.0 fsverity regression (kernel bug):** Ubuntu 26.04 ships kernel 7.0 which has a regression breaking composefs boot with `Failed to execute /sbin/init`. This image uses kernel 6.17 from Ubuntu 25.10 (questing) as a workaround. ([bootc#2174](https://github.com/bootc-dev/bootc/issues/2174))

### Other issues

- **EFI boot order:** `bootc install to-existing-root` does not update EFI variables (runs in a container). You must manually create a systemd-boot EFI entry and update the boot order after install. See the [GUIDE](GUIDE.md) for details.
- **arm64:** Disabled in CI pending [bootc#1703](https://github.com/bootc-dev/bootc/issues/1703) and [composefs-rs#210](https://github.com/containers/composefs-rs/pull/210)

## Acknowledgments

This project was co-authored with [OpenCode](https://opencode.ai/) (Claude Opus 4.6), which assisted with Containerfile development, upstream bug investigation, PAX tar header analysis, kernel regression diagnosis, and documentation.

## License

Apache License, Version 2.0
