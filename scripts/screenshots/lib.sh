#!/bin/bash
# lib.sh — Reusable functions for Gridka screenshot automation.
# Source this file from your screenshot scripts.
#
# Usage:
#   source "$(dirname "$0")/lib.sh"
#
# All functions use the APP_NAME variable and WINDOW_* geometry variables,
# which can be overridden before sourcing or after sourcing this file.

# ─── Configuration (override any of these before or after sourcing) ──────

APP_NAME="${APP_NAME:-Gridka}"
SCREENSHOT_PADDING="${SCREENSHOT_PADDING:-80}"    # points of desktop padding
WINDOW_X="${WINDOW_X:-200}"                       # window left edge (points)
WINDOW_Y="${WINDOW_Y:-160}"                       # window top edge (points)
WINDOW_W="${WINDOW_W:-1280}"                      # window width (points)
WINDOW_H="${WINDOW_H:-740}"                       # window height (points)

# Target: 2880x1800 px on 2x Retina = 1440x900 pt capture region.
# capture_w = WINDOW_W + 2*PADDING = 1280 + 160 = 1440 pt → 2880 px
# capture_h = WINDOW_H + 2*PADDING =  740 + 160 =  900 pt → 1800 px

DELAY_SHORT="${DELAY_SHORT:-0.5}"
DELAY_MEDIUM="${DELAY_MEDIUM:-1.5}"
DELAY_LONG="${DELAY_LONG:-3.0}"
DELAY_FILE_LOAD="${DELAY_FILE_LOAD:-4.0}"

# ═══════════════════════════════════════════════════════════════════════════
#  App Lifecycle
# ═══════════════════════════════════════════════════════════════════════════

launch_app() {
    local app_path="${1:-}"
    echo "==> Launching ${APP_NAME}..."
    if [[ -n "$app_path" ]]; then
        open -a "$app_path"
    else
        open -a "$APP_NAME"
    fi
    sleep "$DELAY_LONG"
    activate_app
}

quit_app() {
    echo "==> Quitting ${APP_NAME}..."
    osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || true
    sleep "$DELAY_MEDIUM"
}

activate_app() {
    osascript -e "
        tell application \"${APP_NAME}\"
            activate
        end tell
        delay 0.3
    "
}

is_app_running() {
    pgrep -x "$APP_NAME" > /dev/null 2>&1
}

# ═══════════════════════════════════════════════════════════════════════════
#  Window Management
# ═══════════════════════════════════════════════════════════════════════════

set_window_geometry() {
    local x="${1:-$WINDOW_X}" y="${2:-$WINDOW_Y}" w="${3:-$WINDOW_W}" h="${4:-$WINDOW_H}"
    osascript -e "
        tell application \"System Events\"
            tell process \"${APP_NAME}\"
                set frontmost to true
                delay 0.2
                tell front window
                    set position to {${x}, ${y}}
                    set size to {${w}, ${h}}
                end tell
            end tell
        end tell
    "
    sleep "$DELAY_SHORT"
}

get_window_bounds() {
    # Returns: x,y,w,h as comma-separated string
    osascript -e "
        tell application \"System Events\"
            tell process \"${APP_NAME}\"
                set {x, y} to position of front window
                set {w, h} to size of front window
                return (x as text) & \",\" & (y as text) & \",\" & (w as text) & \",\" & (h as text)
            end tell
        end tell
    "
}

get_window_id() {
    # Returns the CGWindowID of the frontmost Gridka window
    osascript -l JavaScript -e "
        ObjC.import('CoreGraphics');
        var list = ObjC.deepUnwrap(
            $.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)
        );
        var wins = list.filter(function(w) {
            return w.kCGWindowOwnerName === '${APP_NAME}' && w.kCGWindowLayer === 0;
        });
        wins.length > 0 ? wins[0].kCGWindowNumber : -1;
    "
}

# ═══════════════════════════════════════════════════════════════════════════
#  Screenshot Capture
# ═══════════════════════════════════════════════════════════════════════════

