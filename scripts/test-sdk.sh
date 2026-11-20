#!/usr/bin/env bash
# test-sdk.sh VERSION TRIPLE...: functional test of HomuHomu833/android-sdk-custom builds.
# Builds a signed APK end to end with the SDK's own tools (aidl, aapt2 compile/link, d8,
# dexdump, aapt add, zipalign, apksigner, apkanalyzer), then exercises the platform tools
# (sqlite3, mke2fs, make_f2fs, etc1tool, adb, fastboot, hprof-conv). Placeholders are SKIPs.
# Foreign Linux builds run through qemu-user binfmt like test-cmake.sh. The Java tools need
# a host JDK (java, javac, keytool) and are skipped without one.
# Env: REPO (default HomuHomu833/android-sdk-custom), WORK, HOST_OS (linux|darwin|bsd|windows),
#      WINE, SR_DIR, PLATFORM_ZIP (android.jar source)
set -uo pipefail
REPO="${REPO:-HomuHomu833/android-sdk-custom}"; VER=$1; shift
WORK="${WORK:-$HOME/sdk-test}"; HOST_OS="${HOST_OS:-linux}"; WINE="${WINE:-}"
PLATFORM_ZIP="${PLATFORM_ZIP:-https://dl.google.com/android/repository/platform-35_r02.zip}"
mkdir -p "$WORK"; RESULTS="$WORK/results-sdk-$VER.txt"; : > "$RESULTS"
CUR=""; nf=0
log()  { echo "$1" | tee -a "$RESULTS"; }
pass() { log "OK    [$CUR] $1"; }
bad()  { log "FAIL  [$CUR] $1 :: $(tr '\n' ' ' <<<"${2:-}" | tr -s ' ' | cut -c1-600)"; nf=$((nf+1)); }
skip() { log "SKIP  [$CUR] $1"; }
TO() { if [ "$(type -t "$1")" != function ] && command -v timeout >/dev/null; then timeout 300 "$@"; else "$@"; fi; }
# expect LABEL REGEX CMD...: pass when CMD exits 0 and prints REGEX
expect() { local l=$1 p=$2 out rc; shift 2; out=$(TO "$@" 2>&1); rc=$?
  if [ $rc -eq 0 ] && grep -qE -- "$p" <<<"$out"; then pass "$l"; else bad "$l (rc=$rc, wanted /$p/)" "$out"; fi; }
# usage LABEL REGEX CMD...: tools that only print usage; any exit code, output must match
usage() { local l=$1 p=$2 out rc; shift 2; out=$(TO "$@" 2>&1); rc=$?
  if [ $rc -lt 126 ] && grep -qiE -- "$p" <<<"$out"; then pass "$l"; else bad "$l (rc=$rc, wanted /$p/)" "$out"; fi; }
# a path as the tool under test sees it
P() { local p=$1
  if [ -n "$WINE" ]; then p="Z:${p//\//\\}"
  elif [ "$HOST_OS" = windows ] && command -v cygpath >/dev/null; then p=$(cygpath -m "$p"); fi
  printf '%s' "$p"; }

declare -A SYSROOT=(
  [aarch64-linux-gnu]=/usr/aarch64-linux-gnu [arm-linux-gnueabihf]=/usr/arm-linux-gnueabihf
  [arm-linux-gnueabi]=/usr/arm-linux-gnueabi [x86-linux-gnu]=/usr/i686-linux-gnu
  [riscv64-linux-gnu]=/usr/riscv64-linux-gnu [powerpc64le-linux-gnu]=/usr/powerpc64le-linux-gnu
  [s390x-linux-gnu]=/usr/s390x-linux-gnu     [loongarch64-linux-gnu]=/usr/loongarch64-linux-gnu
  [mips-linux-gnueabihf]=/usr/mips-linux-gnu [mipsel-linux-gnueabihf]=/usr/mipsel-linux-gnu
  [mips64-linux-gnuabi64]=/usr/mips64-linux-gnuabi64 [mips64el-linux-gnuabi64]=/usr/mips64el-linux-gnuabi64
)

# --- fixtures, shared by every triple ---------------------------------------------------
FIX="$WORK/fix"; mkdir -p "$FIX/res/values" "$FIX/aidl/t" "$FIX/java/t"
if [ ! -s "$FIX/android.jar" ]; then
  curl -fsSL --retry 5 --retry-all-errors -o "$WORK/platform.zip" "$PLATFORM_ZIP" &&
    unzip -p "$WORK/platform.zip" '*/android.jar' > "$FIX/android.jar"; rm -f "$WORK/platform.zip"
