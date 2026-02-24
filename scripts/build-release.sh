#!/usr/bin/env bash
set -euo pipefail

# Build, archive, and export Gridka for Mac App Store submission.
#
# Usage:
#   ./scripts/build-release.sh                    # Archive + export
#   ./scripts/build-release.sh --validate         # Also validate the archive
#   ./scripts/build-release.sh --upload            # Also upload to App Store Connect

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SCHEME="Gridka"
CONFIGURATION="Release"
ARCHIVE_PATH="$PROJECT_DIR/build/Gridka.xcarchive"
EXPORT_PATH="$PROJECT_DIR/build/export"
EXPORT_OPTIONS_PLIST="$PROJECT_DIR/scripts/ExportOptions.plist"

VALIDATE=false
UPLOAD=false

for arg in "$@"; do
    case "$arg" in
        --validate) VALIDATE=true ;;
        --upload)   UPLOAD=true ;;
        --help|-h)
            echo "Usage: $0 [--validate] [--upload]"
            echo "  --validate   Validate the archive after export"
            echo "  --upload     Upload to App Store Connect after export"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg"
            exit 1
            ;;
    esac
done

# Create ExportOptions.plist if it doesn't exist
if [ ! -f "$EXPORT_OPTIONS_PLIST" ]; then
    cat > "$EXPORT_OPTIONS_PLIST" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST
    echo "Created $EXPORT_OPTIONS_PLIST"
fi

echo "==> Regenerating Xcode project..."
cd "$PROJECT_DIR"
xcodegen generate

echo "==> Cleaning build directory..."
rm -rf "$PROJECT_DIR/build"
mkdir -p "$PROJECT_DIR/build"

echo "==> Building archive..."
xcodebuild archive \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    CODE_SIGN_STYLE=Automatic \
    ENABLE_HARDENED_RUNTIME=YES \
    | tail -20

echo "==> Archive created at: $ARCHIVE_PATH"

echo "==> Exporting archive..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    | tail -10

echo "==> Export complete: $EXPORT_PATH"

if [ "$VALIDATE" = true ]; then
    echo "==> Validating..."
    xcrun altool --validate-app \
        -f "$EXPORT_PATH/Gridka.pkg" \
        -t macos \
        --apiKey "${APP_STORE_API_KEY:-}" \
        --apiIssuer "${APP_STORE_API_ISSUER:-}"
    echo "==> Validation passed."
fi

if [ "$UPLOAD" = true ]; then
    echo "==> Uploading to App Store Connect..."
    xcrun altool --upload-app \
        -f "$EXPORT_PATH/Gridka.pkg" \
        -t macos \
        --apiKey "${APP_STORE_API_KEY:-}" \
        --apiIssuer "${APP_STORE_API_ISSUER:-}"
    echo "==> Upload complete."
fi

echo "==> Done."
