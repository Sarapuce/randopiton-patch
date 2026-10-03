#!/usr/bin/env bash
# Patch Randopitons 2.1.5 (com.huguesn.randopitons, versionCode 17) so it starts
# on 64-bit-only Android devices (Pixel 7 and later, Android 14+).
#
# Usage: ./patch.sh [--no-verify] [--maps-key AIza...] Randopitons_2.1.5_APKPure.xapk [output.xapk]
#
# Produces a single patched .xapk (default: ./randopiton_2.1.5_patch.xapk).
#
# --no-verify: skip the SHA-256 check of the base APK (other 2.1.5 downloads
#              may be repackaged differently and have another hash).
#
# --maps-key:  your own Google Maps API key, so the in-app map works after
#              re-signing. The original key only authorizes the developer's
#              signature, so on a re-signed APK the map stays blank without this.
#              Create a key in Google Cloud ("Maps SDK for Android"), restricted
#              to package com.huguesn.randopitons + your keystore's SHA-1.
#              The map display (dynamic Maps SDK for Android) is not billed.
#
# Env: KEYSTORE, KS_PASS, KS_ALIAS to sign with an existing key
#      (default: generate ./randopitons.keystore on first run).
#      BUILD_TOOLS: Android SDK build-tools dir (zipalign, apksigner).
#      MAPS_API_KEY: same as --maps-key.
set -euo pipefail

VERIFY=1
MAPS_KEY=${MAPS_API_KEY:-}
DEV_MAPS_KEY=AIzaSyBEWwVXOVJorjg9HrYZYJcew63EJ59cs2U

while [ $# -gt 0 ]; do
  case "${1:-}" in
    --no-verify|-no-verify) VERIFY=0; shift ;;
    --maps-key|-maps-key)   MAPS_KEY=${2:?--maps-key needs a value}; shift 2 ;;
    --) shift; break ;;
    -*) echo "unknown option: $1" >&2; exit 1 ;;
    *) break ;;
  esac
done

