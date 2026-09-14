#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Plagadeon Notes"
APP_DIR="$HOME/Applications/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICONSET_DIR="$RESOURCES_DIR/AppIcon.iconset"

mkdir -p "$MACOS_DIR"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

for size in 16 32 128 256 512; do
    /usr/bin/sips -s format png -z "$size" "$size" \
        "$PROJECT_DIR/Assets/AppIcon-Monogram.svg" \
        --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    /usr/bin/sips -s format png -z "$double_size" "$double_size" \
        "$PROJECT_DIR/Assets/AppIcon-Monogram.svg" \
        --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done

/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
/bin/rm -rf "$ICONSET_DIR"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Plagadeon Notes</string>
    <key>CFBundleExecutable</key>
    <string>launcher</string>
    <key>CFBundleIdentifier</key>
    <string>de.plagadeon.notes.launcher</string>
    <key>CFBundleName</key>
    <string>Plagadeon Notes</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

cat > "$MACOS_DIR/launcher" <<'LAUNCHER'
#!/bin/zsh
set -euo pipefail

PROJECT_DIR="__PROJECT_DIR__"
BINARY="$PROJECT_DIR/.build/arm64-apple-macosx/debug/PlagadeonNotes"
BUILD_LOG="/tmp/plagadeon-notes-build.log"

needs_build=0
if [[ ! -x "$BINARY" ]]; then
    needs_build=1
else
    newest_source=0

    if [[ -d "$PROJECT_DIR/Sources" ]]; then
        source_mtime=$(
            /usr/bin/find "$PROJECT_DIR/Sources" -type f -print0 2>/dev/null \
                | /usr/bin/xargs -0 /usr/bin/stat -f '%m' 2>/dev/null \
                | /usr/bin/sort -nr \
                | /usr/bin/head -n1
        )
        newest_source="${source_mtime:-0}"
    fi

    package_mtime=$(/usr/bin/stat -f '%m' "$PROJECT_DIR/Package.swift" 2>/dev/null || echo 0)
    if [[ "$package_mtime" -gt "$newest_source" ]]; then
        newest_source="$package_mtime"
    fi

    binary_mtime=$(/usr/bin/stat -f '%m' "$BINARY" 2>/dev/null || echo 0)
    if [[ "$newest_source" -gt "$binary_mtime" ]]; then
        needs_build=1
    fi
fi

if [[ "$needs_build" -eq 1 ]]; then
    if ! /usr/bin/env swift build --package-path "$PROJECT_DIR" -c debug > "$BUILD_LOG" 2>&1; then
        /usr/bin/osascript <<OSA
set buildLog to POSIX file "$BUILD_LOG"
set logText to read buildLog
if (count characters of logText) > 3500 then
    set logText to text 1 thru 3500 of logText
end if
display alert "Plagadeon Notes: Build fehlgeschlagen" message logText as critical
OSA
        exit 1
    fi
fi

exec "$BINARY"
LAUNCHER

PROJECT_DIR="$PROJECT_DIR" /usr/bin/perl -pi -e 's|__PROJECT_DIR__|$ENV{PROJECT_DIR}|g' "$MACOS_DIR/launcher"
/usr/bin/sed "s|__PROJECT_DIR__|$PROJECT_DIR|g" "$PROJECT_DIR/scripts/AppLauncher.swift" > "$CONTENTS_DIR/AppLauncher.swift"
/usr/bin/swiftc -O "$CONTENTS_DIR/AppLauncher.swift" -o "$MACOS_DIR/launcher"
/bin/rm "$CONTENTS_DIR/AppLauncher.swift"
/bin/chmod +x "$MACOS_DIR/launcher"

echo "App-Bundle erstellt: $APP_DIR"
echo "Starte die App künftig per Doppelklick aus ~/Applications (ohne Terminalfenster)."
