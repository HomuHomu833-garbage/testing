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
  - DEBIAN_FRONTEND=noninteractive apt-get install -yq curl python3 unzip xz-utils binutils libc6-x32 libstdc++6-x32-cross || DEBIAN_FRONTEND=noninteractive apt-get install -yq curl python3 unzip xz-utils binutils libc6-x32
  - touch /var/lib/x32-ready
power_state: { mode: reboot, condition: true }
UD
printf 'instance-id: x32\nlocal-hostname: x32\n' > meta-data
cloud-localds seed.iso user-data meta-data
qemu-system-x86_64 -enable-kvm -cpu host -smp "$(nproc)" -m 12G -display none -serial file:console.log \
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
if [ "$rc" != 0 ]; then
  "${S[@]}" "REPO='$REPO' bash -s" <<'DIAG' || true
sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq gdb >/dev/null 2>&1
mkdir -p ~/dg && cd ~/dg
curl -fsSL -o a.tar.xz "https://github.com/$REPO/releases/download/llvm-r30/bolt%2Bclang%2Bclang-tools-extra%2Blld%2Bpolly-r30-x86_64-linux-gnux32.tar.xz" && tar xf a.tar.xz
b=$(dirname "$(find ~/dg -name lld -type f | head -1)"); echo "bin=$b"
cd "$(mktemp -d)"; echo 'int main(){return 0;}' > t.c
file "$b/lld" | cut -c1-200
N=$(find ~/w/base -path '*prebuilt/linux-x86_64/sysroot' | head -1); echo "ndk sysroot=$N"
g=$(ls -d "$(dirname "$N")"/lib/clang/*/ | head -1); v=$(basename "$(ls -d "$b"/../lib/clang/*/ | head -1)")
mkdir -p "$b/../lib/clang/$v/lib"; (cd "$g/lib" && tar -cf - .) | (cd "$b/../lib/clang/$v/lib" && tar -xkf - 2>/dev/null)
"$b/clang" --target=x86_64-linux-android21 --sysroot="$N" -static -save-temps -c t.c -o t.o 2>&1 | tail -2
"$b/clang" --target=x86_64-linux-android21 --sysroot="$N" -static -### t.o 2>&1 | tail -1 > cmd
for th in default 1; do
  echo "== threads=$th"; extra=; [ $th = 1 ] && extra=-Wl,--threads=1
  "$b/clang" --target=x86_64-linux-android21 --sysroot="$N" -static $extra t.c -o t 2>&1 | head -3; echo "rc=${PIPESTATUS[0]}"
done
eval "set -- $(sed 's/^ *//' cmd)"; echo "link cmd: $*" | cut -c1-400
gdb -batch -ex run -ex 'x/4i $pc' -ex 'info registers' -ex 'p $_siginfo._sifields._sigfault.si_addr' -ex 'p/x $fs_base' -ex 'x/6wx $fs_base' -ex 'info proc mappings' --args "$@" 2>&1 | tail -90
DIAG
fi
mkdir -p "${RUNNER_TEMP:-/tmp}/w"
scp -i key -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR 't@localhost:w/results-*.txt' "${RUNNER_TEMP:-/tmp}/w/" || true
kill "$(cat qemu.pid)" 2>/dev/null || true
exit $rc
