#!/usr/bin/env bash
# Patch Randopitons 2.1.5 (com.huguesn.randopitons, versionCode 17) so it starts
# on 64-bit-only Android devices (Pixel 7 and later, Android 14+).
#
# Usage: ./patch.sh [--no-verify] [--maps-key AIza...] Randopitons_2.1.5_APKPure.xapk [out_dir]
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
DEV_MAPS_KEY=AIzaSyBEWwVXOVJorjg9HrYZYJcew63EJ59cs2U   # key baked in the 2.1.5 APK

while [ $# -gt 0 ]; do
  case "${1:-}" in
    --no-verify|-no-verify) VERIFY=0; shift ;;
    --maps-key|-maps-key)   MAPS_KEY=${2:?--maps-key needs a value}; shift 2 ;;
    --) shift; break ;;
    -*) echo "unknown option: $1" >&2; exit 1 ;;
    *) break ;;
  esac
done

XAPK=${1:?usage: $0 [--no-verify] [--maps-key AIza...] <Randopitons_2.1.5.xapk> [out_dir]}
OUT=${2:-out}
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
    || { echo "Erreur : la clé Maps doit faire ${#DEV_MAPS_KEY} caractères (format 'AIza...')." >&2; exit 1; }
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

unzip -q "$XAPK" -d "$WORK/xapk"
BASE="$WORK/xapk/com.huguesn.randopitons.apk"
if [ "$VERIFY" = 1 ] && ! echo "$EXPECTED_SHA256  $BASE" | sha256sum -c --quiet - >/dev/null 2>&1; then
  cat >&2 <<EOF
Erreur : le SHA-256 de l'APK de base ne correspond pas à la version 2.1.5 testée.
  attendu : $EXPECTED_SHA256
  obtenu  : $(sha256sum "$BASE" | cut -d' ' -f1)

Si vous êtes sûr d'avoir l'appli Randopitons version 2.1.5 (téléchargée depuis
une autre source, par exemple), relancez avec l'option --no-verify :
  $0 --no-verify $XAPK $OUT
EOF
  exit 1
fi

# 1. Patch SoLoader's default system library path (32-bit only -> 64-bit first).
apktool d -q -r -f -o "$WORK/src" "$BASE"
SMALI="$WORK/src/smali/com/facebook/soloader/SoLoader.smali"
grep -q 'const-string v2, "/vendor/lib:/system/lib"' "$SMALI" 2>/dev/null \
  || { echo "Erreur : code SoLoader attendu introuvable, cette version de l'appli n'est pas compatible avec le patch." >&2; exit 1; }
sed -i 's#const-string v2, "/vendor/lib:/system/lib"#const-string v2, "/system/lib64:/vendor/lib64:/system/lib:/vendor/lib"#' "$SMALI"

# 2. Rebuild, but keep only the patched classes.dex; everything else stays original.
apktool b -q "$WORK/src" -o "$WORK/rebuilt.apk"
unzip -q -o "$WORK/rebuilt.apk" classes.dex -d "$WORK/dex"
cp "$BASE" "$WORK/base.apk"
(cd "$WORK/dex" && zip -q "$WORK/base.apk" classes.dex)

# 2b. Optionally swap the Google Maps API key in the (binary) AndroidManifest.
#     Same length as the original key, so the UTF-16LE bytes are replaced in place.
if [ -n "$MAPS_KEY" ]; then
  unzip -q -o "$WORK/base.apk" AndroidManifest.xml -d "$WORK/mf"
  python3 - "$WORK/mf/AndroidManifest.xml" "$DEV_MAPS_KEY" "$MAPS_KEY" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
data = open(path, 'rb').read()
o, n = old.encode('utf-16-le'), new.encode('utf-16-le')
if data.count(o) != 1:
    sys.stderr.write("Erreur : clé Google Maps d'origine introuvable dans le manifest.\n")
    sys.exit(1)
open(path, 'wb').write(data.replace(o, n))
PY
  (cd "$WORK/mf" && zip -q "$WORK/base.apk" AndroidManifest.xml)
fi

# 3. Drop the original signature and Play source stamp, then align and re-sign every APK.
[ -f "$KEYSTORE" ] || keytool -genkeypair -keystore "$KEYSTORE" -alias "$KS_ALIAS" \
  -keyalg RSA -keysize 2048 -validity 10000 -storepass "$KS_PASS" -keypass "$KS_PASS" \
  -dname "CN=Randopitons patch" >/dev/null 2>&1

mkdir -p "$OUT"
for apk in "$WORK/base.apk" "$WORK"/xapk/config.*.apk; do
  name=$(basename "$apk")
  zip -q -d "$apk" 'META-INF/*.SF' 'META-INF/*.RSA' 'META-INF/*.DSA' 'META-INF/*.EC' stamp-cert-sha256 || true
  "$BUILD_TOOLS/zipalign" -f -p 4 "$apk" "$WORK/aligned-$name"
  "$BUILD_TOOLS/apksigner" sign --ks "$KEYSTORE" --ks-pass "pass:$KS_PASS" --ks-key-alias "$KS_ALIAS" \
    --out "$OUT/$name" "$WORK/aligned-$name"
done
rm -f "$OUT"/*.idsig

# Print the package + SHA-1 to register on the Google Maps API key (GCP console).
SHA1=$("$BUILD_TOOLS/apksigner" verify --print-certs "$OUT/base.apk" 2>/dev/null \
  | awk '/SHA-1 digest:/{print toupper($NF); exit}' | sed 's/../&:/g; s/:$//')
cat <<EOF

------------------------------------------------------------------------
Pour que la carte fonctionne, enregistrez CES valeurs sur votre clé Google
Maps, dans la console GCP :
  API et services > Identifiants > (votre clé) >
  Restrictions d'application > Applications Android > Ajouter

  Nom du package : com.huguesn.randopitons
  Empreinte SHA-1 : $SHA1
------------------------------------------------------------------------
EOF

if [ -z "$MAPS_KEY" ]; then
  echo "Note : pas de --maps-key fourni. L'appli démarre, mais la carte restera"
  echo "       blanche (la clé Google d'origine n'autorise que la signature du dev)."
fi
echo "Done. Install with: adb install-multiple $OUT/*.apk"
