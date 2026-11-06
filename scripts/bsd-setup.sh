#!/bin/sh
# Installs what test-llvm.sh needs inside a FreeBSD/NetBSD/OpenBSD VM and puts GNU-named
# helpers (tar with xz, timeout, python3) in ~/gnubin.
set -x
mkdir -p "$HOME/gnubin"
case "$(uname -s)" in
  FreeBSD) sudo pkg install -y bash curl python3 unzip coreutils
           # 32-bit compat libraries for x86 builds (the VM image ships without lib32)
           if [ ! -e /usr/lib32/libm.so.5 ]; then
             r=$(freebsd-version -u | sed 's/-p[0-9]*$//')
             curl -fsSL "https://download.freebsd.org/releases/amd64/$r/lib32.txz" | sudo tar -xpf - -C /
           fi
           # foreign FreeBSD builds (arm) run through qemu's bsd-user emulator via binmiscctl
           case "${T:-}" in arm-*|armv7-*)
             sudo pkg install -y qemu-user-static && sudo service qemu_user_static onestart ;;
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
