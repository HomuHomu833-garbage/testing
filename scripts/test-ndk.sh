#!/usr/bin/env bash
# test-ndk.sh VERSION TRIPLE...: functional test of HomuHomu833/android-ndk-custom builds.
# Builds a JNI project with ndk-build for every ABI, symbolizes a fake tombstone with
# ndk-stack, and exercises make, yasm, python, ndk-which and (r20-r23) binutils.
# Foreign Linux builds run through qemu-user binfmt like test-sdk.sh.
# Env: REPO (default HomuHomu833/android-ndk-custom), WORK, HOST_OS (linux|darwin|bsd|windows),
#      WINE, SR_DIR
set -uo pipefail
REPO="${REPO:-HomuHomu833/android-ndk-custom}"; VER=$1; shift
TAG=${VER%%-*}; TAG=$(sed -E 's/^(r[0-9]+)[a-z]?$/\1/' <<<"$TAG")
WORK="${WORK:-$HOME/ndk-test}"; HOST_OS="${HOST_OS:-linux}"; WINE="${WINE:-}"
mkdir -p "$WORK"; RESULTS="$WORK/results-ndk-$VER.txt"; : > "$RESULTS"
CUR=""; nf=0
log()  { echo "$1" | tee -a "$RESULTS"; }
pass() { log "OK    [$CUR] $1"; }
bad()  { log "FAIL  [$CUR] $1 :: $(tr '\n' ' ' <<<"${2:-}" | tr -s ' ' | cut -c1-600)"; nf=$((nf+1)); }
skip() { log "SKIP  [$CUR] $1"; }
TO() { if [ "$(type -t "$1")" != function ] && command -v timeout >/dev/null; then timeout 900 "$@"; else "$@"; fi; }
expect() { local l=$1 p=$2 out rc; shift 2; out=$(TO "$@" 2>&1); rc=$?
  if [ $rc -eq 0 ] && grep -qE -- "$p" <<<"$out"; then pass "$l"; else bad "$l (rc=$rc, wanted /$p/)" "$out"; fi; }
P() { local p=$1
  if [ -n "$WINE" ]; then p="Z:${p//\//\\}"
  elif [ "$HOST_OS" = windows ] && command -v cygpath >/dev/null; then p=$(cygpath -w "$p"); fi
  printf '%s' "$p"; }
hexat() { od -An -tx1 -j "$2" -N "$3" "$1" 2>/dev/null | tr -d ' \n'; }

declare -A SYSROOT=(
  [aarch64-linux-gnu]=/usr/aarch64-linux-gnu [arm-linux-gnueabihf]=/usr/arm-linux-gnueabihf
  [arm-linux-gnueabi]=/usr/arm-linux-gnueabi [x86-linux-gnu]=/usr/i686-linux-gnu
  [riscv64-linux-gnu]=/usr/riscv64-linux-gnu [powerpc64le-linux-gnu]=/usr/powerpc64le-linux-gnu
  [s390x-linux-gnu]=/usr/s390x-linux-gnu     [loongarch64-linux-gnu]=/usr/loongarch64-linux-gnu
  [mips-linux-gnueabihf]=/usr/mips-linux-gnu [mipsel-linux-gnueabihf]=/usr/mipsel-linux-gnu
  [mips64-linux-gnuabi64]=/usr/mips64-linux-gnuabi64 [mips64el-linux-gnuabi64]=/usr/mips64el-linux-gnuabi64
)

# --- fixtures ---------------------------------------------------------------------------
FIX="$WORK/fix"; rm -rf "$FIX"; mkdir -p "$FIX/proj/jni"
cat > "$FIX/proj/jni/hello.c" <<'EOF'
#include <jni.h>
__attribute__((noinline)) int ndk_test_crash_here(int x) { return x * 6; }
jint JNI_OnLoad(JavaVM *vm, void *r) { (void)vm; (void)r; return ndk_test_crash_here(7) ? JNI_VERSION_1_6 : 0; }
EOF
cat > "$FIX/proj/jni/cxx.cpp" <<'EOF'
#include <string>
#include <vector>
extern "C" int ndk_test_cxx(int n) { std::vector<std::string> v(n, "ok"); return (int)v.size(); }
EOF
cat > "$FIX/proj/jni/Android.mk" <<'EOF'
LOCAL_PATH := $(call my-dir)
include $(CLEAR_VARS)
LOCAL_MODULE := hello
LOCAL_SRC_FILES := hello.c cxx.cpp
include $(BUILD_SHARED_LIBRARY)
EOF
printf 'APP_ABI := all\nAPP_STL := c++_shared\nAPP_PLATFORM := android-21\n' > "$FIX/proj/jni/Application.mk"
printf 'all:\n\t@echo make-ok $(words a b c)\n' > "$FIX/Makefile"
printf 'BITS 64\nglobal f\nsection .text\nf: mov eax, 42\n ret\n' > "$FIX/t.asm"

