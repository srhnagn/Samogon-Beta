import AppKit
import CoreGraphics
import Observation
import ServiceManagement
import SwiftUI

/// Represents the four primary lifecycle states of the Aero Notch surface on a display.
public enum NotchInteractionState: String, Equatable, Sendable {
    /// Collapsed within or hugging the physical camera cutout (minimal 2px ambient lip).
    case idle
    /// Mouse entered tracking region; expands into the interactive mini status pill.
    case hover
    /// File(s) dragged near the notch; dynamically opens the File Shelf drop target.
    case dragOver
    /// Full Aero Dashboard toggled open by hovering or clicking the pill.
    case expanded
}

/// Primary dashboard section tab when expanded.
public enum DashboardSection: String, CaseIterable, Identifiable, Sendable {
    case all = "Hub"
    case tools = "Tools"
    case shelf = "Shelf"
    case media = "Audio"
    case power = "Power"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2.fill"
        case .tools: return "wrench.and.screwdriver.fill"
        case .shelf: return "tray.and.arrow.down.fill"
        case .media: return "waveform"
        case .power: return "bolt.shield.fill"
        }
    }
}

/// Per-display Notch state so every connected monitor (e.g. Xiaomi 4K + MacBook Air M3) operates independently.
@MainActor
@Observable
public final class ScreenNotchState {
    public let displayID: CGDirectDisplayID
    public let appState: AppState
    public var geometry: NotchGeometry
    public var interactionState: NotchInteractionState = .idle

    public var onStateChanged: ((NotchInteractionState) -> Void)?
    private var hoverCollapseWorkItem: DispatchWorkItem?
    private var lastExpandUptime: TimeInterval = 0

    public init(geometry: NotchGeometry, appState: AppState) {
        self.displayID = geometry.displayID
        self.geometry = geometry
        self.appState = appState
        if appState.isPinned {
            self.interactionState = .expanded
        }
    }

    public func updateGeometry(_ newGeometry: NotchGeometry) {
        if geometry != newGeometry {
            geometry = newGeometry
        }
    }

    // MARK: - Hover & Drag Transitions

    public func handleMouseEntered() {
        hoverCollapseWorkItem?.cancel()
        hoverCollapseWorkItem = nil

        guard interactionState != .expanded else { return }
        lastExpandUptime = ProcessInfo.processInfo.systemUptime
        // Native macOS Force Touch trackpad tactile actuation click on hover
        AeroHaptics.playHoverClick()
        appState.audioManager.refreshMasterVolumeOnly()
        transition(to: .expanded)
    }