capture_with_padding() {
    # Capture the window plus surrounding desktop area.
    # On Retina displays the output image is at native (2x) resolution.
    local output_file="$1"
    local padding="${2:-$SCREENSHOT_PADDING}"

    local bounds
    bounds=$(get_window_bounds)
    IFS=',' read -r wx wy ww wh <<< "$bounds"

    local cx=$((wx - padding))
    local cy=$((wy - padding))
    local cw=$((ww + 2 * padding))
    local ch=$((wh + 2 * padding))

    # Clamp to non-negative
    [[ $cx -lt 0 ]] && cx=0
    [[ $cy -lt 0 ]] && cy=0

    screencapture -x -R "${cx},${cy},${cw},${ch}" "$output_file"
    echo "    Saved: $output_file"
}

capture_window_only() {
    # Capture just the window with its drop shadow (no desktop).
    local output_file="$1"
    local wid
    wid=$(get_window_id)

    if [[ "$wid" == "-1" || -z "$wid" ]]; then
        echo "    WARNING: Could not find window ID, falling back to padded capture"
        capture_with_padding "$output_file" 20
        return
    fi

    screencapture -x -l "$wid" "$output_file"
    echo "    Saved: $output_file"
}

capture_full_screen() {
    # Capture the entire screen (for maximum resolution screenshots).
    local output_file="$1"
    screencapture -x "$output_file"
    echo "    Saved: $output_file"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Keyboard / Input
# ═══════════════════════════════════════════════════════════════════════════

send_keystroke() {
    # Send a keystroke with optional modifiers.
    # Usage:  send_keystroke "o" "command down"
    #         send_keystroke "d" "command down, shift down"
    #         send_keystroke "a"   (no modifier)
    local key="$1"
    local modifiers="${2:-}"

    if [[ -n "$modifiers" ]]; then
        osascript -e "
            tell application \"System Events\"
                tell process \"${APP_NAME}\"
                    keystroke \"${key}\" using {${modifiers}}
                end tell
            end tell
        "
    else
        osascript -e "
            tell application \"System Events\"
                tell process \"${APP_NAME}\"
                    keystroke \"${key}\"
                end tell
            end tell
        "
    fi
}

send_key_code() {
    # Send a key code (for non-character keys).
    # Common codes: Return=36, Tab=48, Escape=53, Delete=51, Space=49,
    #               DownArrow=125, UpArrow=126, LeftArrow=123, RightArrow=124
    local code="$1"
    local modifiers="${2:-}"

    if [[ -n "$modifiers" ]]; then
        osascript -e "
            tell application \"System Events\"
                tell process \"${APP_NAME}\"
                    key code ${code} using {${modifiers}}
                end tell
            end tell
        "
    else
        osascript -e "
            tell application \"System Events\"
                tell process \"${APP_NAME}\"
                    key code ${code}
                end tell
            end tell
        "
    fi
}

type_text() {
    # Type a string of text into the currently focused field.
    local text="$1"
    osascript -e "
        tell application \"System Events\"
            tell process \"${APP_NAME}\"
                keystroke \"${text}\"
            end tell
        end tell
    "
}

# ═══════════════════════════════════════════════════════════════════════════
#  Mouse Operations  (uses CGEvent via JXA for precise coordinate control)
# ═══════════════════════════════════════════════════════════════════════════

click_at() {
    # Left-click at absolute screen coordinates (points).
    local x="$1" y="$2"
    osascript -l JavaScript -e "
        ObjC.import('CoreGraphics');
        var pt = $.CGPointMake(${x}, ${y});
        var down = $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseDown, pt, $.kCGMouseButtonLeft);
        $.CGEventPost($.kCGHIDEventTap, down);
        delay(0.05);
        var up = $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseUp, pt, $.kCGMouseButtonLeft);
        $.CGEventPost($.kCGHIDEventTap, up);
    "
}

