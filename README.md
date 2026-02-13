Select the image for your arch, will be done with a manifest once these get sorted: https://github.com/bootc-dev/bootc/issues/1703 & https://github.com/containers/composefs-rs/pull/210

From the liveISO close the installer and open a terminal.
```
sudo apt-get update && sudo apt-get install podman -y
```
```
nano -w pubkey
```
Add your key


```
cat <<EOF > /tmp/force-vfs.conf
[storage]
driver = "vfs"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
EOF
```

```
mkdir -p /tmp/bootc-storage
```

```
sudo podman run --pid=host --privileged --rm \
  -v /dev:/dev   -v /tmp/bootc-storage:/var/lib/containers \
  -v /tmp/force-vfs.conf:/etc/containers/storage.conf:ro \
  -v /home/ubuntu/pubkey:/id_rsa.pub:ro  \
  --tmpfs /run/containers/storage:rw,mode=0755  \
  ghcr.io/jmarrero/ubuntu-bootc:latest \
  bootc install to-disk \
  --source-imgref docker://ghcr.io/jmarrero/ubuntu-bootc:latest \
  --root-ssh-authorized-keys /id_rsa.pub --composefs-backend --wipe \
  --filesystem ext4 --bootloader systemd /dev/vda
```
