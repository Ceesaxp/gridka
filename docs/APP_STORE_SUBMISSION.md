# App Store Submission Guide

Step-by-step instructions for submitting Gridka to the Mac App Store.

## Prerequisites

- Active Apple Developer Program membership ($99/year)
- Xcode 15.0+ with command-line tools installed
- XcodeGen installed (`brew install xcodegen`)
- DuckDB libraries in `Libraries/` (duckdb.h, libduckdb.a, libduckdb.dylib)

## 1. Apple Developer Portal Setup

### Register Bundle IDs

1. Go to [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list)
2. Register two App IDs:
   - **Gridka app:** `org.ceesaxp.gridka.app`
   - **Quick Look extension:** `org.ceesaxp.gridka.app.quicklook`
3. For each, enable the **App Sandbox** capability

### Configure Signing in Xcode

1. Open `Gridka.xcodeproj` in Xcode
2. Select the **Gridka** target → Signing & Capabilities
3. Check "Automatically manage signing"
4. Select your team
5. Repeat for the **GridkaQuickLook** target

## 2. App Store Connect Setup

### Create the App

1. Go to [App Store Connect](https://appstoreconnect.apple.com)
2. My Apps → "+" → New App
3. Fill in:
   - **Platform:** macOS
   - **Name:** Gridka
   - **Primary Language:** English (U.S.)
   - **Bundle ID:** org.ceesaxp.gridka.app
   - **SKU:** gridka-macos (or your preferred identifier)

### App Information

| Field | Value |
|-------|-------|
| Category | Utilities |
| Subcategory | Developer Tools (optional) |
| Age Rating | 4+ |
| Copyright | 2026 Gridka Contributors |

### App Description (suggested)

> **Gridka** — a lightning-fast CSV viewer for macOS.
>
> Open CSV and TSV files of any size — from a few rows to 100 million+ — with instant scrolling, sorting, filtering, and search. Powered by DuckDB's analytical engine, Gridka handles massive datasets while staying light on memory.
>
> **Key Features:**
> - Open any CSV/TSV file with automatic delimiter, encoding, and type detection
> - Smooth 60fps virtual scrolling at any file size
> - Click-to-sort with multi-column sort support
> - Type-aware column filters (text, numeric, date, boolean)
> - Global search across all columns
> - Column management: resize, reorder, hide/show, pin, auto-fit
> - Detail pane for inspecting long text, URLs, and JSON
> - Cell editing with save-back to CSV
> - Multi-tab interface
> - Quick Look extension for CSV preview in Finder
>
> Built as a native macOS app with AppKit. No Electron. No web views. Just fast, native performance.

### Keywords (suggested)

`csv, viewer, tsv, data, spreadsheet, duckdb, table, filter, search, large files`

### URLs

- **Support URL:** (your GitHub issues page or support page)
- **Marketing URL:** (optional — your GitHub repo)
- **Privacy Policy URL:** (required — can link to a simple page stating no data is collected)

## 3. Screenshots

### Required Sizes

Mac App Store requires screenshots in at least one of these sizes:

| Display | Resolution |
|---------|------------|
| MacBook Pro 16" | 2880 x 1800 |
| MacBook Pro 14" | 3024 x 1964 |
| iMac 27" | 2560 x 1440 |

### Suggested Screenshots (3-5)

1. **Empty state** — drag-and-drop landing screen
2. **Loaded CSV** — a large file with data visible, status bar showing row count
3. **Filtering** — filter popover open with an active filter applied
4. **Search** — search bar active with highlighted matches
5. **Detail pane** — detail pane open showing long text or JSON content

### Taking Screenshots

```bash
# Set your window to the right size, then:
screencapture -w ~/Desktop/gridka-screenshot-1.png
```

Or use Cmd+Shift+4, then Space, then click the window.

## 4. Build and Upload

### Option A: Using the build script

```bash
# Make scripts executable
chmod +x scripts/build-release.sh scripts/bump-version.sh

# Set the version
./scripts/bump-version.sh 1.0.0

# Build, archive, and export
./scripts/build-release.sh

# To also validate:
./scripts/build-release.sh --validate

# To upload:
./scripts/build-release.sh --upload
```

For `--validate` and `--upload`, set these environment variables:
```bash
export APP_STORE_API_KEY="your-api-key-id"
export APP_STORE_API_ISSUER="your-issuer-id"
```

You can create an API key in [App Store Connect → Users and Access → Keys](https://appstoreconnect.apple.com/access/api).

### Option B: Using Xcode Organizer

1. In Xcode: Product → Archive
2. When archive completes, Organizer opens automatically
3. Click "Distribute App"
4. Select "App Store Connect"
5. Follow the prompts

## 5. DuckDB dylib Signing

The embedded `libduckdb.dylib` must be code-signed with your team identity. The build process handles this via the copy-files build phase in `project.yml`, but verify before uploading:

```bash
# Check signing on the dylib inside the archive
codesign -dv --verbose=4 \
    build/Gridka.xcarchive/Products/Applications/Gridka.app/Contents/Frameworks/libduckdb.dylib
```

You should see your Team ID in the output. If the dylib is unsigned:

```bash
codesign --force --sign "Apple Distribution: Your Name (TEAMID)" \
    path/to/Gridka.app/Contents/Frameworks/libduckdb.dylib
```

## 6. Submit for Review

1. In App Store Connect, go to your app → App Store tab
2. Select the build you uploaded
3. Fill in any remaining metadata
4. Click "Submit for Review"

### Review Notes (optional, helps reviewers)

> Gridka is a CSV file viewer. To test: open the app, then use File → Open (Cmd+O) to open any .csv or .tsv file. You can also drag and drop a CSV file onto the app window. A sample CSV file is available at: [provide URL to a sample CSV].

## Troubleshooting

### "The app references non-public selectors"
Check that no private API usage crept in. Run:
```bash
xcrun altool --validate-app -f build/export/Gridka.pkg -t macos
```

### "Missing privacy manifest"
Ensure `Resources/PrivacyInfo.xcprivacy` is included in the build. Check that `project.yml` has the Resources path in the `sources` section.

### "Code signing error"
1. Verify your provisioning profiles are up to date
2. In Xcode → Preferences → Accounts, refresh your certificates
3. Make sure both bundle IDs are registered in the Developer Portal

### "Sandbox violation" during testing
If the app crashes under sandbox, check Console.app for sandbox denial logs. Common issues:
- DuckDB trying to write temp files outside allowed paths
- File access outside user-selected scope
