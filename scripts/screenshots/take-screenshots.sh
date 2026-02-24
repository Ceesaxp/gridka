#!/bin/bash
# take-screenshots.sh — Capture Gridka App Store screenshots.
#
# Usage:
#   ./take-screenshots.sh [--state STATE] [--output DIR] [--interactive]
#
# Options:
#   --state STATE     Capture only this state (empty, loaded, filter, search,
#                     detail, large, tabs). Default: all states.
#   --output DIR      Output directory. Default: ~/Desktop/Gridka-Screenshots
#   --interactive     Pause before each capture for manual adjustments.
#   --large-csv PATH  Path to a large CSV file. Default: auto-generated.
#   --app-path PATH   Path to Gridka.app (if not in /Applications).
#   --help            Show this help message.
#
# Prerequisites:
#   - Gridka must be built and accessible (in /Applications or specified path)
#   - Accessibility permissions must be granted for Terminal / your terminal app
#     (System Settings → Privacy & Security → Accessibility)
#   - Screen Recording permission for screencapture with window padding
#   - A clean desktop wallpaper is recommended for professional screenshots
#
# The script generates test CSV data, then walks through each screenshot state
# using keyboard shortcuts and mouse automation via AppleScript/JXA.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# ─── Defaults ────────────────────────────────────────────────────────────

OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Desktop/Gridka-Screenshots}"
DATA_DIR="${DATA_DIR:-${SCRIPT_DIR}/data}"
INTERACTIVE="${INTERACTIVE:-false}"
CAPTURE_STATE="${CAPTURE_STATE:-all}"
LARGE_CSV_PATH=""
APP_PATH=""

# ─── Parse arguments ─────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --state)      CAPTURE_STATE="$2"; shift 2 ;;
        --output)     OUTPUT_DIR="$2";    shift 2 ;;
        --interactive) INTERACTIVE=true;  shift ;;
        --large-csv)  LARGE_CSV_PATH="$2"; shift 2 ;;
        --app-path)   APP_PATH="$2";      shift 2 ;;
        --help)
            head -25 "$0" | tail -22 | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ─── Resolve paths ───────────────────────────────────────────────────────

if [[ -z "$LARGE_CSV_PATH" ]]; then
    LARGE_CSV_PATH="${DATA_DIR}/sensor_telemetry.csv"
fi

# ─── Generate test data ──────────────────────────────────────────────────

"${SCRIPT_DIR}/generate-test-data.sh" "$DATA_DIR"

ensure_dir "$OUTPUT_DIR"

echo ""
echo "==> Screenshots will be saved to: ${OUTPUT_DIR}"
echo "==> Window geometry: ${WINDOW_W}x${WINDOW_H} at (${WINDOW_X}, ${WINDOW_Y})"
echo "==> Padding: ${SCREENSHOT_PADDING}pt"
echo ""

# ─── Helper: conditional pause ───────────────────────────────────────────

maybe_pause() {
    if [[ "$INTERACTIVE" == "true" ]]; then
        wait_for_user "${1:-Adjust the window if needed, then press Enter to capture.}"
    fi
}

# ─── Helper: should we capture this state? ───────────────────────────────

should_capture() {
    [[ "$CAPTURE_STATE" == "all" || "$CAPTURE_STATE" == "$1" ]]
}

# ═══════════════════════════════════════════════════════════════════════════
#  STATE 1: Empty State — drag-and-drop landing screen
# ═══════════════════════════════════════════════════════════════════════════

capture_empty() {
    log_step "1/7  Empty State"

    # Quit any existing instance
    quit_app 2>/dev/null || true
    sleep "$DELAY_SHORT"

    # Launch fresh (no file)
    if [[ -n "$APP_PATH" ]]; then
        launch_app "$APP_PATH"
    else
        launch_app
    fi

    set_window_geometry
    sleep "$DELAY_MEDIUM"

    maybe_pause "Empty state ready. Press Enter to capture."
    capture_with_padding "${OUTPUT_DIR}/01-empty-state.png"
}

# ═══════════════════════════════════════════════════════════════════════════
#  STATE 2: Loaded CSV — data visible, status bar showing row count
# ═══════════════════════════════════════════════════════════════════════════

capture_loaded() {
    log_step "2/7  Loaded CSV"

    open_file "${DATA_DIR}/sales_data.csv"
    sleep "$DELAY_MEDIUM"
    set_window_geometry
    sleep "$DELAY_SHORT"

    # Click on a cell to show selection and populate status bar detail
    # Click roughly at row 5, column 2 area (relative to window)
    click_relative 250 200 left
    sleep "$DELAY_SHORT"

    maybe_pause "Loaded CSV ready. Press Enter to capture."
    capture_with_padding "${OUTPUT_DIR}/02-loaded-csv.png"
}

