#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build
/usr/bin/xcrun swiftc -swift-version 5 Sources/Policy.swift Tests/main.swift -o .build/policy-tests
.build/policy-tests
app="$PWD/.build/专线控制台.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
/usr/bin/xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 -framework SwiftUI -framework AppKit Sources/Policy.swift Sources/Service.swift Sources/App.swift -o "$app/Contents/MacOS/PrivateLine"
/bin/cp Resources/install-helper.sh "$app/Contents/Resources/"
/bin/cp "$HOME/Library/Application Support/Codex Private Proxy/mihomo" "$app/Contents/Resources/mihomo"
/bin/chmod 755 "$app/Contents/Resources/install-helper.sh"
/usr/bin/xcrun swift Resources/make-icon.swift .build/AppIcon.iconset
/usr/bin/iconutil -c icns .build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.private-line.control</string>
<key>CFBundleName</key><string>专线控制台</string>
<key>CFBundleDisplayName</key><string>专线控制台</string>
<key>CFBundleExecutable</key><string>PrivateLine</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict "$app"
printf 'Built %s\n' "$app"
