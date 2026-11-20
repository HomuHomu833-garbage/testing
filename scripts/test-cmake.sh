#!/usr/bin/env bash
# test-cmake.sh VERSION TRIPLE...: functional test of HomuHomu833/cmake-custom builds.
# Per triple: cmake/ctest/cpack/ninja --version, a cmake -P script, and (where a native C
# compiler exists) configure + build + ctest of a small project with the bundled ninja.
# Foreign Linux builds run through qemu-user binfmt; dynamic glibc ones take their libc from
# QEMU_LD_PREFIX. HOST_OS=windows runs the .exe files (through $WINE when set).
# Env: REPO (default HomuHomu833/cmake-custom), WORK, HOST_OS (linux|darwin|bsd|windows), WINE
set -uo pipefail
REPO="${REPO:-HomuHomu833/cmake-custom}"; VER=$1; shift
WORK="${WORK:-$HOME/cmake-test}"; HOST_OS="${HOST_OS:-linux}"; WINE="${WINE:-}"
mkdir -p "$WORK"; RESULTS="$WORK/results-cmake-$VER.txt"; : > "$RESULTS"
CUR=""; nf=0
log()  { echo "$1" | tee -a "$RESULTS"; }
pass() { log "OK    [$CUR] $1"; }
bad()  { log "FAIL  [$CUR] $1 :: $(sed -n '/Deprecation Warning/,/^$/d; /Compatibility with CMake/d; p' <<<"${2:-}" | tr '\n' ' ' | tr -s ' ' | cut -c1-700)"; nf=$((nf+1)); }
skip() { log "SKIP  [$CUR] $1"; }
TO() { if command -v timeout >/dev/null; then timeout 300 "$@"; else "$@"; fi; }
expect() { local l=$1 p=$2 out rc; shift 2; out=$(TO "$@" 2>&1); rc=$?
  if [ $rc -eq 0 ] && grep -qE -- "$p" <<<"$out"; then pass "$l"; else bad "$l (rc=$rc, wanted /$p/)" "$out"; fi; }

declare -A SYSROOT=(
  [aarch64-linux-gnu]=/usr/aarch64-linux-gnu [arm-linux-gnueabihf]=/usr/arm-linux-gnueabihf
  [arm-linux-gnueabi]=/usr/arm-linux-gnueabi [x86-linux-gnu]=/usr/i686-linux-gnu
  [riscv64-linux-gnu]=/usr/riscv64-linux-gnu [powerpc64le-linux-gnu]=/usr/powerpc64le-linux-gnu
  [s390x-linux-gnu]=/usr/s390x-linux-gnu     [loongarch64-linux-gnu]=/usr/loongarch64-linux-gnu
  [mips-linux-gnueabihf]=/usr/mips-linux-gnu [mipsel-linux-gnueabihf]=/usr/mipsel-linux-gnu
  [mips64-linux-gnuabi64]=/usr/mips64-linux-gnuabi64 [mips64el-linux-gnuabi64]=/usr/mips64el-linux-gnuabi64
)
FIX="$WORK/fix"; mkdir -p "$FIX/p"
cat > "$FIX/p/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.6)
project(t C)
add_executable(t t.c)
enable_testing()
add_test(NAME t COMMAND t)
EOF
printf '#include <stdio.h>\nint main(void){puts("t-ok");return 0;}\n' > "$FIX/p/t.c"
cat > "$FIX/s.cmake" <<'EOF'
string(REGEX REPLACE "([a-z]+)-([0-9]+)" "\\2:\\1" r "abc-42")
list(APPEND l z a m)
list(SORT l)
math(EXPR m "6 * 7")
file(WRITE "${OUT}" "${r};${m}")
file(READ "${OUT}" back)
string(REPLACE ";" "," j "${l}")
message(STATUS "script-ok ${back} ${j}")
EOF

