#!/bin/bash
# Build KeyRemapper.app — a standalone macOS app
# Usage: ./build.sh

set -e

cd "$(dirname "$0")"
BUILD_DIR=".build"
APP_NAME="KeyRemapper"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "── Building KeyRemapper.app ──"

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# 1. Compile the keyboard layout helper
echo "▸ Compiling keyboard layout helper…"
swiftc keyboard_layout.swift -o "$BUILD_DIR/keyboard_layout" 2>&1

# 2. Compile the Swift app binary
echo "▸ Compiling KeyRemapper binary…"
swiftc KeyRemapperApp.swift -o "$BUILD_DIR/$APP_NAME" \
    -framework Cocoa -framework WebKit 2>&1

# 3. Create the AppleScript launcher
#    macOS 26/Tahoe LaunchServices refuses to open unsigned Swift-compiled
#    .app bundles (error -10825).  AppleScript-based .apps (via osacompile)
#    are accepted.  The AppleScript runs the Swift binary SYNCHRONOUSLY
#    (no & disown) so the shell stays alive and the process tree is not
#    killed when the shell exits.
echo "▸ Creating app bundle…"
cat > "$BUILD_DIR/launcher.applescript" << 'APPLESCRIPT'
on run
    set appPath to (path to me as text)
    set resourcesPath to POSIX path of (appPath & "Contents:Resources:")
    set binaryPath to resourcesPath & "KeyRemapper"
    -- try block swallows the exit status: if the binary is SIGKILLed
    -- (e.g. by the restart watchdog), the applet exits silently instead
    -- of showing a "Killed: 9" error dialog.
    try
        do shell script quoted form of binaryPath & " &> /dev/null < /dev/null"
    end try
end run
APPLESCRIPT

osacompile -o "$APP_BUNDLE" "$BUILD_DIR/launcher.applescript" 2>&1

# Replace the default AppleScript applet icon with our custom KeyRemapper icon
if [ -f "applet.icns" ]; then
    cp applet.icns "$APP_BUNDLE/Contents/Resources/applet.icns"
fi

# 4. Copy resources into the .app bundle
echo "▸ Bundling resources…"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/Resources/$APP_NAME"
cp "$BUILD_DIR/keyboard_layout" "$APP_BUNDLE/Contents/Resources/keyboard_layout"
cp app.py "$APP_BUNDLE/Contents/Resources/app.py"

mkdir -p "$APP_BUNDLE/Contents/Resources/templates"
mkdir -p "$APP_BUNDLE/Contents/Resources/static"
cp templates/index.html "$APP_BUNDLE/Contents/Resources/templates/"
cp static/style.css "$APP_BUNDLE/Contents/Resources/static/"
cp static/app.js "$APP_BUNDLE/Contents/Resources/static/"
[ -d static/videos ] && cp -r static/videos "$APP_BUNDLE/Contents/Resources/static/"

chmod +x "$APP_BUNDLE/Contents/Resources/$APP_NAME"

# 5. Update Info.plist with proper metadata + icon reference
plutil -replace CFBundleName -string "KeyRemapper" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "KeyRemapper" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "com.local.keyremapper" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "1.0" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "1.0" "$APP_BUNDLE/Contents/Info.plist"
# Remove CFBundleIconName (points to default AppleScript icon name)
plutil -remove CFBundleIconName "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
plutil -replace NSHighResolutionCapable -bool true "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true

# Make the AppleScript applet a background agent (no Dock icon).  The applet
# is just a launcher — the Swift binary is the real UI process and shows in
# the Dock via setActivationPolicy(.regular).  Without this, BOTH processes
# show in the Dock (green applet icon + generic exec icon).
plutil -insert LSUIElement -bool true "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true

# Allow WKWebView to load http://127.0.0.1 (App Transport Security blocks
# non-HTTPS by default).  NSAllowsLocalNetworking permits localhost connections.
plutil -replace NSAppTransportSecurity.NSAllowsLocalNetworking -bool true "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
    plutil -insert NSAppTransportSecurity -xml "<dict><key>NSAllowsLocalNetworking</key><true/></dict>" "$APP_BUNDLE/Contents/Info.plist"

# 6. Ad-hoc codesign (best effort — helps on some macOS versions)
codesign --force --deep --sign - "$APP_BUNDLE" 2>&1 || true

# 7. Register with LaunchServices
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP_BUNDLE" 2>/dev/null || true

# 8. Clean up temp files
rm -f "$BUILD_DIR/launcher.applescript"

echo ""
echo "✓ Build complete!"
echo "  App: $APP_BUNDLE"
echo ""
echo "  To install: cp -R $APP_BUNDLE /Applications/"
echo "  To run:    open $APP_BUNDLE"
