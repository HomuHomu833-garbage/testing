#!/usr/bin/env bash
# x32-vm.sh RELEASE TRIPLE: runs test-llvm.sh for an x32 build inside a Debian VM (KVM) whose
# kernel is booted with syscall.x32=y (Debian builds x32 support in but leaves it off by default).
# Needs: qemu-system-x86 cloud-image-utils openssh-client, and /dev/kvm.
set -euo pipefail
REL=$1 T=$2
D="${RUNNER_TEMP:-/tmp}/x32vm"; mkdir -p "$D"; cd "$D"
img=debian-13-generic-amd64.qcow2
[ -f base.qcow2 ] || curl -fsSL -o base.qcow2 "https://cloud.debian.org/images/cloud/trixie/latest/$img"
qemu-img create -q -f qcow2 -F qcow2 -b base.qcow2 disk.qcow2 40G
rm -f key key.pub; ssh-keygen -q -t ed25519 -N '' -f key
cat > user-data <<UD
#cloud-config
users:
  - name: t
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys: [ "$(cat key.pub)" ]
growpart: { mode: auto, devices: ['/'] }
runcmd:
  - sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/&syscall.x32=y /' /etc/default/grub
  - update-grub
  - DEBIAN_FRONTEND=noninteractive apt-get update -q
  - DEBIAN_FRONTEND=noninteractive apt-get install -yq curl python3 unzip xz-utils binutils
  - touch /var/lib/x32-ready
power_state: { mode: reboot, condition: true }
UD
printf 'instance-id: x32\nlocal-hostname: x32\n' > meta-data
cloud-localds seed.iso user-data meta-data
qemu-system-x86_64 -enable-kvm -cpu host -smp "$(nproc)" -m 12G -nographic -serial file:console.log \
  -drive file=disk.qcow2,if=virtio -drive file=seed.iso,if=virtio,format=raw \
  -netdev user,id=n,hostfwd=tcp::2222-:22 -device virtio-net,netdev=n -daemonize -pidfile qemu.pid
S=(ssh -i key -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR t@localhost)
# wait for the second boot (after cloud-init's reboot) with x32 enabled
for i in $(seq 1 120); do
  if "${S[@]}" 'test -f /var/lib/x32-ready && grep -q syscall.x32=y /proc/cmdline' 2>/dev/null; then break; fi
  sleep 10
done
"${S[@]}" 'cat /proc/cmdline; uname -a'
scp -i key -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -r "$GITHUB_WORKSPACE/scripts" t@localhost:
rc=0
"${S[@]}" "cd scripts && REPO='$REPO' PRUNE_ARCHIVES=1 WORK=\$HOME/w ./test-llvm.sh '$REL' '-$REL-$T.tar'" || rc=$?
mkdir -p "${RUNNER_TEMP:-/tmp}/w"
scp -i key -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR 't@localhost:w/results-*.txt' "${RUNNER_TEMP:-/tmp}/w/" || true
kill "$(cat qemu.pid)" 2>/dev/null || true
exit $rc