XAPK=${1:?usage: $0 [--no-verify] [--maps-key AIza...] <Randopitons_2.1.5.xapk> [output.xapk]}
OUT_XAPK=${2:-randopiton_2.1.5_patch.xapk}
KEYSTORE=${KEYSTORE:-randopitons.keystore}
KS_PASS=${KS_PASS:-randopitons}
KS_ALIAS=${KS_ALIAS:-rando}
BUILD_TOOLS=${BUILD_TOOLS:-$(ls -d "${ANDROID_HOME:-$HOME/Android/Sdk}"/build-tools/* | sort -V | tail -1)}
EXPECTED_SHA256=16963a4ea84c42cc93a91193eb52d55d3edd9b7eac812357ecef866d62fb7412

for tool in apktool zip unzip keytool "$BUILD_TOOLS/zipalign" "$BUILD_TOOLS/apksigner"; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
if [ -n "$MAPS_KEY" ]; then
  command -v python3 >/dev/null || { echo "missing tool: python3 (needed for --maps-key)" >&2; exit 1; }
  [ ${#MAPS_KEY} -eq ${#DEV_MAPS_KEY} ] \
    || { echo "error: the Maps key must be ${#DEV_MAPS_KEY} characters long (format 'AIza...')." >&2; exit 1; }
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

unzip -q "$XAPK" -d "$WORK/xapk"
BASE="$WORK/xapk/com.huguesn.randopitons.apk"
if [ "$VERIFY" = 1 ] && ! echo "$EXPECTED_SHA256  $BASE" | sha256sum -c --quiet - >/dev/null 2>&1; then
  cat >&2 <<EOF
error: the base APK's SHA-256 does not match the tested 2.1.5 build.
  expected: $EXPECTED_SHA256
  got:      $(sha256sum "$BASE" | cut -d' ' -f1)

If you are sure you have Randopitons version 2.1.5 (e.g. downloaded from
another source), re-run with --no-verify:
  $0 --no-verify $XAPK $OUT_XAPK
EOF
  exit 1
fi

# 1. Patch SoLoader's default system library path (32-bit only -> 64-bit first).
echo "[1/3] Decompiling and patching SoLoader (may take ~1 min)"
apktool d -q -r -f -o "$WORK/src" "$BASE"
SMALI="$WORK/src/smali/com/facebook/soloader/SoLoader.smali"
grep -q 'const-string v2, "/vendor/lib:/system/lib"' "$SMALI" 2>/dev/null \
  || { echo "error: expected SoLoader code not found, this app version is not compatible with the patch." >&2; exit 1; }
sed -i 's#const-string v2, "/vendor/lib:/system/lib"#const-string v2, "/system/lib64:/vendor/lib64:/system/lib:/vendor/lib"#' "$SMALI"

# 2. Rebuild, but keep only the patched classes.dex, everything else stays original.
echo "[2/3] Recompiling code"
apktool b -q "$WORK/src" -o "$WORK/rebuilt.apk"
unzip -q -o "$WORK/rebuilt.apk" classes.dex -d "$WORK/dex"
cp "$BASE" "$WORK/base.apk"
(cd "$WORK/dex" && zip -q "$WORK/base.apk" classes.dex)

# 2b. Optionally swap the Google Maps API key in the AndroidManifest.
if [ -n "$MAPS_KEY" ]; then
  unzip -q -o "$WORK/base.apk" AndroidManifest.xml -d "$WORK/mf"
  python3 - "$WORK/mf/AndroidManifest.xml" "$DEV_MAPS_KEY" "$MAPS_KEY" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
data = open(path, 'rb').read()
o, n = old.encode('utf-16-le'), new.encode('utf-16-le')
if data.count(o) != 1:
    sys.stderr.write("error: original Google Maps key not found in the manifest.\n")
    sys.exit(1)
open(path, 'wb').write(data.replace(o, n))
PY
  (cd "$WORK/mf" && zip -q "$WORK/base.apk" AndroidManifest.xml)
fi

# 3. Drop the original signature and Play source stamp, then align and re-sign every APK.
[ -f "$KEYSTORE" ] || keytool -genkeypair -keystore "$KEYSTORE" -alias "$KS_ALIAS" \
  -keyalg RSA -keysize 2048 -validity 10000 -storepass "$KS_PASS" -keypass "$KS_PASS" \
  -dname "CN=Randopitons patch" >/dev/null 2>&1

echo "[3/3] Aligning and signing APKs"
mkdir -p "$WORK/signed"
for apk in "$WORK/base.apk" "$WORK"/xapk/config.*.apk; do
  # The base APK is named "com.huguesn.randopitons.apk" inside the .xapk.
  case "$apk" in
    */base.apk) name=com.huguesn.randopitons.apk ;;
    *)          name=$(basename "$apk") ;;
  esac
  echo "      $name"
  zip -q -d "$apk" 'META-INF/*.SF' 'META-INF/*.RSA' 'META-INF/*.DSA' 'META-INF/*.EC' stamp-cert-sha256 || true
  "$BUILD_TOOLS/zipalign" -f -p 4 "$apk" "$WORK/aligned-$name"
  "$BUILD_TOOLS/apksigner" sign --ks "$KEYSTORE" --ks-pass "pass:$KS_PASS" --ks-key-alias "$KS_ALIAS" \
    --out "$WORK/signed/$name" "$WORK/aligned-$name" 2>/dev/null
done

# 4. Repackage the signed APKs + manifest + icon into a single .xapk.
echo "Packaging $OUT_XAPK"
cp "$WORK/xapk/icon.png" "$WORK/signed/icon.png"
total=$(cat "$WORK"/signed/*.apk | wc -c | tr -d ' ')
sed "s/\"total_size\":[0-9]*/\"total_size\":$total/" "$WORK/xapk/manifest.json" > "$WORK/signed/manifest.json"
rm -f "$OUT_XAPK"
zip -X -0 -j -q "$OUT_XAPK" \
  "$WORK/signed/manifest.json" "$WORK/signed/icon.png" "$WORK/signed/"*.apk
unzip -l "$OUT_XAPK" | grep -q 'com.huguesn.randopitons.apk' \
  || { echo "error: base APK missing from $OUT_XAPK" >&2; exit 1; }

# Print the package + SHA-1 to register on the Google Maps API key.
SHA1=$("$BUILD_TOOLS/apksigner" verify --print-certs "$WORK/signed/com.huguesn.randopitons.apk" 2>/dev/null \
  | awk '/SHA-1 digest:/{print toupper($NF); exit}' | sed 's/../&:/g; s/:$//')
cat <<EOF

------------------------------------------------------------------------
  Package name : com.huguesn.randopitons
  SHA-1 fingerprint : $SHA1
------------------------------------------------------------------------
EOF

if [ -z "$MAPS_KEY" ]; then
  echo "Note: no --maps-key provided. The app starts, but the map will stay"
  echo "      blank (the original Google key only authorizes the dev's signature)."
fi
echo "Done. Output: $OUT_XAPK"
echo "Install it with an XAPK installer (e.g. SAI, from the Play Store)."
