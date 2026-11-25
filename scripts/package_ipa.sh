#!/usr/bin/env bash
# Crea Arcadia.ipa (non firmata: la firma la fa SideStore).
set -euo pipefail
APP="build/Build/Products/Release-iphoneos/Arcadia.app"
[ -d "$APP" ] || { echo "::error::App non trovata in $APP"; exit 1; }

rm -rf output
mkdir -p output/Payload
cp -R "$APP" output/Payload/
mkdir -p output/Payload/Arcadia.app/Frameworks
if ls build_extra/Frameworks/*.framework >/dev/null 2>&1; then
  cp -R build_extra/Frameworks/*.framework output/Payload/Arcadia.app/Frameworks/
fi
if [ -d build_extra/System ]; then
  rm -rf output/Payload/Arcadia.app/System
  cp -R build_extra/System output/Payload/Arcadia.app/System
fi
find output/Payload -name "_CodeSignature" -type d -prune -exec rm -rf {} +
( cd output && zip -qry Arcadia.ipa Payload )
echo "Contenuto Frameworks:"; ls output/Payload/Arcadia.app/Frameworks
ls -lh output/Arcadia.ipa
