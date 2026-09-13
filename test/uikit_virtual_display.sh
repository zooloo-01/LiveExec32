#!/bin/sh
# Requires an already booted Simulator. --build-only only compiles the fixture.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_only=0
device=booted
while [ "$#" -gt 0 ]; do
    case "$1" in
        --build-only) build_only=1; shift ;;
        --device) device=$2; shift 2 ;;
        *) echo "usage: $0 [--build-only] [--device UDID]" >&2; exit 2 ;;
    esac
done
work=$(mktemp -d "${TMPDIR:-/tmp}/lc32-display.XXXXXX")
app="$work/DisplayTest.app"
identifier="org.liveexec32.displaytest.$(basename "$work" | tr -cd '[:alnum:]')"
installed=0
cleanup() {
    if [ "$installed" -eq 1 ]; then
        perl -e 'alarm 15; exec @ARGV; die "exec: $!\n"' \
            xcrun simctl uninstall "$device" "$identifier" >/dev/null 2>&1 || :
    fi
    echo "Virtual display test artifacts: $work"
}
trap cleanup EXIT
mkdir -p "$app"
cat > "$app/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$identifier</string>
<key>CFBundleExecutable</key><string>DisplayTest</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleName</key><string>DisplayTest</string>
<key>MinimumOSVersion</key><string>15.0</string>
<key>UILaunchScreen</key><dict/>
</dict></plist>
EOF
arch=$(uname -m)
xcrun --sdk iphonesimulator clang -target "$arch-apple-ios15.0-simulator" \
    -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -framework UIKit -framework QuartzCore -framework Foundation -framework CoreGraphics \
    "$repo/test/uikit_virtual_display.m" "$repo/test/uikit_legacy_display.mm" \
    "$repo/HostFrameworks/UIKit/LegacyDisplay.mm" -lc++ -o "$app/DisplayTest"
codesign --force --sign - "$app"
if [ "$build_only" -eq 1 ]; then exit 0; fi
xcrun simctl install "$device" "$app"
installed=1
# Bound application startup and preserve output; simctl exit alone is not
# evidence of success, so require the fixture's explicit result below.
perl -e 'alarm 45; exec @ARGV; die "exec: $!\n"' \
    xcrun simctl launch --console "$device" "$identifier" > "$work/result.log" 2>&1
cat "$work/result.log"
grep -q 'virtual display UIKit: PASS' "$work/result.log"
grep -q 'legacy display production UIKit: PASS' "$work/result.log"
! grep -q 'FAIL' "$work/result.log"
