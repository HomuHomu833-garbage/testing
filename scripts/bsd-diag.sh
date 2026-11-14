#!/usr/bin/env bash
# bsd-diag.sh: after a failing run, re-fetch the toolchain and print a gdb trace of the
# riscv64 driver crash (x86-netbsd).
set -x
d=$HOME/dg; mkdir -p "$d" && cd "$d" || exit 0
a="bolt%2Bclang%2Bclang-tools-extra%2Blld%2Bpolly-$REL-$T.tar.xz"
curl -fsSL -o a.tar.xz "https://github.com/$REPO/releases/download/llvm-${REL%%[!r0-9]*}/$a" && tar -xf a.tar.xz || exit 0
b=$(dirname "$(find "$d" -name clang -path '*/bin/*' | head -1)")
uname -a; ulimit -a
for t in riscv64-linux-android37 aarch64-linux-android29 x86_64-linux-android21; do
  echo "== $t"; "$b/clang" --target=$t -### -c -x c /dev/null -o /dev/null 2>&1 | tail -3; echo "rc=$?"
done
sudo pkgin -y install gdb >/dev/null 2>&1
f=$(ls "$b"/clang-[0-9]* | head -1)
N=$(find "$HOME/w/base" -type d -path '*prebuilt/linux-x86_64/sysroot' 2>/dev/null | head -1); echo "ndk sysroot=$N"
echo 'int main(){return 0;}' > t.c
for t in riscv64-linux-android37 aarch64-linux-android29; do for x in "" -static; do
  echo "== sysroot $t $x"; timeout 120 "$b/clang" --target=$t --sysroot="$N" $x -### t.c -o t 2>&1 | tail -3; echo "rc=${PIPESTATUS[0]}"
done; done
command -v gdb && timeout 900 gdb -batch -ex run -ex 'bt 40' -ex 'x/4i $pc' -ex 'info registers' --args "$f" --target=riscv64-linux-android37 --sysroot="$N" -static -### t.c -o t 2>&1 | tail -70
