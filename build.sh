#!/bin/sh
# Builds Snifix.app, signs it locally and installs it into /Applications.
set -e
cd "$(dirname "$0")"
VERSION=1.1.0

swift build -c release --product Snifix

APP=dist/Snifix.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Snifix "$APP/Contents/MacOS/Snifix"

# App icon from the logo
ICONSET=dist/AppIcon.iconset
mkdir -p "$ICONSET"
[ -f Resources/icon-1024.png ] || swift tools/make-icon.swift Resources/logo-source.png Resources/icon-1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Snifix</string>
  <key>CFBundleIdentifier</key><string>com.umid.snifix</string>
  <key>CFBundleName</key><string>Snifix</string>
  <key>CFBundleDisplayName</key><string>Snifix</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>Snifix принимает подключения iPhone и Android из вашей сети, чтобы показывать их запросы.</string>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP"

# Quit a running copy first: it puts the Mac's proxy settings back on exit
if pgrep -x Snifix >/dev/null; then
  osascript -e 'tell application "Snifix" to quit' >/dev/null 2>&1 || true
  sleep 2
fi
rm -rf /Applications/Snifix.app
cp -R "$APP" /Applications/
xattr -dr com.apple.quarantine /Applications/Snifix.app 2>/dev/null || true
echo "Installed /Applications/Snifix.app"

rm -rf dist/dmg "dist/Snifix-$VERSION.dmg"
mkdir -p dist/dmg
cp -R "$APP" dist/dmg/
ln -s /Applications dist/dmg/Applications
hdiutil create -quiet -volname "Snifix $VERSION" -srcfolder dist/dmg -ov -format UDZO "dist/Snifix-$VERSION.dmg"
rm -rf dist/dmg
echo "Disk image dist/Snifix-$VERSION.dmg"
