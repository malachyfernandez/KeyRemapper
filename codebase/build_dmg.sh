#!/bin/bash
# Build KeyRemapper.dmg — a distributable disk image with styled background
# Usage: ./build_dmg.sh

set -e

cd "$(dirname "$0")"

# First build the app
./build.sh

APP_BUNDLE=".build/KeyRemapper.app"
DMG_NAME="KeyRemapper-1.0.dmg"
DMG_PATH=".build/$DMG_NAME"

echo ""
echo "── Building DMG ──"

# Clean up any previous DMG
rm -f "$DMG_PATH"

# Generate a background image with the arrow design
echo "▸ Generating DMG background…"
swiftc generate_dmg_background.swift -o .build/gen_bg -framework Cocoa 2>&1
.build/gen_bg ".build/dmg-background.png"

# Build the DMG using dmgbuild (handles background + icon positions properly)
echo "▸ Creating styled disk image…"
DMGBUILD="$HOME/Library/Python/3.9/bin/dmgbuild"
if [ ! -x "$DMGBUILD" ]; then
    DMGBUILD="$(python3 -m site --user-base)/bin/dmgbuild"
fi
"$DMGBUILD" -s dmg_settings.py "KeyRemapper" "$DMG_PATH" 2>&1

# Clean up
rm -f .build/gen_bg .build/dmg-background.png

# Get the size
SIZE=$(du -h "$DMG_PATH" | cut -f1)

echo ""
echo "✓ DMG built successfully!"
echo "  File: $DMG_PATH"
echo "  Size: $SIZE"
echo ""
echo "  To install: Open the DMG, drag KeyRemapper to Applications"
echo "  To share:   Send the DMG file to others"
