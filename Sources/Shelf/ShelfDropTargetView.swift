import AppKit
import SwiftUI

/// Native AppKit `NSDraggingDestination` bridge for receiving file URL drops with zero disk duplication.
public struct ShelfDropTargetView: NSViewRepresentable {
    @Binding public var isTargeted: Bool
    public let onDropURLs: ([URL]) -> Bool

    public init(isTargeted: Binding<Bool>, onDropURLs: @escaping ([URL]) -> Bool) {
        self._isTargeted = isTargeted
        self.onDropURLs = onDropURLs
    }

    public func makeNSView(context: Context) -> ShelfDropDestinationNSView {
        let view = ShelfDropDestinationNSView()
        view.onTargetChanged = { targeted in
            Task { @MainActor in
                self.isTargeted = targeted
            }
        }
        view.onDropURLs = onDropURLs
        return view
    }

    public func updateNSView(_ nsView: ShelfDropDestinationNSView, context: Context) {
        nsView.onDropURLs = onDropURLs
    }
}

/// Underlying `NSView` implementing `NSDraggingDestination` for `NSPasteboard.PasteboardType.fileURL`.
@MainActor
public final class ShelfDropDestinationNSView: NSView {
    public var onTargetChanged: ((Bool) -> Void)?
    public var onDropURLs: (([URL]) -> Bool)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        // Allow normal SwiftUI clicks/scrolls/drags on subviews while still receiving drag-and-drop operations
        return nil
    }

    override public func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let canRead = sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
        guard canRead else { return [] }
        onTargetChanged?(true)
        return .copy
    }

    override public func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onTargetChanged?(false)
    }

    override public func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        return true
    }

    override public func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onTargetChanged?(false)
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else {
            return false
        }
        return onDropURLs?(urls) ?? false
    }
}
