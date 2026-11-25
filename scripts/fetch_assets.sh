#!/usr/bin/env bash
# File di sistema di PPSSPP (font, compat.ini, shader...) da includere nell'app.
set -euo pipefail
rm -rf build_extra/ppsspp-src build_extra/System/PPSSPP
mkdir -p build_extra/System/PPSSPP
git clone -q --depth 1 --filter=blob:none --sparse https://github.com/hrydgard/ppsspp build_extra/ppsspp-src
( cd build_extra/ppsspp-src && git sparse-checkout set assets )
cp -R build_extra/ppsspp-src/assets/. build_extra/System/PPSSPP/
# Elementi non necessari al core libretro
rm -rf build_extra/System/PPSSPP/debugger build_extra/System/PPSSPP/ui_images 2>/dev/null || true
du -sh build_extra/System/PPSSPP
