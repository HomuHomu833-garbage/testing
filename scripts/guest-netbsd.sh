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
case $T in
  riscv64-netbsd-none)   port=riscv-riscv64;    img=riscv64.img; kern=netbsd-GENERIC64;  pk=riscv64
    Q=(qemu-system-riscv64 -M virt -cpu rv64 -smp 4 -m 4G); BUS=device ;;
  riscv32-netbsd-none)   port=riscv-riscv32;    img=riscv32.img; kern=netbsd-GENERIC;    pk=""
    Q=(qemu-system-riscv32 -M virt -smp 4 -m 2G); BUS=device ;;
  arm-netbsd-eabihf)     port=evbarm-earmv7hf;  img=armv7.img;   kern=netbsd-GENERIC;    pk=earmv7hf
    Q=(qemu-system-arm -M virt,highmem=off -cpu cortex-a15 -smp 4 -m 3G); BUS=device ;;
  armeb-netbsd-eabihf)   port=evbarm-earmv7hfeb; img=armv7.img;  kern=netbsd-GENERIC;    pk=""
    Q=(qemu-system-arm -M virt,highmem=off -cpu cortex-a15 -smp 4 -m 3G); BUS=device ;;
  aarch64_be-netbsd-none) port=evbarm-aarch64eb; img=arm64.img;  kern=netbsd-GENERIC64.img; pk=aarch64eb
    Q=(qemu-system-aarch64 -M virt -cpu cortex-a57 -smp 4 -m 4G); BUS=device ;;
  *) echo "no NetBSD guest for $T"; exit 2 ;;
esac
cd "$D"
[ -f "$img" ] || curl -fsSL "$B/$port/binary/gzimg/$img.gz" | gunzip > "$img"
[ -f kernel ] || curl -fsSL "$B/$port/binary/kernel/$kern.gz" | gunzip > kernel
truncate -s 64M scripts.img; tar -C "$SRC" -cf - scripts | dd of=scripts.img conv=notrunc status=none
truncate -s 40G work.img; truncate -s 32M results.img; : > results.img; truncate -s 32M results.img

disk() { echo -drive "file=$1,format=raw,if=none,id=$2" -device "virtio-blk-$BUS,drive=$2"; }
# shellcheck disable=SC2046
QEMU=("${Q[@]}" -nographic -kernel kernel -append "root=dk1"
  $(disk "$img" hd0) $(disk scripts.img hd1) $(disk work.img hd2) $(disk results.img hd3)
  -netdev user,id=n0 -device "virtio-net-$BUS,netdev=n0")

# disks by size: scripts 64M = 131072 sectors, work 40G = 83886080, results 32M = 65536
cat > cmds <<EOF
R=\$(sysctl -n kern.rawpartition | awk '{printf "%c", 97+\$1}'); export R
pick() { for d in \$(sysctl -n hw.disknames); do case \$d in ld*) [ "\$(disklabel \$d 2>/dev/null | awk '/total sectors/{print \$3}')" = "\$1" ] && echo \$d;; esac; done; }
SD=\$(pick 131072); WD=\$(pick 83886080); RD=\$(pick 65536); echo "disks: scripts=\$SD work=\$WD results=\$RD"; test -n "\$SD" -a -n "\$WD" -a -n "\$RD"
mkdir -p /t /w && tar -xf /dev/r\${SD}\$R -C /t
newfs -q /dev/r\${WD}\$R >/dev/null && mount -o async /dev/\${WD}\$R /w
-dhcpcd -w -q 2>/dev/null; ifconfig -a | grep -E 'inet ' ; route -n get default | grep gateway
EOF
if [ -n "$pk" ]; then
  cat >> cmds <<EOF
PKG_PATH=http://cdn.netbsd.org/pub/pkgsrc/packages/NetBSD/$pk/$V/All; export PKG_PATH; pkg_add bash curl unzip coreutils gtar xz mozilla-rootcerts-openssl 2>&1 | tail -3; pkg_add python311 2>&1 | tail -2 || pkg_add python312 2>&1 | tail -2
mkdir -p /root/gnubin && for x in /usr/pkg/bin/python3.1[0-9]; do ln -sf \$x /root/gnubin/python3; done; ln -sf /usr/pkg/bin/gtimeout /root/gnubin/timeout; ln -sf /usr/pkg/bin/gtar /root/gnubin/tar; PATH=/root/gnubin:/usr/pkg/bin:\$PATH; export PATH; python3 -V
-cd /t/scripts && HOST_OS=netbsd REPO='$REPO' WORK=/w PRUNE_ARCHIVES=1 TIMEOUT=900 bash ./test-llvm.sh '$REL' '-$REL-$T.tar' > /w/out.log 2>&1; tail -n 4 /w/out.log
EOF
else
  cat >> cmds <<EOF
-cd /t/scripts && REPO='$REPO' WORK=/w ./guest-smoke.sh '$REL' '$T' > /w/out.log 2>&1; tail -n 4 /w/out.log
EOF
fi
cat >> cmds <<EOF
cd /w && tar -cf /dev/r\${RD}\$R results-*.txt out.log
EOF
rc=0
BOOT_TIMEOUT=5400 python3 "$SRC/scripts/guest.py" console.log cmds -- "${QEMU[@]}" || rc=$?
mkdir -p "${RUNNER_TEMP:-/tmp}/w"
tar -xf results.img -C "${RUNNER_TEMP:-/tmp}/w" 2>/dev/null || echo "no results came back from the guest"
tail -n 30 console.log | tr -d '\r'
exit $rc
