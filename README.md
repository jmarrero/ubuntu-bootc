# Ubuntu Bootc

An Ubuntu 26.04 LTS ("Resolute Raccoon") bootable container image with [cloud-init](https://cloud-init.io/) and [podman](https://podman.io/) built-in, designed for use with [bootc](https://github.com/bootc-dev/bootc) and [bcvk](https://github.com/bootc-dev/bcvk).

## What's Included

- Ubuntu 26.04 LTS base image with bootc support
- Cloud-init for automatic instance configuration (generator-controlled, does not block boot when no datasource is present)
- Podman for running containers (Quadlet support)
- Snap compatibility (bind mount units for composefs)
- systemd-networkd (DHCP) and systemd-resolved for networking/DNS
- OpenSSH server enabled
- Kernel 6.17 from Ubuntu 25.10 (workaround for Linux 7.0 fsverity regression)
- Standard bootc tooling (ostree, composefs, dracut)

## Quick Start with bcvk

The easiest way to run this image is with [bcvk](https://github.com/bootc-dev/bcvk), which handles disk creation, installation, and SSH key injection automatically.

### 1. Build the image

```bash
podman build -t ubuntu-bootc:latest -f Containerfile .
```

### 2. Run as a libvirt VM

```bash
bcvk libvirt run --composefs-backend --filesystem ext4 --firmware uefi-insecure \
    localhost/ubuntu-bootc
```

> **Note:** `--firmware uefi-insecure` is required because the kernel 6.17 from Ubuntu 25.10 (questing) is not signed for secure boot. See [Known Issues](#known-issues).

### 3. Connect via SSH

```bash
bcvk libvirt ssh ubuntu-bootc
```

bcvk injects an SSH key via systemd SMBIOS credentials (`tmpfiles.extra`), so no password or cloud-init datasource is needed for SSH access.

### Managing the VM

```bash
# List running VMs
bcvk libvirt list

# Stop the VM
bcvk libvirt stop ubuntu-bootc

# Remove the VM and its disk
bcvk libvirt rm ubuntu-bootc
```

## Converting a Running Ubuntu 26.04 VM

You can also convert an existing Ubuntu 26.04 VM in-place to a bootc-managed system. All commands below should be run as root (`sudo -i` or prefix with `sudo`).

### 1. Install podman

```bash
apt update && apt install -y podman
```

### 2. Pull the image

```bash
podman pull ghcr.io/jmarrero/ubuntu-bootc:latest
```

### 3. Enable ext4 verity and unmount /boot

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

```bash
ESP_PART=$(lsblk -nlo NAME,PARTTYPE /dev/vda | grep -i c12a7328 | grep -o 'vda[0-9]*' | grep -o '[0-9]*')
efibootmgr --create --disk /dev/vda --part "${ESP_PART}" \
  --label "Linux Boot Manager" \
  --loader "\EFI\systemd\systemd-bootx64.efi"
NEW=$(efibootmgr | grep "Linux Boot Manager" | head -1 | sed 's/Boot\([0-9A-F]*\).*/\1/')
OLD=$(efibootmgr | grep "Ubuntu" | head -1 | sed 's/Boot\([0-9A-F]*\).*/\1/')
efibootmgr --bootorder "${NEW},${OLD}"
```

### 6. Reboot

```bash
reboot
```

## Building the Image

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

## Cloud-Init Behavior

Cloud-init is included but configured to be **generator-controlled**: the `cloud-init-generator` runs `ds-identify` at early boot to detect available datasources. If no datasource is found (e.g. when running locally with bcvk), cloud-init disables itself and boot continues normally without blocking.

This differs from the [ubuntu-bootc](https://github.com/jmarrero/ubuntu-bootc) base image, which force-enables `cloud-init.target` in `default.target.wants` and will block boot when no datasource is present.

When a cloud datasource is available (EC2, GCE, OpenStack, NoCloud, etc.), cloud-init runs normally and handles user creation, SSH key injection, and instance configuration.

## Snap Compatibility

This image replaces the standard ostree symlinks (`/home`, `/root`, `/opt`, `/mnt`, `/srv`) with real directories backed by systemd bind mount units. This is required because `snap-confine` cannot rbind-mount through symlinks on composefs. A `snap.mount` unit also bind-mounts `/var/lib/snapd/snap` onto `/snap`.

## Known Issues

### Why not the stock Ubuntu 26.04 kernel and base image?

- **PAX tar headers (composefs-rs bug):** Ubuntu 26.04 is the first release built with Canonical's Rockcraft/umoci tooling, which produces PAX format tars. composefs-rs cannot round-trip these, causing `Layer has incorrect checksum` during install. This image uses a [squashed base image](https://github.com/jmarrero/ubuntu-resolute-squashed) that strips PAX headers. ([composefs-rs#290](https://github.com/composefs/composefs-rs/issues/290))
- **Linux 7.0 fsverity regression (kernel bug):** Ubuntu 26.04 ships kernel 7.0 which has a regression breaking composefs boot with `Failed to execute /sbin/init`. This image uses kernel 6.17 from Ubuntu 25.10 (questing) as a workaround. ([bootc#2174](https://github.com/bootc-dev/bootc/issues/2174))

### Secure boot

The kernel 6.17 from Ubuntu 25.10 (questing) is not signed for secure boot. When using bcvk, pass `--firmware uefi-insecure` to disable secure boot. This is only needed until the fsverity regression is fixed in a future Ubuntu kernel.

### Other issues

- **EFI boot order:** `bootc install to-existing-root` does not update EFI variables (runs in a container). You must manually create a systemd-boot EFI entry and update the boot order after install.
- **arm64:** Disabled in CI pending [bootc#1703](https://github.com/bootc-dev/bootc/issues/1703) and [composefs-rs#210](https://github.com/containers/composefs-rs/pull/210)

## Acknowledgments

This project was co-authored with [OpenCode](https://opencode.ai/) (Claude Opus 4.6), which assisted with Containerfile development, upstream bug investigation, PAX tar header analysis, kernel regression diagnosis, and documentation.

## License

Apache License, Version 2.0