for T in "$@"; do
  CUR="$T"; d="$WORK/x/$T"; rm -rf "$d"; mkdir -p "$d"
  case $T in *-w64-mingw32) a="cmake-$T.7z" ;; *) a="cmake-$T.tar.xz" ;; esac
  if ! curl -fsSL --retry 5 --retry-all-errors -o "$d/$a" "https://github.com/$REPO/releases/download/$VER/$a"; then
    bad "download $a"; continue; fi
  case $a in
    *.7z) if command -v 7z >/dev/null; then (cd "$d" && 7z x -y "$a" >/dev/null); else (cd "$d" && tar -xf "$a"); fi ;;
    *) tar -xJf "$d/$a" -C "$d" ;;
  esac
  rm -f "$d/$a"
  b=$(dirname "$(find "$d" \( -name cmake -o -name cmake.exe \) -path '*/bin/*' | head -1)")
  [ -d "$b" ] || { bad "no bin/cmake in $a"; continue; }
  x=""; [ "$HOST_OS" = windows ] && x=.exe
  R=(); [ "$HOST_OS" = windows ] && [ -n "$WINE" ] && R=("$WINE")
  unset QEMU_LD_PREFIX
  if [ "$HOST_OS" = linux ] && [ "${T%%-*}" != "$(uname -m)" ] && readelf -lW "$b/cmake" 2>/dev/null | grep -q 'interpreter'; then
    sr=${SYSROOT[$T]:-}; [ -z "$sr" ] && [ -e "${SR_DIR:-/nonexistent}/sr-$T" ] && sr=$SR_DIR/sr-$T
    case $T in *-linux-gnu*) if [ -n "$sr" ] && [ -d "$sr" ]; then export QEMU_LD_PREFIX=$sr
      else skip "dynamic glibc build, no $T libc on this runner"; continue; fi ;; esac
  fi
  # macOS only runs third-party arm64e code with the arm64e preview ABI boot-arg
  if [ "$HOST_OS" = darwin ] && [ "${T%%-*}" = arm64e ]; then "$b/cmake" --version >/dev/null 2>&1
    [ $? -eq 137 ] && { skip "this Mac does not run third-party arm64e binaries"; continue; }; fi
  expect "cmake --version" "cmake version ${VER//./\\.}" "${R[@]}" "$b/cmake$x" --version
  expect "ctest --version" "ctest version" "${R[@]}" "$b/ctest$x" --version
  expect "cpack --version" "cpack version" "${R[@]}" "$b/cpack$x" --version
  [ -e "$b/ninja$x" ] && expect "ninja --version" '^[0-9]+\.[0-9]+' "${R[@]}" "$b/ninja$x" --version
  o="$d/s.out"; [ "$HOST_OS" = windows ] && command -v cygpath >/dev/null && o=$(cygpath -m "$o")
  [ -n "$WINE" ] && o="Z:${o//\//\\}"
  sf="$FIX/s.cmake"; [ "$HOST_OS" = windows ] && command -v cygpath >/dev/null && sf=$(cygpath -m "$sf")
  [ -n "$WINE" ] && sf="Z:${sf//\//\\}"
  expect "cmake -P script" "script-ok 42:abc;42 a,m,z" "${R[@]}" "$b/cmake$x" -DOUT="$o" -P "$sf"
  if [ "$HOST_OS" = windows ]; then
    # -E capabilities arrived in 3.7
    [ "$VER" != 3.6.0 ] && expect "cmake -E capabilities" '"version"' "${R[@]}" "$b/cmake$x" -E capabilities
    continue
  fi
  cc=$(command -v cc || command -v clang || command -v gcc)
  [ -n "$cc" ] || { skip "no native C compiler for the project build"; continue; }
  bd="$d/build"; rm -rf "$bd"; mkdir -p "$bd"
  # an Android cmake defaults its target to Android; this host builds for itself
  sys=(); case $T in *-android*) sys=(-DCMAKE_SYSTEM_NAME=Linux) ;; esac
  if out=$(cd "$bd" && TO "$b/cmake" "$FIX/p" -G Ninja -DCMAKE_MAKE_PROGRAM="$b/ninja" -DCMAKE_C_COMPILER="$cc" "${sys[@]}" 2>&1); then
    pass "configure (Ninja)"
    if out=$(TO "$b/cmake" --build "$bd" 2>&1); then pass "build"
      expect "ctest" "100% tests passed" sh -c "cd '$bd' && '$b/ctest' --output-on-failure"
    else bad "build" "$out"; fi
  else bad "configure (Ninja)" "$out"; fi
  rm -rf "$d"
done
log "OK=$(grep -c '^OK' "$RESULTS")  FAIL=$(grep -c '^FAIL' "$RESULTS")  SKIP=$(grep -c '^SKIP' "$RESULTS")"
[ $nf -eq 0 ]
