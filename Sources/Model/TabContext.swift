import AppKit

/// Represents the per-file state for a single tab.
/// Each tab owns its own FileSession, TableViewController, and container view.
/// When multi-tab support is enabled, switching tabs swaps the containerView
/// in and out of the window's content view.
final class TabContext {

    /// The file session for this tab (nil if empty/new tab).
    var fileSession: FileSession?

    /// The table view controller for this tab (nil if showing empty state).
    var tableViewController: TableViewController?

    /// The container view for this tab's content (either the TVC view or the empty state view).
    /// This is the top-level view that gets added to the window's content view.
    var containerView: NSView?

    /// The empty state view shown when no file is loaded.
    var emptyStateView: NSView?

    /// Whether this tab is in the empty state (no file loaded).
    var isEmptyState: Bool {
        return fileSession == nil
    }
}