# ═══════════════════════════════════════════════════════════════════════════
#  STATE 3: Filtering — filter applied, filter bar visible
# ═══════════════════════════════════════════════════════════════════════════

capture_filter() {
    log_step "3/7  Filtering"

    # Open a file with good filter targets
    open_file "${DATA_DIR}/world_cities.csv"
    sleep "$DELAY_MEDIUM"
    set_window_geometry
    sleep "$DELAY_SHORT"

    echo "    Applying filter via right-click context menu..."

    # Click on a cell in the "Country" column that has a filterable value.
    # With a 1280px wide window and ~10 columns, the "Country" column
    # (column 2) should be around x=200, and row 1 data around y=100
    # (accounting for title bar ~28 + header ~24 + some rows).
    # We'll click on a cell then use the context menu.

    # First, click on a cell (row ~3, "Country" column area)
    click_relative 200 130 left
    sleep "$DELAY_SHORT"

    # Right-click for context menu
    click_relative 200 130 right
    sleep "$DELAY_MEDIUM"

    # Click "Filter for This Value" in the context menu.
    # It's typically the 5th item (after Copy Cell, Copy Row, Copy w/ Headers, separator).
    osascript <<'APPLESCRIPT'
        tell application "System Events"
            tell process "Gridka"
                delay 0.3
                -- Look through menus for the filter item
                repeat with m in menus
                    try
                        set menuItemsList to every menu item of m
                        repeat with mi in menuItemsList
                            try
                                if name of mi starts with "Filter for" then
                                    click mi
                                    return
                                end if
                            end try
                        end repeat
                    end try
                end repeat
            end tell
        end tell
APPLESCRIPT
    sleep "$DELAY_MEDIUM"

    echo "    Filter applied."

    # Now right-click on the column header to show the filter popover
    # (so the screenshot shows both the filter chip AND an open popover).
    # Column headers start at roughly y=52 from the window top (after title bar).
    # We'll right-click on a different column header — the 3rd column (Population).
    click_relative 400 60 right
    sleep "$DELAY_MEDIUM"

    # Click the "Filter" menu item from the header context menu
    osascript <<'APPLESCRIPT'
        tell application "System Events"
            tell process "Gridka"
                delay 0.3
                repeat with m in menus
                    try
                        set menuItemsList to every menu item of m
                        repeat with mi in menuItemsList
                            try
                                if name of mi starts with "Filter" then
                                    click mi
                                    return
                                end if
                            end try
                        end repeat
                    end try
                end repeat
            end tell
        end tell
APPLESCRIPT
    sleep "$DELAY_MEDIUM"

    # Type a value in the filter popover (it should be focused on the value field)
    type_text "10000000"
    sleep "$DELAY_SHORT"

    maybe_pause "Filter state ready (popover should be open). Press Enter to capture."
    capture_with_padding "${OUTPUT_DIR}/03-filtering.png"

    # Press Escape to dismiss the popover
    send_key_code 53
    sleep "$DELAY_SHORT"
}

# ═══════════════════════════════════════════════════════════════════════════
#  STATE 4: Search — search bar active with results
# ═══════════════════════════════════════════════════════════════════════════

capture_search() {
    log_step "4/7  Search"

    # Open the employee directory (good search targets with names/departments)
    open_file "${DATA_DIR}/employees.csv"
    sleep "$DELAY_MEDIUM"
    set_window_geometry
    sleep "$DELAY_SHORT"

    # Open search bar
    toggle_search
    sleep "$DELAY_SHORT"

    # Type a search term
    type_text "Engineer"
    sleep "$DELAY_MEDIUM"

    # Click on one of the matching rows to show selection
    click_relative 300 180 left
    sleep "$DELAY_SHORT"

    maybe_pause "Search state ready. Press Enter to capture."
    capture_with_padding "${OUTPUT_DIR}/04-search.png"

    # Close search bar
    send_key_code 53   # Escape
    sleep "$DELAY_SHORT"
}

# ═══════════════════════════════════════════════════════════════════════════
#  STATE 5: Detail Pane — showing JSON content
# ═══════════════════════════════════════════════════════════════════════════

