import AppKit
import UniformTypeIdentifiers

final class DragDropView: NSView {

    var onFileDrop: ((URL) -> Void)?

    private static let supportedExtensions: Set<String> = ["csv", "tsv", "txt", "dsv"]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard fileURL(from: sender) != nil else { return [] }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard fileURL(from: sender) != nil else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = fileURL(from: sender) else { return false }
        onFileDrop?(url)
        return true
    }

    // MARK: - Private

    private func fileURL(from draggingInfo: NSDraggingInfo) -> URL? {
        guard let items = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], let url = items.first else {
            return nil
        }

        let ext = url.pathExtension.lowercased()
        guard DragDropView.supportedExtensions.contains(ext) else { return nil }
        return url
    }
}