right_click_at() {
    # Right-click at absolute screen coordinates (points).
    local x="$1" y="$2"
    osascript -l JavaScript -e "
        ObjC.import('CoreGraphics');
        var pt = $.CGPointMake(${x}, ${y});
        var down = $.CGEventCreateMouseEvent(null, $.kCGEventRightMouseDown, pt, $.kCGMouseButtonRight);
        $.CGEventPost($.kCGHIDEventTap, down);
        delay(0.05);
        var up = $.CGEventCreateMouseEvent(null, $.kCGEventRightMouseUp, pt, $.kCGMouseButtonRight);
        $.CGEventPost($.kCGHIDEventTap, up);
    "
}

click_relative() {
    # Click at a position relative to the window's top-left corner.
    # Usage: click_relative 200 150 [left|right]
    local rel_x="$1" rel_y="$2" button="${3:-left}"

    local bounds
    bounds=$(get_window_bounds)
    IFS=',' read -r wx wy _ww _wh <<< "$bounds"

    local abs_x=$((wx + rel_x))
    local abs_y=$((wy + rel_y))

    if [[ "$button" == "right" ]]; then
        right_click_at "$abs_x" "$abs_y"
    else
        click_at "$abs_x" "$abs_y"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  File Operations
# ═══════════════════════════════════════════════════════════════════════════

open_file() {
    # Open a file in Gridka using macOS open command.
    # Files are opened as new tabs when tabbingMode = .preferred.
    local filepath="$1"
    echo "    Opening: $(basename "$filepath")"
    open -a "$APP_NAME" "$filepath"
    sleep "$DELAY_FILE_LOAD"
}

open_file_via_dialog() {
    # Open a file using Cmd+O → Cmd+Shift+G → type path → Enter.
    # Use this when open_file() doesn't work as expected.
    local filepath="$1"
    echo "    Opening via dialog: $(basename "$filepath")"

    send_keystroke "o" "command down"
    sleep "$DELAY_MEDIUM"

    # "Go to Folder" sheet
    send_keystroke "g" "command down, shift down"
    sleep "$DELAY_SHORT"

    type_text "$(dirname "$filepath")"
    sleep "$DELAY_SHORT"
    send_key_code 36          # Return — navigate to folder
    sleep "$DELAY_MEDIUM"

    type_text "$(basename "$filepath")"
    sleep "$DELAY_SHORT"
    send_key_code 36          # Return — open the file
    sleep "$DELAY_FILE_LOAD"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Context Menu Helpers
# ═══════════════════════════════════════════════════════════════════════════

click_context_menu_item_starting_with() {
    # After a right-click, click the first context menu item whose name
    # starts with the given prefix.
    local prefix="$1"
    sleep "$DELAY_SHORT"
    osascript -e "
        tell application \"System Events\"
            tell process \"${APP_NAME}\"
                set found to false
                repeat with m in menus
                    if not found then
                        repeat with mi in menu items of m
                            if not found then
                                try
                                    if name of mi starts with \"${prefix}\" then
                                        click mi
                                        set found to true
                                    end if
                                end try
                            end if
                        end repeat
                    end if
                end repeat
            end tell
        end tell
    "
}

# ═══════════════════════════════════════════════════════════════════════════
#  Common UI State Shortcuts
# ═══════════════════════════════════════════════════════════════════════════

toggle_search() {
    echo "    Toggling search bar"
    send_keystroke "f" "command down"
    sleep "$DELAY_SHORT"
}

toggle_detail_pane() {
    echo "    Toggling detail pane"
    send_keystroke "d" "command down, shift down"
    sleep "$DELAY_SHORT"
}

new_tab() {
    echo "    Creating new tab"
    send_keystroke "t" "command down"
    sleep "$DELAY_MEDIUM"
}

close_tab() {
    send_keystroke "w" "command down"
    sleep "$DELAY_SHORT"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Utilities
# ═══════════════════════════════════════════════════════════════════════════

wait_for_user() {
    local message="${1:-Press Enter to continue...}"
    echo ""
    echo "    >>> $message"
    read -r
}

log_step() {
    local label="$1"
    echo ""
    echo "========================================================"
    echo "  $label"
    echo "========================================================"
}

ensure_dir() {
    mkdir -p "$1"
}