    public func scheduleCollapseIfCursorOutside(checkCursorInside: @escaping @MainActor () -> Bool) {
        hoverCollapseWorkItem?.cancel()
        guard !appState.isPinned else { return }
        guard interactionState == .expanded || interactionState == .hover else { return }

        // Ignore transient exit signals while the spring expansion animation is still opening under a slow cursor
        let elapsedSinceExpand = ProcessInfo.processInfo.systemUptime - lastExpandUptime
        let delay: TimeInterval = elapsedSinceExpand < 0.32 ? (0.35 - elapsedSinceExpand) : 0.14

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.appState.isPinned else { return }
                guard self.interactionState == .expanded || self.interactionState == .hover else { return }
                if !checkCursorInside() {
                    self.transition(to: .idle)
                }
            }
        }
        hoverCollapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    public func cancelPendingCollapse() {
        hoverCollapseWorkItem?.cancel()
        hoverCollapseWorkItem = nil
    }

    public func handleDragEntered() {
        hoverCollapseWorkItem?.cancel()
        hoverCollapseWorkItem = nil
        appState.shelfManager.isDropTargeted = true
        guard interactionState != .expanded else { return }
        lastExpandUptime = ProcessInfo.processInfo.systemUptime
        AeroHaptics.playAlignmentTap()
        transition(to: .expanded)
    }

    public func handleDragExited(checkCursorInside: @escaping @MainActor () -> Bool) {
        if checkCursorInside() {
            return
        }
        appState.shelfManager.isDropTargeted = false
        scheduleCollapseIfCursorOutside(checkCursorInside: checkCursorInside)
    }

    public func toggleExpanded() {
        AeroHaptics.playHoverClick()
        switch interactionState {
        case .idle, .hover, .dragOver:
            lastExpandUptime = ProcessInfo.processInfo.systemUptime
            appState.audioManager.refreshMasterVolumeOnly()
            transition(to: .expanded)
        case .expanded:
            appState.setPinned(false)
            transition(to: .idle)
        }
    }

    public func collapse(force: Bool = false) {
        hoverCollapseWorkItem?.cancel()
        if appState.isPinned && !force { return }
        if force && appState.isPinned {
            appState.setPinned(false)
        }
        if interactionState != .idle {
            transition(to: .idle)
        }
    }

    public func transition(to newState: NotchInteractionState) {
        guard interactionState != newState else { return }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.83, blendDuration: 0.12)) {
            interactionState = newState
        }
        onStateChanged?(newState)
    }

    // MARK: - Balanced Widths & Preserved Heights

    /// Computes the exact visual width of the Notch container for the active state.
    public var currentContainerWidth: CGFloat {
        let baseWidth = geometry.notchWidth
        switch interactionState {
        case .idle:
            let statusBonus: CGFloat = (appState.isCaffeinateActive || appState.isAudioPlaying || appState.shelvedFileCount > 0) ? 68 : 0
            return baseWidth + statusBonus
        case .hover:
            return max(baseWidth + 96, 274)
        case .dragOver:
            return 455
        case .expanded:
            return 564
        }
    }

    /// Computes the exact visual height of the Notch container for the active state (height preserved).
    public var currentContainerHeight: CGFloat {
        let baseHeight = geometry.notchHeight
        switch interactionState {
        case .idle:
            return baseHeight + 2
        case .hover:
            return max(baseHeight + 12, 44)
        case .dragOver:
            return 195
        case .expanded:
            return 348
        }
    }
}

/// Central, zero-polling reactive coordinator for Aero with full UserDefaults settings persistence & Launch-at-Login.
@MainActor
@Observable
public final class AppState {
    private static let selectedSectionKey = "com.zerotrust.aero.selectedSection"
    private static let isPinnedKey = "com.zerotrust.aero.isPinned"
    private static let launchAtLoginKey = "com.zerotrust.aero.launchAtLogin"
    private static let hasConfiguredLoginDefaultKey = "com.zerotrust.aero.hasConfiguredLoginDefault"

    // MARK: - Sub-Module Engines
    public let shelfManager: ShelfManager
    public let powerManager: PowerManager
    public let audioManager: AudioManager
    public let autoRaiseManager: AutoRaiseManager
    public let scrollingCaptureManager: ScrollingCaptureManager

    // MARK: - Persistent User Preferences
    public var selectedSection: DashboardSection = .all
    public var isPinned: Bool = false
    public var launchAtLogin: Bool = true

    // MARK: - Cross-Module Status Indicators (Reactive Mirrors)
    public var isCaffeinateActive: Bool = false
    public var caffeinateBadgeText: String = ""
    public var isAudioPlaying: Bool = false
    public var activeTrackTitle: String = "No Media Playing"
    public var activeArtistName: String = "Spotify / Apple Music"
    public var shelvedFileCount: Int = 0

    /// Invoked when global status badges change so all connected display controllers can update their frame if idle.
    public var onGlobalBadgesChanged: (() -> Void)?
    public var onRequestCollapseAllDisplays: (() -> Void)?
    public var onRequestExpandActiveDisplay: (() -> Void)?

    public init() {
        self.shelfManager = ShelfManager()
        self.powerManager = PowerManager()
        self.audioManager = AudioManager()
        self.autoRaiseManager = AutoRaiseManager()
        self.scrollingCaptureManager = ScrollingCaptureManager()

        restoreUserSettings()
        bindModuleEngines()
    }

    // MARK: - Persistent Settings & Launch at Login

