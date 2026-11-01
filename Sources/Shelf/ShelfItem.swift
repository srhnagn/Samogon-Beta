import AppKit
import Foundation
import UniformTypeIdentifiers

/// Represents an in-memory, zero-copy shelved file reference backed by a security-scoped URL bookmark.
@MainActor
public final class ShelfItem: Identifiable, Hashable {
    public let id: UUID
    public let originalURL: URL
    public let bookmarkData: Data?
    public let fileName: String
    public let fileSize: Int64
    public let fileExtension: String
    public let contentType: UTType?
    public let addedAt: Date

    /// Asynchronously populated thumbnail from `QLThumbnailGenerator`, falling back to the system UTType icon.
    public var thumbnail: NSImage

    private var isAccessingSecurityScope: Bool = false

    public init(url: URL) {
        self.id = UUID()
        self.originalURL = url
        self.fileName = url.lastPathComponent
        self.fileExtension = url.pathExtension.uppercased()
        self.addedAt = Date()

        // Acquire security scope if provided by sandbox/drag pasteboard
        self.isAccessingSecurityScope = url.startAccessingSecurityScopedResource()

        // Create an in-memory bookmark (zero physical file duplication on disk)
        self.bookmarkData = try? url.bookmarkData(
            options: [.minimalBookmark],
            includingResourceValuesForKeys: [.fileSizeKey, .contentTypeKey],
            relativeTo: nil
        )

        let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .totalFileAllocatedSizeKey])
        self.fileSize = Int64(resourceValues?.fileSize ?? resourceValues?.totalFileAllocatedSize ?? 0)
        self.contentType = resourceValues?.contentType

        // Immediate lightweight icon fallback until QuickLook thumbnail resolves
        let baseIcon = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        baseIcon.size = NSSize(width: 64, height: 64)
        self.thumbnail = baseIcon
    }

    /// Restores a shelved item from persisted bookmark data across app restarts.
    public convenience init?(bookmarkData: Data) {
        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), FileManager.default.fileExists(atPath: resolved.path(percentEncoded: false)) else {
            return nil
        }
        self.init(url: resolved)
    }

    /// Resolves the live URL from the in-memory bookmark if the file was moved while shelved.
    public var resolvedURL: URL {
        guard let bookmarkData else { return originalURL }
        var isStale = false
        if let resolved = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return resolved
        }
        return originalURL
    }

    public var formattedSize: String {
        fileSize > 0 ? fileSize.aeroFormattedBytes : "Folder / Package"
    }

    public func releaseSecurityScope() {
        if isAccessingSecurityScope {
            originalURL.stopAccessingSecurityScopedResource()
            isAccessingSecurityScope = false
        }
    }

    public nonisolated static func == (lhs: ShelfItem, rhs: ShelfItem) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
