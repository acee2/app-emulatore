#!/usr/bin/env bash
# Scarica i core libretro per iOS (arm64) dal buildbot ufficiale e li converte in .framework.
set -uo pipefail

BASE="https://buildbot.libretro.com/nightly/apple/ios-arm64/latest"
CORES="pcsx_rearmed play ppsspp mupen64plus_next snes9x fceumm mgba gambatte genesis_plus_gx"
OUT="build_extra/Frameworks"
TMP="build_extra/tmp"
mkdir -p "$OUT" "$TMP"

ok=0
for c in $CORES; do
  name="${c}_libretro_ios"
  echo "→ $name"
  if ! curl -fsSL --retry 3 --retry-delay 5 "$BASE/$name.dylib.zip" -o "$TMP/$name.zip"; then
    echo "::warning::Core $name non disponibile sul buildbot: la relativa console risulterà 'Non incluso'."
    continue
  fi
  rm -rf "$TMP/$name"
  unzip -o -q "$TMP/$name.zip" -d "$TMP/$name"
  dylib=$(find "$TMP/$name" -name "*.dylib" | head -1)
  if [ -z "$dylib" ]; then
    echo "::warning::Archivio di $name senza dylib"
    continue
  fi
  fw="$OUT/$name.framework"
  rm -rf "$fw"
  mkdir -p "$fw"
  cp "$dylib" "$fw/$name"
  codesign --remove-signature "$fw/$name" 2>/dev/null || true
  install_name_tool -id "@rpath/$name.framework/$name" "$fw/$name"
  bundle_id="it.arcadia.core.$(echo "$c" | tr '_' '-')"
  cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
  <key>MinimumOSVersion</key><string>13.0</string>
</dict>
</plist>
PLIST
  ok=$((ok + 1))
  echo "  ok ($(du -h "$fw/$name" | cut -f1))"
done

echo "Core pronti: $ok"
if [ "$ok" -eq 0 ]; then
  echo "::error::Nessun core scaricato."
  exit 1
fi
