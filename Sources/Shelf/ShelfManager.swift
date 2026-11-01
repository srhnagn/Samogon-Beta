import AppKit
import Observation
import QuickLookThumbnailing
import Quartz

/// Coordinates the Zero-Copy File Shelf, asynchronous QuickLook thumbnail generation, and native QuickLook previews.
@MainActor
@Observable
public final class ShelfManager: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    public private(set) var items: [ShelfItem] = []
    public var selectedItemID: UUID?
    public var isDropTargeted: Bool = false
    /// Incremented when an async thumbnail finishes rendering so SwiftUI cards update immediately.
    public private(set) var thumbnailRevision: Int = 0

    private static let bookmarksStorageKey = "com.zerotrust.aero.shelfBookmarks"

    public var onItemsChanged: ((Int) -> Void)?

    public override init() {
        super.init()
        restorePersistedBookmarks()
    }

    private func restorePersistedBookmarks() {
        guard let savedBookmarks = UserDefaults.standard.array(forKey: Self.bookmarksStorageKey) as? [Data] else {
            return
        }
        for data in savedBookmarks {
            if let restored = ShelfItem(bookmarkData: data) {
                items.append(restored)
                generateThumbnailAsync(for: restored)
            }
        }
        selectedItemID = items.first?.id
    }

    private func persistBookmarks() {
        let dataList = items.compactMap(\.bookmarkData)
        UserDefaults.standard.set(dataList, forKey: Self.bookmarksStorageKey)
    }

    // MARK: - Computed Metrics

    public var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.fileSize }
    }

    public var formattedTotalBytes: String {
        totalBytes.aeroFormattedBytes
    }

    public var selectedItem: ShelfItem? {
        guard let selectedItemID else { return items.first }
        return items.first(where: { $0.id == selectedItemID }) ?? items.first
    }

    // MARK: - Adding & Deduplicating Files

    @discardableResult
    public func addFileURLs(_ urls: [URL]) -> Bool {
        var addedAny = false
        for url in urls where url.isFileURL {
            let standardized = url.standardizedFileURL
            // Prevent duplicate entries for the exact same file path
            if items.contains(where: { $0.originalURL.standardizedFileURL == standardized }) {
                continue
            }

            let newItem = ShelfItem(url: standardized)
            items.insert(newItem, at: 0)
            if selectedItemID == nil {
                selectedItemID = newItem.id
            }
            addedAny = true
            generateThumbnailAsync(for: newItem)
        }

        if addedAny {
            persistBookmarks()
            AeroHaptics.playAlignmentTap()
            onItemsChanged?(items.count)
            reloadQuickLookIfNeeded()
        }
        return addedAny
    }

    // MARK: - Async QLThumbnailGenerator

    private func generateThumbnailAsync(for item: ShelfItem) {
        let scale = NSScreen.aeroTargetScreen?.backingScaleFactor ?? 2.0
        let size = CGSize(width: 72, height: 72)
        let request = QLThumbnailGenerator.Request(
            fileAt: item.resolvedURL,
            size: size,
            scale: scale,
            representationTypes: .all
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self, weak item] representation, _ in
            guard let nsImage = representation?.nsImage else { return }
            Task { @MainActor [weak self, weak item] in
                guard let self, let item else { return }
                item.thumbnail = nsImage
                self.thumbnailRevision &+= 1
            }
        }
    }

    // MARK: - File Shelf Actions

    public func copyAbsolutePath(for item: ShelfItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.resolvedURL.path(percentEncoded: false), forType: .string)
    }

    public func revealInFinder(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.resolvedURL])
    }

    public func removeItem(_ item: ShelfItem) {
        item.releaseSecurityScope()
        items.removeAll { $0.id == item.id }
        if selectedItemID == item.id {
            selectedItemID = items.first?.id
        }
        persistBookmarks()
        onItemsChanged?(items.count)
        reloadQuickLookIfNeeded()
    }

    public func clearAll() {
        for item in items {
            item.releaseSecurityScope()
        }
        items.removeAll()
        selectedItemID = nil
        persistBookmarks()
        onItemsChanged?(0)
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() {
            panel.orderOut(nil)
        }
    }

    // MARK: - QuickLook Preview (Spacebar)

    public func toggleQuickLookPreview() {
        guard !items.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.dataSource = self
            panel.delegate = self
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }

    private func reloadQuickLookIfNeeded() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              panel.isVisible else { return }
        panel.reloadData()
    }

    // MARK: - QLPreviewPanelDataSource

    public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedItem == nil ? 0 : 1
    }

    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard let item = selectedItem else { return nil }
        return item.resolvedURL as NSURL
    }
}
