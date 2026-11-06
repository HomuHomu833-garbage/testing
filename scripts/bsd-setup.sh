#!/bin/sh
# Installs what test-llvm.sh needs inside a FreeBSD/NetBSD/OpenBSD VM and puts GNU-named
# helpers (tar with xz, timeout, python3) in ~/gnubin.
set -x
mkdir -p "$HOME/gnubin"
case "$(uname -s)" in
  FreeBSD) sudo pkg install -y bash curl python3 unzip coreutils ;;
  NetBSD)  sudo pkgin -y install bash curl python311 unzip coreutils gtar xz || sudo pkgin -y install bash curl python312 unzip coreutils gtar xz ;;
  OpenBSD) sudo pkg_add -I bash curl python%3 unzip-- coreutils gtar-- xz ;;
esac
for d in /usr/local/bin /usr/pkg/bin; do
  [ -x "$d/gtimeout" ] && ln -sf "$d/gtimeout" "$HOME/gnubin/timeout"
  [ -x "$d/gtar" ] && ln -sf "$d/gtar" "$HOME/gnubin/tar"
  for p in "$d"/python3.*; do case $p in *-config) ;; *) [ -x "$p" ] && ln -sf "$p" "$HOME/gnubin/python3" ;; esac; done
done
command -v timeout >/dev/null || ls "$HOME/gnubin"
