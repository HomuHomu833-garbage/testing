#!/usr/bin/env bash
# guest-netbsd.sh RELEASE TRIPLE: tests a NetBSD build for a CPU without a GitHub runner in a NetBSD
# guest under qemu-system (TCG). The guest gets 3 extra disks: the scripts (a tar), a scratch disk
# for WORK and one the results are tarred onto. Ports with pkgsrc binary packages run the full
# test-llvm.sh; the others run guest-smoke.sh (base /bin/sh tools only).
# Env: REPO, NBVER (default 11.0), RUNNER_TEMP, GITHUB_WORKSPACE.
set -euo pipefail
REL=$1 T=$2 V=${NBVER:-11.0}
D="${RUNNER_TEMP:-/tmp}/nbguest"; mkdir -p "$D"
SRC="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/.." && pwd)}"
B="https://cdn.netbsd.org/pub/NetBSD/NetBSD-$V"
# qemu's virt boards have no firmware NetBSD can take the root disk from: name it. The armv7
# ELF kernel loads below RAM (qemu then grows without bound), so those boot the u-boot image;
# their virtio disks attach as ld4.. in reverse order, the image (first of 4) as ld7.
root=dk1
case $T in
  riscv64-netbsd-none)   port=riscv-riscv64;    img=riscv64.img; kern=netbsd-GENERIC64;  pk=riscv64
    Q=(qemu-system-riscv64 -M virt -cpu rv64 -smp 4 -m 4G); BUS=device ;;
  riscv32-netbsd-none)   port=riscv-riscv32;    img=riscv32.img; kern=netbsd-GENERIC;    pk=""
    Q=(qemu-system-riscv32 -M virt -smp 4 -m 2G -bios opensbi32.bin); BUS=device ;;
  arm-netbsd-eabihf)     port=evbarm-earmv7hf;  img=armv7.img;   kern=netbsd-GENERIC.ub; root=ld7a;    pk=earmv7hf
    Q=(qemu-system-arm -M virt,highmem=off -cpu cortex-a15 -smp 4 -m 3G); BUS=device ;;
  armeb-netbsd-eabihf)   port=evbarm-earmv7hfeb; img=armv7.img;  kern=netbsd-GENERIC.ub; root=ld7a;    pk=""
    Q=(qemu-system-arm -M virt,highmem=off -cpu cortex-a15 -smp 4 -m 3G); BUS=device ;;
  aarch64_be-netbsd-none) port=evbarm-aarch64eb; img=arm64.img;  kern=netbsd-GENERIC64.img; pk=aarch64eb
    Q=(qemu-system-aarch64 -M virt -cpu cortex-a57 -smp 4 -m 4G); BUS=device ;;
  *) echo "no NetBSD guest for $T"; exit 2 ;;
esac
cd "$D"
dl() { curl -fsSL --retry 8 --retry-all-errors --retry-delay 15 -o "$2.gz" "$1" && gunzip -f "$2.gz"; }
[ -f "$img" ] || { dl "$B/$port/binary/gzimg/$img.gz" "$img" && truncate -s 10G "$img"; }   # root grows on first boot
# Ubuntu's qemu leaves out the riscv32 OpenSBI firmware: take qemu's own
[[ $T != riscv32-* || -f opensbi32.bin ]] || curl -fsSL --retry 5 -o opensbi32.bin \
  "https://raw.githubusercontent.com/qemu/qemu/v$(qemu-system-riscv32 --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)/pc-bios/opensbi-riscv32-generic-fw_dynamic.bin"
