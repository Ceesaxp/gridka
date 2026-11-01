#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo 'ERROR: this regression check requires native Apple Silicon macOS' >&2
    exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/gridka-quicklook.XXXXXX")"
trap 'rm -rf "$work"' EXIT

git rev-parse HEAD
sw_vers
xcodebuild -version
xcrun swiftc --version

# Build only the extension. No DuckDB download, app tests, or Finder registration.
xcodebuild -project Gridka.xcodeproj -target GridkaQuickLook \
    -configuration Release SDKROOT=macosx ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    SYMROOT="$work/products" OBJROOT="$work/objects" \
    CODE_SIGN_IDENTITY='' CODE_SIGNING_ALLOWED=NO build

appex="$work/products/Release/GridkaQuickLook.appex"
plist="$appex/Contents/Info.plist"
binary="$appex/Contents/MacOS/GridkaQuickLook"
test "$(lipo -archs "$binary")" = arm64

# Re-sign only a disposable copy without hardened runtime to permit the probe.
# Production signing settings and entitlements remain unchanged.
cp "$binary" "$work/extension-probe"
codesign --force --sign - "$work/extension-probe"
xcrun clang -arch arm64 -mmacosx-version-min=14.0 -O2 -fobjc-arc -dynamiclib \
    ci_scripts/quicklook/runtime-probe.m -framework Foundation -framework Quartz \
    -o "$work/runtime-probe.dylib"
codesign --force --sign - "$work/runtime-probe.dylib"

probe() {
    GRIDKA_QUICKLOOK_PLIST="$1" DYLD_INSERT_LIBRARIES="$work/runtime-probe.dylib" "$2"
}

echo '== Release arm64 extension runtime checks =='
probe "$plist" "$work/extension-probe" | tee "$work/positive.txt"
grep -q 'Quick Look runtime probe: 0 failure(s)' "$work/positive.txt"

# Negative control: compile the pre-fix declaration at -O with the same module
# name. The positive check above always uses the actual Xcode-built executable.
sed 's/: QLPreviewProvider, QLPreviewingController/: QLPreviewProvider/' \
    QuickLookExtension/PreviewProvider.swift > "$work/PreviewProvider.swift"
printf 'import Foundation\nexit(2)\n' > "$work/main.swift"
xcrun swiftc -O -whole-module-optimization -target arm64-apple-macosx14.0 \
    -module-name GridkaQuickLook "$work/PreviewProvider.swift" "$work/main.swift" \
    -o "$work/missing-conformance"
echo '== Negative control: missing protocol conformance =='
if probe "$plist" "$work/missing-conformance" > "$work/negative.txt" 2>&1; then
    echo 'ERROR: missing conformance was not detected' >&2
    exit 1
fi
cat "$work/negative.txt"
grep -q '^FAIL QLPreviewingController conformance$' "$work/negative.txt"
grep -q '^FAIL own Objective-C preview callback$' "$work/negative.txt"

# Negative control for the original plist layout, using the fixed executable.
plutil -convert xml1 -o "$work/legacy.plist" "$plist"
/usr/libexec/PlistBuddy -c 'Delete :NSExtension:NSExtensionAttributes' "$work/legacy.plist"
/usr/libexec/PlistBuddy -c 'Add :QLSupportsSearchableItems bool false' "$work/legacy.plist"
/usr/libexec/PlistBuddy -c 'Add :QLSupportedContentTypes array' "$work/legacy.plist"
/usr/libexec/PlistBuddy -c 'Add :QLSupportedContentTypes:0 string public.tab-separated-values-text' "$work/legacy.plist"
echo '== Negative control: legacy plist layout =='
if probe "$work/legacy.plist" "$work/extension-probe" > "$work/legacy.txt" 2>&1; then
    echo 'ERROR: legacy plist layout was not detected' >&2
    exit 1
fi
cat "$work/legacy.txt"
grep -q '^FAIL data-based preview flag$' "$work/legacy.txt"
grep -q '^FAIL attributes nested only: QLSupportedContentTypes$' "$work/legacy.txt"

echo 'PASS Release arm64 runtime checks and both negative controls; Finder GUI not exercised'
