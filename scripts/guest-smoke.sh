#!/bin/sh
# guest-smoke.sh RELEASE TRIPLE: the test-llvm.sh checks that need only a POSIX sh and base tools,
# for guests without bash/python/curl (e.g. NetBSD riscv32, armeb). Downloads with ftp(1) or curl,
# lays our bin/ over Google's toolchain, then compiles and links for every Android target and runs
# every binary once. Results go to $WORK/results-RELEASE.txt in test-llvm.sh's format.
REL=$1 T=$2
REPO=${REPO:-HomuHomu833/llvm-custom}
WORK=${WORK:-$HOME/w}
TAG=llvm-$(echo "$REL" | sed 's/[^r0-9].*//')
mkdir -p "$WORK/dl" "$WORK/run"; cd "$WORK" || exit 1
RES="$WORK/results-$REL.txt"; : > "$RES"
CUR="$REL-$T"; ok=0; fail=0
log()  { echo "$1" | tee -a "$RES"; }
pass() { log "OK    [$CUR] $1"; ok=$((ok+1)); }
bad()  { log "FAIL  [$CUR] $1 :: $(echo "$2" | tr '\n' ' ' | cut -c1-400)"; fail=$((fail+1)); }
step() { l=$1; shift; o=$("$@" 2>&1); r=$?; if [ $r -eq 0 ]; then pass "$l"; else bad "$l (rc=$r)" "$o"; fi; return $r; }
expect() { l=$1; pat=$2; shift 2; o=$("$@" 2>&1); r=$?
  if [ $r -eq 0 ] && echo "$o" | grep -qE -- "$pat"; then pass "$l"; else bad "$l (rc=$r, wanted /$pat/)" "$o"; fi; }
get() { if command -v curl >/dev/null; then curl -fsSL -o "$2" "$1"; else ftp -V -o "$2" "$1"; fi; }

asset="bolt+clang+clang-tools-extra+lld+polly-$REL-$T.tar.xz"
[ -f "dl/$asset" ] || get "https://github.com/$REPO/releases/download/$TAG/$(echo "$asset" | sed 's/+/%2B/g')" "dl/$asset" \
  || { bad "download $asset" ""; exit 1; }
z=dl/ndk.zip
[ -f $z ] || get "https://dl.google.com/android/repository/android-ndk-$REL-linux.zip" $z \
  || get "https://dl.google.com/android/repository/android-ndk-$REL-linux-x86_64.zip" $z || { bad "download official NDK" ""; exit 1; }
rm -rf x base; mkdir -p x base
xz -dc "dl/$asset" | tar -xf - -C x || { bad "extract our toolchain" ""; exit 1; }
unzip -qo $z '*/toolchains/llvm/prebuilt/linux-x86_64/*' -d base >/dev/null || { bad "extract official NDK" ""; exit 1; }
TC=$(echo base/*/toolchains/llvm/prebuilt/linux-x86_64); OURS=$(echo x/*)
rm -rf "$TC/bin"; cp -R "$OURS/bin" "$TC/bin"
G=$(ls -d "$TC"/lib64/clang/*/ "$TC"/lib/clang/*/ 2>/dev/null | head -n1)
for rd in "$OURS"/lib/clang/*/; do
  v=$(basename "$rd"); [ -d "$TC/lib/clang/$v" ] || { mkdir -p "$TC/lib/clang"; cp -R "$rd" "$TC/lib/clang/$v"; }
  [ -n "$G" ] && [ -d "$G/lib" ] && { mkdir -p "$TC/lib/clang/$v/lib"; (cd "$G/lib" && tar -cf - .) | (cd "$TC/lib/clang/$v/lib" && tar -xkf - 2>/dev/null); }
done
L="$PWD/$TC/bin"; cd run || exit 1
printf '#include <stdio.h>\nint main(void){printf("hello %%d\\n",6*7);return 0;}\n' > hello.c
printf '#include <iostream>\n#include <vector>\n#include <stdexcept>\nint main(){std::vector<int> v{1,2};try{throw std::runtime_error("boom");}catch(const std::exception&e){std::cout<<e.what()<<v.size()<<"\\n";}}\n' > hello.cpp
printf 'int  main( ){return 0;}' > fmt.c

expect "clang --version" "clang version" "$L/clang" --version
expect "ld.lld --version" "LLD" "$L/ld.lld" --version
expect "llvm-cxxfilt" 'foo\(\)' "$L/llvm-cxxfilt" _Z3foov
expect "clang-format" 'int main\(\) \{ return 0; \}' "$L/clang-format" fmt.c
for t in aarch64-linux-android30 armv7a-linux-androideabi29 i686-linux-android21 x86_64-linux-android21; do
  a=${t%%-*}
  step "[$a] compile+link C (static)" "$L/clang" --target=$t -O2 -static hello.c -o "c_$a"
  step "[$a] compile+link C++ (static, libc++)" "$L/clang++" --target=$t -O2 -static hello.cpp -o "cpp_$a"
  step "[$a] compile+link C with ThinLTO" "$L/clang" --target=$t -O2 -flto=thin -static hello.c -o "lto_$a"
  step "[$a] link shared lib" "$L/clang" --target=$t -shared -fPIC hello.c -o "lib_$a.so"
done
if step "clang -c -g (aarch64 object)" "$L/clang" --target=aarch64-linux-android29 -g -c hello.c -o h.o; then
  expect "llvm-objdump -d" "aarch64" "$L/llvm-objdump" -d h.o
  expect "llvm-nm" " T main" "$L/llvm-nm" h.o
  step "llvm-ar rcs" "$L/llvm-ar" rcs libh.a h.o
  expect "llvm-dwarfdump" "DW_TAG_subprogram" "$L/llvm-dwarfdump" h.o
fi
for f in "$L"/*; do
  [ -f "$f" ] || continue
  case $(basename "$f") in clang|clang++|ld.lld|llvm-cxxfilt|clang-format|*.so|*.a) continue ;; esac
  head -c 4 "$f" | grep -q ELF || continue
  o=$("$f" --help </dev/null 2>&1); r=$?
  if [ $r -ge 126 ]; then bad "smoke $(basename "$f") (rc=$r)" "$o"; else pass "smoke $(basename "$f") (rc=$r)"; fi
done
echo; echo "OK=$ok  FAIL=$fail"
[ $fail -eq 0 ]
