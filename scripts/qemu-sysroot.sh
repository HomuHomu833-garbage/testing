#!/usr/bin/env bash
# qemu-sysroot.sh QEMU_ARCH SYSROOT: re-register the binfmt entry for QEMU_ARCH
# through a wrapper that runs qemu with -L SYSROOT. QEMU_LD_PREFIX only reaches the
# first process; clang starts its children with a scrubbed environment.
set -eu
a=$1 sr=$2
conf=/usr/lib/binfmt.d/qemu-$a.conf
[ -f "$conf" ] || exit 0
q=$(command -v "qemu-$a" || command -v "qemu-$a-static")
w=/usr/local/libexec/qemu-sysroot/$a
sudo mkdir -p "${w%/*}"
cat > "$RUNNER_TEMP/qw-$a.c" <<EOF
#include <unistd.h>
#include <stdlib.h>
/* binfmt flags OP: argv = wrapper, path, original argv[0], args... */
int main(int argc, char **argv) {
  char **v = calloc(argc + 6, sizeof *v); int n = 0;
  v[n++] = "$q"; v[n++] = "-L"; v[n++] = "$sr"; v[n++] = "-0"; v[n++] = argv[2]; v[n++] = argv[1];
  for (int i = 3; i < argc; i++) v[n++] = argv[i];
  execv(v[0], v); return 127;
}
EOF
cc -O2 -static -o "$RUNNER_TEMP/qw-$a" "$RUNNER_TEMP/qw-$a.c" 2>/dev/null || cc -O2 -o "$RUNNER_TEMP/qw-$a" "$RUNNER_TEMP/qw-$a.c"
sudo install -m755 "$RUNNER_TEMP/qw-$a" "$w"
name=$(cut -d: -f2 "$conf")
[ -e "/proc/sys/fs/binfmt_misc/$name" ] && echo -1 | sudo tee "/proc/sys/fs/binfmt_misc/$name" >/dev/null
awk -F: -v OFS=: -v w="$w" '{$7=w; $8="OPF"; print}' "$conf" | sudo tee /proc/sys/fs/binfmt_misc/register >/dev/null