fi
cat > "$FIX/AndroidManifest.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="t.sdk"
    android:versionCode="42" android:versionName="4.2">
  <uses-sdk android:minSdkVersion="21" android:targetSdkVersion="35"/>
  <application android:label="@string/app_name"/>
</manifest>
EOF
printf '<resources><string name="app_name">sdk-ok</string></resources>\n' > "$FIX/res/values/strings.xml"
printf 'package t;\ninterface IFoo { int add(int a, int b); String name(); }\n' > "$FIX/aidl/t/IFoo.aidl"
printf 'package t;\npublic class Main { public static int f(int x) { return x * 6; } }\n' > "$FIX/java/t/Main.java"
JAVA=0
if command -v javac >/dev/null && command -v keytool >/dev/null && command -v java >/dev/null; then
  rm -rf "$FIX/classes"; mkdir -p "$FIX/classes"
  javac --release 8 -d "$FIX/classes" "$FIX/java/t/Main.java" 2>/dev/null &&
    { [ -s "$FIX/ks.jks" ] || keytool -genkeypair -keystore "$FIX/ks.jks" -storepass android -keypass android \
        -alias k -keyalg RSA -keysize 2048 -validity 1000 -dname CN=sdk-test >/dev/null 2>&1; } &&
    [ -s "$FIX/ks.jks" ] && JAVA=1
fi
# a 4x4 RGB PNG for etc1tool
python3 - "$FIX/in.png" <<'EOF' 2>/dev/null || true
import struct, sys, zlib
w = h = 4
raw = b"".join(b"\0" + b"".join(bytes([x * 60, y * 60, 128]) for x in range(w)) for y in range(h))
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
EOF
# two magic checks without xxd: ext4 0xEF53 at 1080, f2fs 0xF2F52010 at 1024
hexat() { od -An -tx1 -j "$2" -N "$3" "$1" 2>/dev/null | tr -d ' \n'; }

