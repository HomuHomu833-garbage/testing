#!/bin/sh
# Installs what test-llvm.sh needs inside a FreeBSD/NetBSD/OpenBSD VM and puts GNU-named
# helpers (tar with xz, timeout, python3) in ~/gnubin.
set -x
mkdir -p "$HOME/gnubin"
case "$(uname -s)" in
  FreeBSD) sudo pkg install -y bash curl python3 unzip coreutils
           # 32-bit compat libraries for x86 builds (the VM image ships without lib32)
           # (unpacked aside: extracting the set over / resets its mode and sshd then refuses logins)
           case "${T:-}" in x86-*) if [ ! -e /usr/lib32/libm.so.5 ]; then
             r=$(freebsd-version -u | sed 's/-p[0-9]*$//'); mkdir -p "$HOME/l32"
             curl -fsSL "https://download.freebsd.org/releases/amd64/$r/lib32.txz" | tar -xf - -C "$HOME/l32" ./usr/lib32 ./libexec/ld-elf32.so.1
             sudo cp -Rp "$HOME/l32/usr/lib32" /usr/; sudo cp -p "$HOME/l32/libexec/ld-elf32.so.1" /libexec/
           fi ;; esac
           # foreign FreeBSD builds (arm) run through qemu's bsd-user emulator via binmiscctl
           case "${T:-}" in arm-*|armv7-*)
             sudo pkg install -y qemu-user-static && sudo service qemu_user_static onestart
             # the emulator loads the arm program's ld-elf.so.1 and libs from its prefix. FreeBSD ships
             # armv7 only as an SD card image: mount its root and copy the runtime parts.
             r=$(freebsd-version -u | sed 's/-p[0-9]*$//'); v=${r%-RELEASE}
             curl -fsSL "https://download.freebsd.org/releases/arm/armv7/ISO-IMAGES/$v/FreeBSD-$r-arm-armv7-GENERICSD.img.xz" | xz -dc > "$HOME/armv7.img"
             md=$(sudo mdconfig -a -t vnode -f "$HOME/armv7.img"); sudo mkdir -p /mnt/a
             sudo mount -o ro "/dev/${md}s2a" /mnt/a || sudo mount -o ro "/dev/${md}p2" /mnt/a
             sudo mkdir -p /usr/gnemul/qemu-arm/usr
             (cd /mnt/a && sudo tar -cf - lib libexec usr/lib usr/libexec) | (cd /usr/gnemul/qemu-arm && sudo tar -xpf -)
             sudo umount /mnt/a; sudo mdconfig -d -u "$md"; rm -f "$HOME/armv7.img" ;;
           esac ;;
  NetBSD)  sudo pkgin -y install bash curl python311 unzip coreutils gtar xz || sudo pkgin -y install bash curl python312 unzip coreutils gtar xz
           # 32-bit compat for x86 builds: kernel module and the base32 set
           if [ "$(uname -m)" = amd64 ]; then
             sudo modload compat_netbsd32 2>/dev/null || true
             if [ ! -e /usr/lib/i386/libc.so ]; then
               r=$(uname -r)
               curl -fsSL "https://cdn.netbsd.org/pub/NetBSD/NetBSD-$r/amd64/binary/sets/base32.tar.xz" | sudo tar -xJpf - -C / \
                 || curl -fsSL "https://cdn.netbsd.org/pub/NetBSD/NetBSD-$r/amd64/binary/sets/base32.tgz" | sudo tar -xzpf - -C /
             fi
           fi ;;
  OpenBSD) sudo pkg_add -I bash curl python%3 unzip-- coreutils gtar-- xz ;;
esac
for d in /usr/local/bin /usr/pkg/bin; do
  [ -x "$d/gtimeout" ] && ln -sf "$d/gtimeout" "$HOME/gnubin/timeout"
  [ -x "$d/gtar" ] && ln -sf "$d/gtar" "$HOME/gnubin/tar"
  for p in "$d"/python3.*; do case $p in *-config) ;; *) [ -x "$p" ] && ln -sf "$p" "$HOME/gnubin/python3" ;; esac; done
done
command -v timeout >/dev/null || ls "$HOME/gnubin"
