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

# Generate dSYM for the vendored libduckdb.dylib and inject it into the archive.
# The dylib is a pre-built binary without DWARF, but dsymutil still produces a
# valid dSYM with the correct UUIDs, which satisfies App Store symbol validation.
DYLIB_IN_ARCHIVE="$ARCHIVE_PATH/Products/Applications/Gridka.app/Contents/Frameworks/libduckdb.dylib"
DSYM_DIR="$ARCHIVE_PATH/dSYMs"
if [ -f "$DYLIB_IN_ARCHIVE" ]; then
    echo "==> Generating dSYM for libduckdb.dylib..."
    mkdir -p "$DSYM_DIR"
    dsymutil "$DYLIB_IN_ARCHIVE" -o "$DSYM_DIR/libduckdb.dylib.dSYM" 2>&1 || true
    echo "    dSYM placed in: $DSYM_DIR/libduckdb.dylib.dSYM"
fi

echo "==> Exporting archive..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    | tail -10

echo "==> Export complete: $EXPORT_PATH"

# altool looks for AuthKey_<ID>.p8 in ~/private_keys, ~/.private_keys, or
# ~/.appstoreconnect/private_keys.  If APP_STORE_API_KEY_PATH points to the
# .p8 file, copy it into ~/.private_keys/ so altool can find it.
setup_api_key() {
    if [ -n "${APP_STORE_API_KEY_PATH:-}" ] && [ -f "${APP_STORE_API_KEY_PATH}" ]; then
        mkdir -p ~/.private_keys
        cp -f "${APP_STORE_API_KEY_PATH}" ~/.private_keys/
        echo "    Copied API key to ~/.private_keys/"
    fi
    if [ -z "${APP_STORE_API_KEY:-}" ] || [ -z "${APP_STORE_API_ISSUER:-}" ]; then
        echo "ERROR: APP_STORE_API_KEY and APP_STORE_API_ISSUER must be set."
        echo "  Optionally set APP_STORE_API_KEY_PATH to the .p8 file location."
        exit 1
    fi
}

if [ "$VALIDATE" = true ]; then
    echo "==> Validating..."
    setup_api_key
    xcrun altool --validate-app \
        -f "$EXPORT_PATH/Gridka.pkg" \
        -t macos \
        --apiKey "${APP_STORE_API_KEY}" \
        --apiIssuer "${APP_STORE_API_ISSUER}"
    echo "==> Validation passed."
fi

if [ "$UPLOAD" = true ]; then
    echo "==> Uploading to App Store Connect..."
    setup_api_key
    xcrun altool --upload-app \
        -f "$EXPORT_PATH/Gridka.pkg" \
        -t macos \
        --apiKey "${APP_STORE_API_KEY}" \
        --apiIssuer "${APP_STORE_API_ISSUER}"
    echo "==> Upload complete."
fi

echo "==> Done."