capture_detail() {
    log_step "5/7  Detail Pane"

    # Open API logs (has JSON in the Response Body column)
    open_file "${DATA_DIR}/api_logs.csv"
    sleep "$DELAY_MEDIUM"
    set_window_geometry
    sleep "$DELAY_SHORT"

    # Show detail pane
    toggle_detail_pane
    sleep "$DELAY_SHORT"

    # Click on the "Response Body" column of a row with a rich JSON response.
    # The Response Body is column 6 — at roughly x=800 with default column widths.
    # Click row 3 (the analytics dashboard response with nested JSON).
    click_relative 800 130 left
    sleep "$DELAY_MEDIUM"

    maybe_pause "Detail pane ready. Press Enter to capture."
    capture_with_padding "${OUTPUT_DIR}/05-detail-pane.png"
}

# ═══════════════════════════════════════════════════════════════════════════
#  STATE 6: Large File — big row count in status bar
# ═══════════════════════════════════════════════════════════════════════════

capture_large() {
    log_step "6/7  Large File"

    if [[ ! -f "$LARGE_CSV_PATH" ]]; then
        echo "    WARNING: Large CSV not found at: $LARGE_CSV_PATH"
        echo "    Skipping large file screenshot."
        return
    fi

    echo "    Loading large file (this may take a few seconds)..."
    open_file "$LARGE_CSV_PATH"
    # Give extra time for large file to load
    sleep 6
    set_window_geometry
    sleep "$DELAY_SHORT"

    # Click on a cell to populate the status bar
    click_relative 300 200 left
    sleep "$DELAY_SHORT"

    maybe_pause "Large file loaded. Press Enter to capture."
    capture_with_padding "${OUTPUT_DIR}/06-large-file.png"
}

# ═══════════════════════════════════════════════════════════════════════════
#  STATE 7: Multiple Tabs — several files open simultaneously
# ═══════════════════════════════════════════════════════════════════════════

capture_tabs() {
    log_step "7/7  Multiple Tabs"

    # Quit and relaunch for a clean slate
    quit_app
    sleep "$DELAY_SHORT"

    # Open the first file to launch the app
    echo "    Opening files as tabs..."
    open_file "${DATA_DIR}/sales_data.csv"
    set_window_geometry
    sleep "$DELAY_SHORT"

    # Open additional files — with tabbingMode = .preferred, these should
    # become tabs in the same window. Small delay between each.
    open_file "${DATA_DIR}/world_cities.csv"
    sleep "$DELAY_SHORT"

    open_file "${DATA_DIR}/products.csv"
    sleep "$DELAY_SHORT"

    open_file "${DATA_DIR}/employees.csv"
    sleep "$DELAY_SHORT"

    # Ensure the window is properly sized (tabs might affect it)
    set_window_geometry
    sleep "$DELAY_SHORT"

    # Click on the first tab (sales_data) to make it active and show data
    # Tab bar is at the very top of the window frame (within the title bar)
    click_relative 80 12 left
    sleep "$DELAY_MEDIUM"

    # Click a cell to populate status bar
    click_relative 300 200 left
    sleep "$DELAY_SHORT"

    maybe_pause "Multiple tabs ready. Press Enter to capture."
    capture_with_padding "${OUTPUT_DIR}/07-multiple-tabs.png"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Main
# ═══════════════════════════════════════════════════════════════════════════

main() {
    echo ""
    echo "================================================================"
    echo "  Gridka App Store Screenshot Automation"
    echo "================================================================"
    echo ""
    echo "  Ensure:"
    echo "    1. Gridka is built and accessible"
    echo "    2. Terminal has Accessibility permission"
    echo "    3. Terminal has Screen Recording permission"
    echo "    4. Desktop is clean (nice wallpaper, no clutter)"
    echo "    5. Menu bar is tidy (hide unnecessary icons)"
    echo ""

    if [[ "$INTERACTIVE" == "true" ]]; then
        wait_for_user "Press Enter to begin..."
    else
        echo "  Starting in 3 seconds... (use --interactive for manual control)"
        sleep 3
    fi

    # Capture requested states
    should_capture "empty"  && capture_empty
    should_capture "loaded" && capture_loaded
    should_capture "filter" && capture_filter
    should_capture "search" && capture_search
    should_capture "detail" && capture_detail
    should_capture "large"  && capture_large
    should_capture "tabs"   && capture_tabs

    # Done
    echo ""
    echo "================================================================"
    echo "  Done! Screenshots saved to:"
    echo "    ${OUTPUT_DIR}"
    echo ""
    ls -lh "${OUTPUT_DIR}"/*.png 2>/dev/null | awk '{print "    " $5 "  " $NF}'
    echo "================================================================"

    # Clean up — quit the app
    quit_app 2>/dev/null || true
}

main "$@"