for T in "$@"; do
  CUR="$T"; d="$WORK/x/$T"; rm -rf "$d"; mkdir -p "$d"
  case $T in *-w64-mingw32) a="android-sdk-$T.7z" ;; *) a="android-sdk-$T.tar.xz" ;; esac
  if ! curl -fsSL --retry 5 --retry-all-errors -o "$d/$a" "https://github.com/$REPO/releases/download/$VER/$a"; then
    bad "download $a"; continue; fi
  case $a in
    *.7z) if command -v 7z >/dev/null; then (cd "$d" && 7z x -y "$a" >/dev/null); else (cd "$d" && tar -xf "$a"); fi ;;
    *) tar -xJf "$d/$a" -C "$d" ;;
  esac
  rm -f "$d/$a"
  sdk=$(find "$d" -maxdepth 3 -type d -name build-tools | head -1); sdk=${sdk%/build-tools}
  bt=$(find "$sdk/build-tools" -mindepth 1 -maxdepth 1 -type d | head -1); pt="$sdk/platform-tools"
  ct="$sdk/cmdline-tools/latest/bin"; [ -d "$ct" ] || ct="$sdk/cmdline-tools/bin"
  [ -d "$bt" ] || { bad "no build-tools in $a"; continue; }
  x=""; [ "$HOST_OS" = windows ] && x=.exe
  R=(); [ -n "$WINE" ] && R=("$WINE")
  # a native tool: absent or a text placeholder means SKIP, otherwise run through $R
  have() { local f="$1$x"; [ -f "$f" ] || { skip "$(basename "$1"): not shipped"; return 1; }
    if head -c 4 "$f" | grep -q 'This'; then skip "$(basename "$1"): placeholder"; return 1; fi; return 0; }
  unset QEMU_LD_PREFIX
  probe="$bt/aapt2$x"
  if [ "$HOST_OS" = linux ] && [ "${T%%-*}" != "$(uname -m)" ] && readelf -lW "$probe" 2>/dev/null | grep -q 'interpreter'; then
    sr=${SYSROOT[$T]:-}; [ -z "$sr" ] && [ -e "${SR_DIR:-/nonexistent}/sr-$T" ] && sr=$SR_DIR/sr-$T
    case $T in *-linux-gnu*) if [ -n "$sr" ] && [ -d "$sr" ]; then export QEMU_LD_PREFIX=$sr
      else skip "dynamic glibc build, no $T libc on this runner"; continue; fi ;; esac
  fi
  if [ "$HOST_OS" = darwin ] && [ "${T%%-*}" = arm64e ]; then "$bt/aapt2" version >/dev/null 2>&1
    [ $? -eq 137 ] && { skip "this Mac does not run third-party arm64e binaries"; continue; }; fi
  w="$d/w"; mkdir -p "$w"

  # -- build-tools: an APK from scratch --------------------------------------------------
  if have "$bt/aidl"; then
    expect "aidl java" "" "${R[@]}" "$bt/aidl$x" -I"$(P "$FIX/aidl")" -o"$(P "$w/gen")" "$(P "$FIX/aidl/t/IFoo.aidl")"
    if grep -q 'int add(int a, int b)' "$w/gen/t/IFoo.java" 2>/dev/null; then pass "aidl java output has add()"
    else bad "aidl java output" "$(ls -R "$w/gen" 2>&1)"; fi
    if "${R[@]}" "$bt/aidl$x" --help 2>&1 | grep -q -- '--lang'; then
      expect "aidl cpp" "" "${R[@]}" "$bt/aidl$x" --lang=cpp -I"$(P "$FIX/aidl")" -h "$(P "$w/hdr")" -o "$(P "$w/cpp")" "$(P "$FIX/aidl/t/IFoo.aidl")"
      [ -f "$w/hdr/t/IFoo.h" ] && pass "aidl cpp header" || bad "aidl cpp header" "$(ls -R "$w/hdr" 2>&1)"
    fi
  fi
  apk=""
  if have "$bt/aapt2"; then
    expect "aapt2 version" "Android Asset Packaging Tool" "${R[@]}" "$bt/aapt2$x" version
    expect "aapt2 compile" "" "${R[@]}" "$bt/aapt2$x" compile -o "$(P "$w")" "$(P "$FIX/res/values/strings.xml")"
    if [ -s "$FIX/android.jar" ]; then
      expect "aapt2 link" "" "${R[@]}" "$bt/aapt2$x" link -o "$(P "$w/base.apk")" -I "$(P "$FIX/android.jar")" \
        --manifest "$(P "$FIX/AndroidManifest.xml")" "$(P "$w/values_strings.arsc.flat")"
      [ -s "$w/base.apk" ] && apk="$w/base.apk"
      [ -n "$apk" ] && expect "aapt2 dump badging" "package: name='t.sdk' versionCode='42'" "${R[@]}" "$bt/aapt2$x" dump badging "$(P "$apk")"
      [ -n "$apk" ] && expect "aapt2 dump resources" "string/app_name" "${R[@]}" "$bt/aapt2$x" dump resources "$(P "$apk")"
    else skip "aapt2 link: no android.jar"; fi
  fi
  if [ -n "$apk" ] && have "$bt/aapt"; then
    expect "aapt dump badging" "application-label:'sdk-ok'" "${R[@]}" "$bt/aapt$x" dump badging "$(P "$apk")"
  fi
  dex=""
  if [ $JAVA = 1 ] && [ -f "$bt/d8" -o -f "$bt/d8.bat" ]; then
    # the wrapper is a shell script (or .bat); the jar is what matters, same on every host
    mkdir -p "$w/dex"
    expect "d8" "" java -cp "$bt/lib/d8.jar" com.android.tools.r8.D8 --min-api 21 --lib "$FIX/android.jar" \
      --output "$w/dex" "$FIX/classes/t/Main.class"
    [ -s "$w/dex/classes.dex" ] && dex="$w/dex/classes.dex"
  elif [ $JAVA = 0 ]; then skip "d8: no host JDK"; fi
  if [ -n "$dex" ] && have "$bt/dexdump"; then
    expect "dexdump" "Lt/Main;" "${R[@]}" "$bt/dexdump$x" "$(P "$dex")"
  fi
  if [ -n "$apk" ] && [ -n "$dex" ] && have "$bt/aapt"; then
    aadd() { cd "$w/dex" && "${R[@]}" "$bt/aapt$x" add "$(P "$apk")" classes.dex; }
    expect "aapt add classes.dex" "classes.dex" aadd
    expect "aapt list" "^classes.dex" "${R[@]}" "$bt/aapt$x" list "$(P "$apk")"
  fi
  if [ -n "$apk" ] && have "$bt/zipalign"; then
    expect "zipalign" "" "${R[@]}" "$bt/zipalign$x" -p -f 4 "$(P "$apk")" "$(P "$w/aligned.apk")"
    expect "zipalign -c" "Verification succes" "${R[@]}" "$bt/zipalign$x" -c -v 4 "$(P "$w/aligned.apk")"
    if [ $JAVA = 1 ] && [ -f "$bt/lib/apksigner.jar" ]; then
      expect "apksigner sign" "" java -jar "$bt/lib/apksigner.jar" sign --ks "$FIX/ks.jks" --ks-pass pass:android \
        --out "$w/signed.apk" "$w/aligned.apk"
      expect "apksigner verify" "Verified using v2 scheme \(APK Signature Scheme v2\): true" \
        java -jar "$bt/lib/apksigner.jar" verify --verbose "$w/signed.apk"
      if [ -f "$ct/apkanalyzer" ] && [ "$HOST_OS" != windows ]; then
        expect "apkanalyzer application-id" "^t\.sdk" sh "$ct/apkanalyzer" manifest application-id "$w/signed.apk"
      fi
    fi
  fi
  if [ $JAVA = 1 ] && [ -f "$ct/sdkmanager" ] && [ "$HOST_OS" != windows ]; then
    expect "sdkmanager finds the SDK root" "^[0-9]+\.[0-9]" sh "$ct/sdkmanager" --version
  fi
  have "$bt/split-select" && usage "split-select" "usage|split-select" "${R[@]}" "$bt/split-select$x" --help
  for p in lld bcc_compat llvm-rs-cc; do [ -f "$bt/$p$x" ] || [ -f "$bt/$p" ] || continue
    { [ -f "$bt/$p" ] && head -c 4 "$bt/$p" | grep -q This; } && skip "$p: placeholder" || \
      usage "$p" "version|usage|OVERVIEW|LLVM" "${R[@]}" "$bt/$p$x" --version; done

  # -- platform-tools ----------------------------------------------------------------------
  if [ -d "$pt" ]; then
    have "$pt/adb" && expect "adb version" "Android Debug Bridge version" "${R[@]}" "$pt/adb$x" version
    have "$pt/fastboot" && expect "fastboot --version" "fastboot version" "${R[@]}" "$pt/fastboot$x" --version
    have "$pt/sqlite3" && expect "sqlite3 SQL" "^42\|abc$" "${R[@]}" "$pt/sqlite3$x" :memory: \
      "create table t(a,b); insert into t values(41,'abc'); select a+1, b from t;"
    have "$pt/hprof-conv" && usage "hprof-conv" "usage|hprof-conv" "${R[@]}" "$pt/hprof-conv$x"
    if have "$pt/mke2fs"; then
      rm -f "$w/e.img"
      MKE2FS_CONFIG="$pt/mke2fs.conf" expect "mke2fs ext4" "" "${R[@]}" "$pt/mke2fs$x" -t ext4 -F -q "$(P "$w/e.img")" 16M
      [ "$(hexat "$w/e.img" 1080 2)" = 53ef ] && pass "ext4 superblock magic" || bad "ext4 superblock magic" "$(hexat "$w/e.img" 1080 2)"
    fi
    for f in make_f2fs make_f2fs_casefold; do
      have "$pt/$f" || continue
      rm -f "$w/$f.img"; : > "$w/$f.img"; truncate -s 64M "$w/$f.img" 2>/dev/null || dd if=/dev/zero of="$w/$f.img" bs=1048576 count=0 seek=64 2>/dev/null
      cf=(); [ $f = make_f2fs_casefold ] && cf=(-C utf8)
      expect "$f" "" "${R[@]}" "$pt/$f$x" "${cf[@]}" "$(P "$w/$f.img")"
      [ "$(hexat "$w/$f.img" 1024 4)" = 1020f5f2 ] && pass "$f superblock magic" || bad "$f superblock magic" "$(hexat "$w/$f.img" 1024 4)"
    done
    if have "$pt/etc1tool"; then
      if [ -s "$FIX/in.png" ]; then
        expect "etc1tool encode" "" "${R[@]}" "$pt/etc1tool$x" "$(P "$FIX/in.png")" --encode -o "$(P "$w/t.pkm")"
        [ "$(head -c 4 "$w/t.pkm" 2>/dev/null)" = "PKM " ] && pass "etc1tool PKM header" || bad "etc1tool PKM header" ""
        expect "etc1tool decode" "" "${R[@]}" "$pt/etc1tool$x" "$(P "$w/t.pkm")" --decode -o "$(P "$w/out.png")"
        [ "$(hexat "$w/out.png" 1 3)" = 504e47 ] && pass "etc1tool decoded PNG" || bad "etc1tool decoded PNG" ""
      else skip "etc1tool: no python3 for the input PNG"; fi
    fi
  fi
  rm -rf "$d"
done
log "OK=$(grep -c '^OK' "$RESULTS")  FAIL=$(grep -c '^FAIL' "$RESULTS")  SKIP=$(grep -c '^SKIP' "$RESULTS")"
[ $nf -eq 0 ]
