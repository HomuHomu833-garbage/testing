#!/usr/bin/env bash
# arm-fbsd-diag.sh: count r21 arm-freebsd link hangs with and without lld threads.
d=$HOME/ad; mkdir -p "$d" && cd "$d" || exit 0
a="bolt%2Bclang%2Bclang-tools-extra%2Blld%2Bpolly-$REL-$T.tar.xz"
curl -fsSL -o a.tar.xz "https://github.com/$REPO/releases/download/llvm-${REL%%[!r0-9]*}/$a" && tar -xf a.tar.xz || exit 0
b=$(dirname "$(find "$d" -name clang -path '*/bin/*' | head -1)")
printf 'int main(){return 0;}\n' > t.c
"$b/clang" --target=x86_64-linux-android21 -c t.c -o t.o || exit 0
for m in default "-Wl,--threads=1"; do
  h=0
  for i in $(seq 15); do
    x=""; [ "$m" = default ] || x="$m"
    timeout 120 "$b/clang" --target=x86_64-linux-android21 -fuse-ld=lld $x t.o -o t >/dev/null 2>&1
    [ $? = 124 ] && h=$((h+1))
  done
  echo "lld $m: $h/15 hung"
done
h=0
for i in $(seq 15); do timeout 120 "$b/clang" --target=x86_64-linux-android21 -c t.c -o t.o >/dev/null 2>&1; [ $? = 124 ] && h=$((h+1)); done
echo "clang -c: $h/15 hung"
