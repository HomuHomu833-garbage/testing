#!/bin/sh
# Replace Ubuntu's qemu-user 8.2 with Debian forky's static qemu 11. 8.2 gets AT_PHDR wrong
# when the first PT_LOAD does not hold the headers (zig's sparc64 linker), and before 11 a
# hexagon dot-new predicate jump fires on any set bit instead of bit 0.
set -e
v=$(curl -fsSL --retry 5 https://deb.debian.org/debian/dists/forky/main/binary-$(dpkg --print-architecture)/Packages.xz \
    | xz -dc | awk '/^Package: qemu-user$/{p=1} p&&/^Filename:/{print $2; exit}')
curl -fsSL --retry 5 -o /tmp/qu.deb "https://deb.debian.org/debian/$v"
dpkg-deb -x /tmp/qu.deb /tmp/qu
sudo cp -f /tmp/qu/usr/bin/qemu-* /usr/bin/
qemu-hexagon --version | head -1
