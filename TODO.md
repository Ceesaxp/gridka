# Gridka — TODO

## App Store Release Preparation

- [x] Fix & rewrite README.md (rename from RAEDME.md, add badges, rewrite content)
- [x] Populate LICENSE.md with MIT license
- [x] Create CHANGELOG.md from git history
- [x] Rewrite HelpWindowController with tabbed help (Getting Started, Shortcuts, Filtering, Tips, About)
- [x] Create Gridka.entitlements (sandbox + user-selected file read-only)
- [x] Create GridkaQuickLook.entitlements (minimal sandbox)
- [x] Create Resources/PrivacyInfo.xcprivacy (privacy manifest for App Store)
- [x] Update project.yml (entitlements, code signing, hardened runtime, dylib signing)
- [x] Create scripts/build-release.sh (archive + export + validate + upload)
- [x] Create scripts/bump-version.sh (version + build number management)
- [x] Create docs/APP_STORE_SUBMISSION.md (manual steps guide)
- [x] Verify xcodegen + build succeeds with new configuration

## Field-Use Bug Fixes (2026-08-19)

- [x] Cmd-C/Cmd-V/Cmd-X inside a cell being edited (standard Edit menu items, responder chain)
- [x] Save over the same file — DuckDB `USE_TMP_FILE false` (sandbox denies the sibling `tmp_` write)
- [x] Save As failing with the same sandbox error (all four COPY TO sites)
- [x] Save As accessory view clipped in the narrower macOS 27 save panel
- [x] Cmd-Delete during cell editing no longer deletes selected rows
