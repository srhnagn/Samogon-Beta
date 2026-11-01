import AppKit
import SwiftUI

/// Horizontal dock and drop-zone card view for the Zero-Copy File Shelf.
public struct ShelfView: View {
    @Bindable var shelfManager: ShelfManager

    public init(shelfManager: ShelfManager) {
        self.shelfManager = shelfManager
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            shelfHeader

            ZStack {
                if shelfManager.items.isEmpty {
                    emptyShelfPrompt
                } else {
                    shelvedItemsDock
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.aeroSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            shelfManager.isDropTargeted ? Color.aeroEmerald : Color.white.opacity(0.08),
                            lineWidth: shelfManager.isDropTargeted ? 1.5 : 1.0
                        )
                )
        )
    }

    // MARK: - Header Bar

    private var shelfHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.aeroEmerald)

            Text("FILE SHELF")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.65))

            if !shelfManager.items.isEmpty {
                Text("\(shelfManager.items.count) • \(shelfManager.formattedTotalBytes)")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.aeroEmerald)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.aeroEmerald.opacity(0.14), in: Capsule())
            }

            Spacer()

            if !shelfManager.items.isEmpty {
                Button {
                    shelfManager.toggleQuickLookPreview()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 9))
                        Text("Space")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Color.white.opacity(0.09), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("QuickLook Selected Item (Spacebar)")

                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        shelfManager.clearAll()
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 20, height: 20)
                        .background(Color.white.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Clear All Shelved Bookmarks")
            }
        }
    }

    // MARK: - Empty Drop Prompt

    private var emptyShelfPrompt: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus.viewfinder")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(shelfManager.isDropTargeted ? Color.aeroEmerald : .white.opacity(0.35))

            Text("Drop files here for Zero-Copy Shelf")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))

            Text("In-memory bookmarks • Drag out anywhere • Space for QuickLook")
                .font(.system(size: 9.5, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
                .foregroundStyle(shelfManager.isDropTargeted ? Color.aeroEmerald : Color.white.opacity(0.14))
        )
    }

    // MARK: - Horizontal Shelved File Cards

    private var shelvedItemsDock: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(shelfManager.items) { item in
                    ShelfItemCard(
                        item: item,
                        isSelected: shelfManager.selectedItemID == item.id,
                        thumbnailRevision: shelfManager.thumbnailRevision,
                        onSelect: {
                            shelfManager.selectedItemID = item.id
                        },
                        onQuickLook: {
                            shelfManager.selectedItemID = item.id
                            shelfManager.toggleQuickLookPreview()
                        },
                        onCopyPath: {
                            shelfManager.copyAbsolutePath(for: item)
                        },
                        onReveal: {
                            shelfManager.revealInFinder(item)
                        },
                        onRemove: {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                                shelfManager.removeItem(item)
                            }
                        },
                        onClearAll: {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                                shelfManager.clearAll()
                            }
                        }
                    )
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 2)
        }
    }
}

// MARK: - Individual Shelved File Card

private struct ShelfItemCard: View {
    let item: ShelfItem
    let isSelected: Bool
    let thumbnailRevision: Int
    let onSelect: () -> Void
    let onQuickLook: () -> Void
    let onCopyPath: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void
    let onClearAll: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: item.thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 2)
                    .id(thumbnailRevision)

                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.75))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
            .padding(.top, 4)

            Text(item.fileName)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 84)

            Text(item.formattedSize)
                .font(.system(size: 8.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.aeroEmerald.opacity(0.8) : Color.white.opacity(0.08),
                            lineWidth: isSelected ? 1.2 : 0.8
                        )
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(count: 2, perform: onQuickLook)
        .onTapGesture(count: 1, perform: onSelect)
        .onDrag {
            NSItemProvider(object: item.resolvedURL as NSURL)
        }
        .contextMenu {
            Button("QuickLook Preview (Space)", action: onQuickLook)
            Divider()
            Button("Copy Absolute Path", action: onCopyPath)
            Button("Reveal in Finder", action: onReveal)
            Divider()
            Button("Remove from Shelf", role: .destructive, action: onRemove)
            Button("Clear All", role: .destructive, action: onClearAll)
        }
    }
}
