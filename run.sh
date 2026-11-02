#!/bin/zsh
# Builds a release binary, wraps it in Tide.app and opens it (--package: don't open).
set -e
cd "${0:A:h}"
swift build -c release
app=Tide.app
version=$(cat version.txt)
rm -rf $app MusicSample.app
mkdir -p $app/Contents/MacOS $app/Contents/Resources
cp .build/release/MusicSample $app/Contents/MacOS/
cp Branding/Icon.icns $app/Contents/Resources/
cat > $app/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Tide</string>
<key>CFBundleDisplayName</key><string>Tide</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>CFBundleIconFile</key><string>Icon</string>
<!-- Kept from the sample days: the sign-in cookies and settings live under this id. -->
<key>CFBundleIdentifier</key><string>local.music-sample</string>
<key>CFBundleExecutable</key><string>MusicSample</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
[[ $1 == --package ]] || open $app
