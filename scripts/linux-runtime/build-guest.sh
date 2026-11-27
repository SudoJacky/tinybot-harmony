#!/usr/bin/env bash
# Build an offline, read-only aarch64 Alpine image on x86_64 Linux.
set -euo pipefail
if (( EUID != 0 )); then
  echo 'Build the guest as root in a Linux build container or with sudo to preserve APK file ownership.' >&2
  exit 1
fi
here=$(cd "$(dirname "$0")" && pwd)
out="$here/../../entry/src/main/resources/rawfile/linux"
b=$(mktemp -d)
trap 'rm -rf -- "$b"' EXIT
mkdir -p "$out" "$b/root" "$b/keys"
cd "$b"
main=https://dl-cdn.alpinelinux.org/alpine/v3.22/main
curl -fsSL --retry 2 "$main/x86_64/apk-tools-static-2.14.13-r0.apk" -o apk.tar.gz
curl -fsSL --retry 2 "$main/aarch64/alpine-keys-2.5-r0.apk" -o keys.tar.gz
echo 'd78d2a9ebadc8179b3b9063c3316e948f594c833db51eaeabe67f1d044245527  apk.tar.gz
2e4c85ae16cabeb53b4145006f883bf8e57d454bd3faff14d35ec7d8a0d05b1a  keys.tar.gz' | sha256sum -c -
tar -xzf apk.tar.gz sbin/apk.static
tar -xzf keys.tar.gz etc/apk/keys
./sbin/apk.static --root "$b/root" --arch aarch64 --keys-dir "$b/etc/apk/keys" --repository "$main" --no-cache --no-scripts --initdb add alpine-baselayout-data musl busybox python3 sqlite e2fsprogs ncurses-terminfo-base
# Shell identity comes from the user namespace. Keep password login locked.
sed -i 's/^root:[^:]*:/root:!:/' root/etc/shadow
grep -q '^root:!:' root/etc/shadow
mkdir -p root/{dev/pts,proc,sys,work,tmp,run}
while IFS= read -r applet; do
  mkdir -p "root/$(dirname "$applet")"
  if [[ ! -e "root/$applet" && ! -L "root/$applet" ]]; then ln -s /bin/busybox "root/$applet"; fi
done < root/etc/busybox-paths.d/busybox
install -m 0755 "$here/guest-init" root/linux-init
install -m 0644 "$here/guest-job.py" root/linux_job.py
install -m 0644 "$here/guest-shell-task.py" root/linux_shell_task.py
install -m 0644 "$here/guest-console.py" root/linux-console.py
truncate -s 160M root.ext4
mke2fs -q -F -t ext4 -d root -E root_owner=0:0 root.ext4
qemu-img convert -f raw -O qcow2 -c root.ext4 root.qcow2
kernel_sha=914e3d790e191c17e7e1a845418c1deaede5bff318eb69754382f6deadd156f5
if [[ ! -f "$out/kernel" ]] || ! echo "$kernel_sha  $out/kernel" | sha256sum --check --status; then
  curl -fsSL --retry 2 https://github.com/harmoninux/linux-config/releases/download/kernel-20260228/kernel_aarch64 -o kernel
  echo "$kernel_sha  kernel" | sha256sum -c -
  install -m 0644 kernel "$out/kernel"
fi
install -m 0644 root.qcow2 "$out/root-v5-shell.qcow2"
sha256sum "$out/root-v5-shell.qcow2" "$out/kernel"
