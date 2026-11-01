import SwiftUI

/// Root SwiftUI view hosted inside `NotchWindowController` that morphs across all four `NotchInteractionState` modes.
public struct NotchRootContainerView: View {
    @Bindable var screenState: ScreenNotchState
    @Bindable var appState: AppState

    public init(screenState: ScreenNotchState) {
        self.screenState = screenState
        self.appState = screenState.appState
    }

    public var body: some View {
        ZStack(alignment: .top) {
            // Pure #000000 hardware-blended Notch vessel
            AeroNotchShape(
                topCornerRadius: 9,
                bottomCornerRadius: screenState.interactionState == .expanded || screenState.interactionState == .dragOver ? 22 : 12
            )
            .fill(Color.aeroPitchBlack)
            .overlay(
                AeroNotchShape(
                    topCornerRadius: 9,
                    bottomCornerRadius: screenState.interactionState == .expanded || screenState.interactionState == .dragOver ? 22 : 12
                )
                .stroke(
                    screenState.interactionState == .dragOver
                        ? Color.aeroEmerald.opacity(0.65)
                        : (screenState.interactionState == .idle ? Color.clear : Color.aeroBorder),
                    lineWidth: screenState.interactionState == .dragOver ? 1.4 : 0.7
                )
            )
            .shadow(
                color: .black.opacity(screenState.interactionState == .idle ? 0.0 : 0.65),
                radius: screenState.interactionState == .expanded ? 20 : 8,
                x: 0,
                y: 8
            )

            // Active State Content with Apple Dynamic Island top-anchored morphing transitions
            Group {
                switch screenState.interactionState {
                case .idle, .hover:
                    NotchPillView(screenState: screenState)
                        .transition(
                            .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                        )
                case .dragOver:
                    NotchDragOverPromptView(screenState: screenState)
                        .transition(
                            .opacity.combined(with: .scale(scale: 0.92, anchor: .top))
                        )
                case .expanded:
                    NotchExpandedView(screenState: screenState)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.93, anchor: .top)),
                                removal: .opacity.combined(with: .scale(scale: 0.90, anchor: .top))
                            )
                        )
                }
            }
        }
        .frame(
            width: screenState.currentContainerWidth,
            height: screenState.currentContainerHeight,
            alignment: .top
        )
        .clipShape(
            AeroNotchShape(
                topCornerRadius: 9,
                bottomCornerRadius: screenState.interactionState == .expanded || screenState.interactionState == .dragOver ? 22 : 12
            )
        )
        .animation(
            .spring(response: 0.36, dampingFraction: 0.83, blendDuration: 0.12),
            value: screenState.interactionState
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Drag-Over Instant Shelf Prompt

public struct NotchDragOverPromptView: View {
    @Bindable var screenState: ScreenNotchState

    public var body: some View {
        VStack(spacing: 12) {
            // Keep physical notch clearance at the top
            Spacer()
                .frame(height: screenState.geometry.notchHeight - 4)

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
                    .foregroundStyle(Color.aeroEmerald.opacity(0.75))
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.aeroEmerald.opacity(0.07))
                    )

                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.aeroEmerald)

                    Text("Drop into Samogon Zero-Copy Shelf")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Security-scoped in-memory bookmark • 0 bytes duplicated on disk")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.vertical, 12)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
    }
}

// MARK: - Full Expanded Dashboard Container

public struct NotchExpandedView: View {
    @Bindable var screenState: ScreenNotchState
    @Bindable var appState: AppState

    public init(screenState: ScreenNotchState) {
        self.screenState = screenState
        self.appState = screenState.appState
    }

    public var body: some View {
        VStack(spacing: 10) {
            // Top bar flanking physical camera cutout
            expandedHeaderBar
                .frame(height: screenState.geometry.notchHeight)

            // Navigation & Quick Telemetry Strip
            sectionNavigationStrip

            // Main Modular Dashboard Workspace
            dashboardContentGrid
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 15)
    }

    // MARK: - Header Flanking Physical Cutout

