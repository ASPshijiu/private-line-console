#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/.build/线路验收测试.app"
mkdir -p "$app/Contents/MacOS"
/usr/bin/xcrun swiftc Tests/Probe.swift -o "$app/Contents/MacOS/Probe"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.private-line.probe</string>
<key>CFBundleName</key><string>线路验收测试</string>
<key>CFBundleExecutable</key><string>Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$app"
