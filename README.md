# Ubuntu Bootc with Cloud-Init

An example [Ubuntu](https://ubuntu.com/) bootable container image with [cloud-init](https://cloud-init.io/) built-in, based on the [bootcrew ubuntu-bootc](https://github.com/bootcrew-dev/ubuntu-bootc) project.

This image demonstrates how to build cloud-init support into a [bootc](https://github.com/bootc-dev/bootc) container image, enabling automatic instance configuration on first boot in cloud environments.

## What's Included

- Ubuntu base image with bootc support
- Cloud-init for automatic instance configuration
- Standard bootc tooling and configuration

## Building

To build and run an ubuntu-bootc system with cloud-init:

```shell
just build-containerfile # Build the container image with cloud-init
just generate-bootable-image # Generate a bootable disk image using bootc
```

Then you can run the `bootable.img` as your boot disk in your preferred hypervisor or cloud environment. Cloud-init will automatically configure the instance based on your cloud provider's metadata service or a user-data file.

## Starting from a Ubuntu 25.10 cloud-init enabled VM

This section describes how to convert an existing Ubuntu 25.10 system to Ubuntu bootc.

All commands in this guide are expected to be run as root.

### Prerequisites

Install podman:

```bash
sudo apt update
sudo apt install -y podman
```

### Installing the Image

> **Warning:** This is a destructive operation that will replace your current system. Before proceeding:
> - **Back up any important data** - this operation will overwrite the existing system
> - **Ensure you have an SSH key configured for root** - you will need to provide the path to your SSH authorized keys file
> - **Verify network connectivity** - the image will be pulled from the registry

#### Pull the Image

Pull the ubuntu-bootc image first (this also initializes the container storage):

```bash
podman pull ghcr.io/jmarrero/ubuntu-bootc:latest
```

#### Unmount /boot

The bootc install process needs to manage the `/boot` partition itself. Unmount it before proceeding:

```bash
umount /boot/efi 2>/dev/null
umount /boot
```

#### Run the Install

Run the bootc install directly using podman:

```bash
podman run --privileged --pid=host --user=root:root \
    -v /var/lib/containers:/var/lib/containers \
    -v /dev:/dev \
    --security-opt label=type:unconfined_t \
    -v /:/target \
    -v /root/.ssh/authorized_keys:/bootc_authorized_ssh_keys/root \
    ghcr.io/jmarrero/ubuntu-bootc:latest \
    bootc install to-existing-root \
    --acknowledge-destructive \
    --skip-fetch-check \
    --composefs-backend \
    --cleanup \
    --root-ssh-authorized-keys /bootc_authorized_ssh_keys/root
```

**Key flags:**

| Flag | Purpose |
|------|---------|
| `--acknowledge-destructive` | Confirms you understand this will overwrite the existing system |
| `--skip-fetch-check` | Skips verification that the image can be fetched (useful when host has registry auth but image doesn't) |
| `--composefs-backend` | Uses the composefs backend instead of ostree for better image storage handling |
| `--cleanup` | Cleans up remnants from the previous Linux installation |
| `--root-ssh-authorized-keys` | Injects SSH keys for root access after reboot |

> **Note:** Adjust the path `/root/.ssh/authorized_keys` to point to your SSH authorized keys file.

After the install completes, reboot the system. You can then SSH into the system as root using your specified key.

For additional options and configuration, see the [bootc install documentation](https://bootc-dev.github.io/bootc/bootc-install.html).