[ -f kernel ] || dl "$B/$port/binary/kernel/$kern.gz" kernel
# everything the guest runs goes in scripts/guest-run.sh: the console takes lines of 255 bytes at most
rm -rf stage; mkdir -p stage; cp -R "$SRC/scripts" stage/
{
  echo 'R=$(sysctl -n kern.rawpartition 2>/dev/null | awk '"'"'{printf "%c", 97+$1}'"'"'); [ -n "$R" ] || R=c'
  echo 'pick() { for d in $(sysctl -n hw.disknames | tr , " "); do case $d in ld*|sd*|wd*|vnd*) [ "$(disklabel $d 2>/dev/null | awk '"'"'/total sectors/{print $3}'"'"')" = "$1" ] && echo $d;; esac; done; }'
  echo 'WD=$(pick 83886080); RD=$(pick 65536); echo "disks: work=$WD results=$RD"'
  echo 'newfs -I /dev/r${WD}$R >/dev/null && mkdir -p /w && mount -o async /dev/${WD}$R /w || exit 1'
  echo 'dhcpcd -w -q 2>/dev/null; ifconfig -a | grep "inet "'
  if [ -n "$pk" ]; then
    # the CDN redirects to the current quarterly branch and pkg_add does not follow it
    pu=$(curl -fsSL --retry 5 -o /dev/null -w '%{url_effective}' "https://cdn.netbsd.org/pub/pkgsrc/packages/NetBSD/$pk/$V/All/")
    echo "PKG_PATH=${pu/https:/http:}; export PKG_PATH"
    echo 'grep -q nameserver /etc/resolv.conf 2>/dev/null || echo nameserver 10.0.2.3 > /etc/resolv.conf'
    echo 'for x in bash curl unzip coreutils gtar xz mozilla-rootcerts python311; do pkg_add $x 2>&1 | tail -2; done'
    echo 'mozilla-rootcerts install >/dev/null 2>&1; pkg_info | cut -c1-40'
    echo 'mkdir -p /root/gnubin; for x in /usr/pkg/bin/python3.1[0-9]; do ln -sf $x /root/gnubin/python3; done'
    echo 'ln -sf /usr/pkg/bin/gtimeout /root/gnubin/timeout; ln -sf /usr/pkg/bin/gtar /root/gnubin/tar'
    echo 'PATH=/root/gnubin:/usr/pkg/bin:$PATH; export PATH; python3 -V'
    echo "cd /t/scripts && HOST_OS=netbsd REPO='$REPO' WORK=/w PRUNE_ARCHIVES=1 TIMEOUT=900 bash ./test-llvm.sh '$REL' '-$REL-$T.tar' > /w/out.log 2>&1"
  else
    echo "cd /t/scripts && REPO='$REPO' WORK=/w sh ./guest-smoke.sh '$REL' '$T' > /w/out.log 2>&1"
  fi
  echo 'tail -n 4 /w/out.log; cd /w && tar -cf /dev/r${RD}$R results-*.txt out.log'
} > stage/scripts/guest-run.sh
truncate -s 64M scripts.img; tar -C stage -cf - scripts | dd of=scripts.img conv=notrunc status=none
truncate -s 40G work.img; rm -f results.img; truncate -s 32M results.img

disk() { echo -drive "file=$1,format=raw,if=none,id=$2" -device "virtio-blk-$BUS,drive=$2"; }
# shellcheck disable=SC2046
QEMU=("${Q[@]}" -nographic -no-reboot -kernel kernel -append "root=$root"
  $(disk "$img" hd0) $(disk scripts.img hd1) $(disk work.img hd2) $(disk results.img hd3)
  -netdev user,id=n0 -device "virtio-net-$BUS,netdev=n0")

cat > cmds <<'EOF'
R=$(sysctl -n kern.rawpartition | awk '{printf "%c",97+$1}'); echo raw=$R
for d in $(sysctl -n hw.disknames); do tar -tf /dev/r$d$R 2>/dev/null | grep -q guest-run && S=$d; done; echo scripts=$S
mkdir -p /t && tar -xf /dev/r$S$R -C /t
sh -x /t/scripts/guest-run.sh 2>&1 | tail -n 40
EOF
rc=0
BOOT_TIMEOUT=5400 python3 "$SRC/scripts/guest.py" console.log cmds -- "${QEMU[@]}" || rc=$?
mkdir -p "${RUNNER_TEMP:-/tmp}/w"
tar -xf results.img -C "${RUNNER_TEMP:-/tmp}/w" 2>/dev/null || echo "no results came back from the guest"
tail -n 30 console.log | tr -d '\r'
exit $rc