    private var expandedHeaderBar: some View {
        HStack(spacing: 0) {
            // Left of physical camera notch: Samogon Faceted Brand Mark & Zero-Trust Air-Gap Title
            HStack(spacing: 5.5) {
                SamogonLogoMarkView(size: 13)

                Text("SAMOGON • AIR-GAPPED")
                    .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(.white.opacity(0.88))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Physical camera cutout reservation
            Spacer(minLength: screenState.geometry.notchWidth)

            // Right of physical camera notch: Quick Scroll Capture, AutoRaise, Launch-at-Login, Pin, Collapse, Quit
            HStack(spacing: 6) {
                Button {
                    appState.scrollingCaptureManager.startScrollingCapture()
                } label: {
                    ScrollingCaptureIconView(size: 11.5, color: .aeroEmerald)
                        .frame(width: 21, height: 21)
                        .background(Color.white.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Kaydırmalı Ekran Görüntüsü Al (Scrolling Capture)")

                Button {
                    appState.autoRaiseManager.toggleEnabled()
                } label: {
                    Image(systemName: appState.autoRaiseManager.isEnabled ? "cursorarrow.motionlines.click" : "cursorarrow")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(appState.autoRaiseManager.isEnabled ? Color.aeroEmerald : .white.opacity(0.45))
                        .frame(width: 21, height: 21)
                        .background(Color.white.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .help(appState.autoRaiseManager.isEnabled ? "AutoRaise (Focus Mouse): Açık" : "AutoRaise (Focus Mouse): Kapalı")

                Button {
                    appState.toggleLaunchAtLogin()
                } label: {
                    Image(systemName: appState.launchAtLogin ? "person.badge.key.fill" : "person.badge.key")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(appState.launchAtLogin ? Color.aeroEmerald : .white.opacity(0.45))
                        .frame(width: 21, height: 21)
                        .background(Color.white.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .help(appState.launchAtLogin ? "Login'de Başlat: Açık" : "Login'de Başlat: Kapalı")

                Button {
                    appState.togglePinned()
                } label: {
                    Image(systemName: appState.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(appState.isPinned ? Color.aeroAmber : .white.opacity(0.65))
                        .frame(width: 21, height: 21)
                        .background(Color.white.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .help(appState.isPinned ? "Sabitlemeyi Kaldır" : "Paneli Açık Sabitle (Pin)")

                Button {
                    screenState.collapse(force: true)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 21, height: 21)
                        .background(Color.white.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Kapat (Esc)")

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 21, height: 21)
                        .background(Color.white.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Samogon'dan Çık")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: - Section Switcher

    private var sectionNavigationStrip: some View {
        HStack(spacing: 5) {
            ForEach(DashboardSection.allCases) { section in
                let isSelected = appState.selectedSection == section
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        appState.setSection(section)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: section.systemImage)
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(section.rawValue)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(isSelected ? .black : .white.opacity(0.72))
                    .padding(.horizontal, 8.5)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(isSelected ? Color.white : Color.white.opacity(0.07))
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Status Badges
            HStack(spacing: 5) {
                if appState.isCaffeinateActive {
                    Label(appState.caffeinateBadgeText, systemImage: "bolt.fill")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.aeroAmber)
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 2.5)
                        .background(Color.aeroAmber.opacity(0.14), in: Capsule())
                }

                Label("0 Sockets", systemImage: "network.slash")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.aeroEmerald.opacity(0.9))
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 2.5)
                    .background(Color.aeroEmerald.opacity(0.12), in: Capsule())
            }
        }
    }

    // MARK: - Modular Dashboard Workspace

    @ViewBuilder
    private var dashboardContentGrid: some View {
        switch appState.selectedSection {
        case .all:
            HStack(spacing: 10) {
                // Left Column: Audio & Dual-Volume Mixer + IOKit Caffeinate Engine
                VStack(spacing: 8) {
                    AudioMediaCardView(audioManager: appState.audioManager)
                    CaffeinateControlView(powerManager: appState.powerManager)
                }
                .frame(width: 256)

                // Right Column: Zero-Copy File Shelf Dock
                ShelfView(shelfManager: appState.shelfManager)
            }
        case .tools:
            SwissKnifeToolsView(
                autoRaiseManager: appState.autoRaiseManager,
                scrollingCaptureManager: appState.scrollingCaptureManager
            )
        case .shelf:
            ShelfView(shelfManager: appState.shelfManager)
        case .media:
            AudioMediaCardView(audioManager: appState.audioManager, isFullTab: true)
        case .power:
            CaffeinateControlView(powerManager: appState.powerManager)
        }
    }
}
