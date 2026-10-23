#!/bin/zsh
# Builds build/Moji Picker.app and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product MojiApp
APP="build/Moji Picker.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MojiApp "$APP/Contents/MacOS/Moji"
cp Resources/emoji.json "$APP/Contents/Resources/"

if [[ ! -f build/AppIcon.icns ]]; then
  ICONSET=build/AppIcon.iconset
  mkdir -p "$ICONSET"
  swift scripts/make-icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Moji</string>
  <key>CFBundleDisplayName</key><string>Moji Picker</string>
  <key>CFBundleIdentifier</key><string>com.beckyisj.moji-mac</string>
  <key>CFBundleExecutable</key><string>Moji</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Becky Isjwara</string>
</dict>
</plist>
PLIST

IDENTITY="${MOJI_SIGN_IDENTITY:-Apple Development}"  # stable signature keeps the Accessibility grant; self-signed certs are rejected on macOS 26
if [[ "$IDENTITY" != "-" ]] && security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" --identifier com.beckyisj.moji-mac "$APP"
else
  codesign --force --sign - --identifier com.beckyisj.moji-mac "$APP"  # ad-hoc: Accessibility resets each build
fi

true
pkill -x Moji 2>/dev/null || true
rm -rf "/Applications/Moji Picker.app"
cp -R "$APP" /Applications/
echo "Installed /Applications/Moji Picker.app"