    private func restoreUserSettings() {
        let defaults = UserDefaults.standard

        if let savedSectionRaw = defaults.string(forKey: Self.selectedSectionKey),
           let savedSection = DashboardSection(rawValue: savedSectionRaw) {
            self.selectedSection = savedSection
        }

        self.isPinned = defaults.bool(forKey: Self.isPinnedKey)

        if !defaults.bool(forKey: Self.hasConfiguredLoginDefaultKey) {
            defaults.set(true, forKey: Self.hasConfiguredLoginDefaultKey)
            defaults.set(true, forKey: Self.launchAtLoginKey)
            self.launchAtLogin = true
            configureLaunchAtLogin(enabled: true)
        } else {
            self.launchAtLogin = defaults.bool(forKey: Self.launchAtLoginKey)
            configureLaunchAtLogin(enabled: self.launchAtLogin)
        }
    }

    public func setSection(_ section: DashboardSection) {
        selectedSection = section
        UserDefaults.standard.set(section.rawValue, forKey: Self.selectedSectionKey)
        AeroHaptics.playAlignmentTap()
    }

    public func setPinned(_ pinned: Bool) {
        isPinned = pinned
        UserDefaults.standard.set(pinned, forKey: Self.isPinnedKey)
        AeroHaptics.playAlignmentTap()
    }

    public func togglePinned() {
        setPinned(!isPinned)
    }

    public func toggleLaunchAtLogin() {
        launchAtLogin.toggle()
        UserDefaults.standard.set(launchAtLogin, forKey: Self.launchAtLoginKey)
        configureLaunchAtLogin(enabled: launchAtLogin)
        AeroHaptics.playAlignmentTap()
    }

    private func configureLaunchAtLogin(enabled: Bool) {
        let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let plistURL = launchAgentsDir.appendingPathComponent("com.zerotrust.aero.notch.plist")

        if enabled {
            try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
            let executablePath = Bundle.main.executablePath
                ?? "/Users/serhanagan/Developer/Swiss Knife for MacOS/Samogon.app/Contents/MacOS/Samogon"

            let plistDict: [String: Any] = [
                "Label": "com.zerotrust.aero.notch",
                "ProgramArguments": [executablePath],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive"
            ]
            if let data = try? PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0) {
                try? data.write(to: plistURL, options: .atomic)
            }
            try? SMAppService.mainApp.register()
        } else {
            try? FileManager.default.removeItem(at: plistURL)
            try? SMAppService.mainApp.unregister()
        }
    }

    // MARK: - Module Bindings

    private func bindModuleEngines() {
        self.shelvedFileCount = shelfManager.items.count
        self.isCaffeinateActive = powerManager.isActive
        self.caffeinateBadgeText = powerManager.statusBadgeText
        self.isAudioPlaying = audioManager.isPlaying
        self.activeTrackTitle = audioManager.trackTitle
        self.activeArtistName = audioManager.artistName

        shelfManager.onItemsChanged = { [weak self] count in
            guard let self else { return }
            self.shelvedFileCount = count
            self.onGlobalBadgesChanged?()
        }

        powerManager.onStatusChanged = { [weak self] active, badge in
            guard let self else { return }
            self.isCaffeinateActive = active
            self.caffeinateBadgeText = badge
            self.onGlobalBadgesChanged?()
        }

        audioManager.onPlaybackChanged = { [weak self] playing, title, artist in
            guard let self else { return }
            self.isAudioPlaying = playing
            self.activeTrackTitle = title
            self.activeArtistName = artist
            self.onGlobalBadgesChanged?()
        }

        scrollingCaptureManager.onCaptureCompleted = { [weak self] savedURL in
            guard let self else { return }
            _ = self.shelfManager.addFileURLs([savedURL])
        }

        scrollingCaptureManager.onRequestCollapseNotch = { [weak self] in
            self?.onRequestCollapseAllDisplays?()
        }

        scrollingCaptureManager.onRequestExpandNotch = { [weak self] in
            self?.onRequestExpandActiveDisplay?()
        }
    }
}