for T in "$@"; do
  CUR="$T"; d="$WORK/x/$T"; rm -rf "$d"; mkdir -p "$d"
  case $T in *-w64-mingw32) a="android-ndk-$VER-$T.7z" ;; *) a="android-ndk-$VER-$T.tar.xz" ;; esac
  if ! curl -fsSL --retry 5 --retry-all-errors -o "$d/$a" "https://github.com/$REPO/releases/download/$TAG/$a"; then
    bad "download $a"; continue; fi
  case $a in
    *.7z) if command -v 7z >/dev/null; then (cd "$d" && 7z x -y "$a" >/dev/null); else (cd "$d" && tar -xf "$a"); fi ;;
    *) tar -xJf "$d/$a" -C "$d" ;;
  esac
  rm -f "$d/$a"
  ndk=$(find "$d" -maxdepth 2 -name source.properties | head -1); ndk=${ndk%/source.properties}
  [ -d "$ndk" ] || { bad "no NDK in $a"; continue; }
  pb=$(find "$ndk/prebuilt" -mindepth 2 -maxdepth 2 -type d -name bin | head -1)
  tc=$(find "$ndk/toolchains/llvm/prebuilt" -mindepth 1 -maxdepth 1 -type d | head -1)
  x=""; [ "$HOST_OS" = windows ] && x=.exe
  R=(); [ -n "$WINE" ] && R=("$WINE")
  unset QEMU_LD_PREFIX
  probe="$pb/make$x"
  if [ "$HOST_OS" = linux ] && [ "${T%%-*}" != "$(uname -m)" ] && readelf -lW "$probe" 2>/dev/null | grep -q 'interpreter'; then
    sr=${SYSROOT[$T]:-}; [ -z "$sr" ] && [ -e "${SR_DIR:-/nonexistent}/sr-$T" ] && sr=$SR_DIR/sr-$T
    case $T in *-linux-gnu*) if [ -n "$sr" ] && [ -d "$sr" ]; then export QEMU_LD_PREFIX=$sr
      else skip "dynamic glibc build, no $T libc on this runner"; continue; fi ;; esac
  fi
  w="$d/w"; mkdir -p "$w"

  # -- host tools --------------------------------------------------------------------------
  expect "make" "make-ok 3" "${R[@]}" "$pb/make$x" -C "$(P "$FIX")"
  if [ -f "$pb/yasm$x" ]; then
    expect "yasm" "" "${R[@]}" "$pb/yasm$x" -f elf64 -o "$(P "$w/t.o")" "$(P "$FIX/t.asm")"
    [ "$(hexat "$w/t.o" 0 4)" = 7f454c46 ] && pass "yasm ELF output" || bad "yasm ELF output" "$(hexat "$w/t.o" 0 4)"
  fi
  for py in "$pb/python2$x" "$tc/python3/bin/python3$x" "$tc/python3/python$x"; do
    [ -f "$py" ] || continue
    expect "$(basename "$py")" "^42 ok" "${R[@]}" "$py" -c 'import zlib, json, os; print("%d %s" % (6 * 7, json.loads("\"ok\"")))'
  done
  if [ "$HOST_OS" != windows ]; then
    expect "ndk-which" "readelf" "$ndk/ndk-which" --abi arm64-v8a readelf
  fi

  # -- binutils (r20-r23) ------------------------------------------------------------------
  for g in aarch64-linux-android arm-linux-androideabi; do
    b=$(find "$ndk/toolchains" -path "*/bin/$g-as$x" 2>/dev/null | head -1); [ -n "$b" ] || continue
    b=${b%-as$x}
    case $g in aarch64*) s='mov x0, #42' m=AArch64 ;; *) s='mov r0, #42' m=ARM ;; esac
    printf '.globl f\n.type f,%%function\nf:\n %s\n ret\n' "$s" > "$w/$g.s"; [ $g = arm-linux-androideabi ] && sed -i.b 's/ ret/ bx lr/' "$w/$g.s"
    expect "$g-as" "" "${R[@]}" "$b-as$x" -o "$(P "$w/$g.o")" "$(P "$w/$g.s")"
    expect "$g-ld" "" "${R[@]}" "$b-ld$x" -shared -o "$(P "$w/$g.so")" "$(P "$w/$g.o")"
    expect "$g-readelf" "Machine: +$m" "${R[@]}" "$b-readelf$x" -h "$(P "$w/$g.so")"
    expect "$g-nm" " T f$" "${R[@]}" "$b-nm$x" "$(P "$w/$g.so")"
    expect "$g-objdump" "mov" "${R[@]}" "$b-objdump$x" -d "$(P "$w/$g.o")"
    expect "$g-strip" "" "${R[@]}" "$b-strip$x" -o "$(P "$w/$g.stripped")" "$(P "$w/$g.so")"
  done

  # -- ndk-build ---------------------------------------------------------------------------
  cp -r "$FIX/proj" "$w/proj"
  if [ -n "$WINE" ]; then nb=("$WINE" cmd /c "$(P "$ndk/ndk-build.cmd")")
  elif [ "$HOST_OS" = windows ]; then nb=(cmd //c "$(P "$ndk/ndk-build.cmd")")
  else nb=("$ndk/ndk-build"); fi
  nbuild() { cd "$w/proj" && "${nb[@]}" -j4 NDK_PROJECT_PATH=. 2>&1; }
  expect "ndk-build" "libhello.so" nbuild
  n=0
  for abi in "$w"/proj/obj/local/*/; do
    abi=$(basename "$abi"); f="$w/proj/libs/$abi/libhello.so"
    [ -s "$f" ] && [ "$(hexat "$f" 0 4)" = 7f454c46 ] && n=$((n+1)) || bad "ndk-build $abi libhello.so" "$(ls "$w/proj/libs/$abi" 2>&1)"
    [ -s "$w/proj/libs/$abi/libc++_shared.so" ] || bad "ndk-build $abi libc++_shared.so" ""
  done
  [ $n -ge 4 ] && pass "ndk-build: $n ABIs" || bad "ndk-build: $n ABIs" "$(ls "$w/proj/libs" 2>&1)"

  # -- ndk-stack ---------------------------------------------------------------------------
  so="$w/proj/obj/local/arm64-v8a/libhello.so"
  if [ -s "$so" ]; then
    nm=$(command -v llvm-nm || command -v nm)
    off=$("$tc/bin/llvm-nm$x" "$so" 2>/dev/null | awk '/ndk_test_crash_here/{print $1}')
    [ -n "$off" ] || off=$(LC_ALL=C "$nm" "$so" 2>/dev/null | awk '/ndk_test_crash_here/{print $1}')
    if [ -n "$off" ]; then
      cat > "$w/tomb.txt" <<EOF
*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
Build fingerprint: 'test/test/test:12/T/1:user/release-keys'
ABI: 'arm64'
pid: 1, tid: 1, name: t  >>> t.ndk <<<
signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0
backtrace:
      #00 pc $(printf '%016x' $((16#$off + 4)))  /data/app/t.ndk/lib/arm64/libhello.so
EOF
      st=("$ndk/ndk-stack"); [ -n "$WINE" ] && st=("$WINE" cmd /c "$(P "$ndk/ndk-stack.cmd")")
      [ "$HOST_OS" = windows ] && [ -z "$WINE" ] && st=(cmd //c "$(P "$ndk/ndk-stack.cmd")")
      expect "ndk-stack" "ndk_test_crash_here" "${st[@]}" -sym "$(P "${so%/*}")" -dump "$(P "$w/tomb.txt")"
    else bad "ndk-stack: no symbol offset" ""; fi
  fi
  rm -rf "$d"
done
log "OK=$(grep -c '^OK' "$RESULTS")  FAIL=$(grep -c '^FAIL' "$RESULTS")  SKIP=$(grep -c '^SKIP' "$RESULTS")"
[ $nf -eq 0 ]
