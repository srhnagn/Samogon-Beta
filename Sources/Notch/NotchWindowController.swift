import AppKit
import CoreGraphics
import Quartz
import SwiftUI

// MARK: - Custom Non-Activating NSPanel (Never Steals Keyboard Focus)

public final class AeroNotchPanel: NSPanel {
    public weak var shelfManager: ShelfManager?

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .mainMenu + 3
        // Include `.canJoinAllSpaces` and `.fullScreenAuxiliary` so WindowServer keeps Aero on EVERY Virtual Desktop (Space)
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovable = false
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = true
        self.acceptsMouseMovedEvents = true
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.appearance = NSAppearance(named: .darkAqua)
    }

    /// Never steal key-window focus from the user's active editor (e.g. Antigravity) unless QuickLook is actively open.
    override public var canBecomeKey: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    override public var canBecomeMain: Bool { false }

    // MARK: - QuickLook Preview Panel Control

    override public func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override public func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            guard let shelfManager, let panel else { return }
            panel.dataSource = shelfManager
            panel.delegate = shelfManager
        }
    }

    override public func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            guard let panel else { return }
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}

// MARK: - Hit-Test & Drag-Aware Tracking Container View

@MainActor
public final class NotchHostContainerView: NSView {
    private let screenState: ScreenNotchState
    private var trackingArea: NSTrackingArea?

    /// Receives security-scoped dropped file URLs and forwards them to `ShelfManager`.
    public var onFileURLsDropped: (([URL]) -> Bool)?
    /// Callback to verify full-screen status before expanding on hover.
    public var shouldSuppressHoverForFullScreen: (() -> Bool)?

    public init(frame frameRect: NSRect, screenState: ScreenNotchState) {
        self.screenState = screenState
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Allow immediate single-click interaction on buttons & sliders without activating Aero or stealing key focus.
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// Computes the exact active interactive rectangle at the top-center of this host view.
    public var activeInteractiveRect: NSRect {
        let activeW = screenState.currentContainerWidth
        let activeH = screenState.currentContainerHeight
        let originX = (bounds.width - activeW) / 2.0
        let originY = bounds.maxY - activeH
        return NSRect(x: originX, y: originY, width: activeW, height: activeH)
    }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard activeInteractiveRect.contains(localPoint) else {
            return nil
        }
        return super.hitTest(point)
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        var options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .activeAlways
        ]
        if isMouseLocationInsideActiveNotch() {
            options.insert(.assumeInside)
        }

        let area = NSTrackingArea(
            rect: activeInteractiveRect,
            options: options,
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Mouse Hover Events

    public func isMouseLocationInsideActiveNotch() -> Bool {
        if QLPreviewPanel.sharedPreviewPanelExists(),
           let ql = QLPreviewPanel.shared(),
           ql.isVisible {
            return true
        }
        guard let window else { return false }
        let screenMouse = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenMouse)
        let localPoint = convert(windowPoint, from: nil)
        return activeInteractiveRect.insetBy(dx: -6, dy: -6).contains(localPoint)
    }

    override public func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if shouldSuppressHoverForFullScreen?() == true { return }
        screenState.handleMouseEntered()
    }

    override public func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if shouldSuppressHoverForFullScreen?() == true { return }
        if screenState.interactionState == .idle {
            screenState.handleMouseEntered()
        } else {
            screenState.cancelPendingCollapse()
        }
    }

    override public func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        screenState.scheduleCollapseIfCursorOutside { [weak self] in
            self?.isMouseLocationInsideActiveNotch() ?? false
        }
    }

    // MARK: - NSDraggingDestination (Zero-Copy File Drop Trigger)

    override public func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            return []
        }
        screenState.handleDragEntered()
        return .copy
    }

    override public func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        screenState.cancelPendingCollapse()
        screenState.appState.shelfManager.isDropTargeted = true
        if screenState.interactionState == .idle {
            screenState.handleDragEntered()
        }
        return .copy
    }

    override public func draggingExited(_ sender: (any NSDraggingInfo)?) {
        screenState.handleDragExited { [weak self] in
            self?.isMouseLocationInsideActiveNotch() ?? false
        }
    }

    override public func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        return true
    }

    override public func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        screenState.appState.shelfManager.isDropTargeted = false
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else {
            return false
        }

        let handled = onFileURLsDropped?(urls) ?? false
        screenState.transition(to: .expanded)
        return handled
    }
}

// MARK: - Per-Screen Notch Window Controller

@MainActor
public final class NotchWindowController: NSWindowController {
    /// Fixed transparent canvas size so SwiftUI opening and closing spring animations never clip or stutter.
    private static let canvasWidth: CGFloat = 604
    private static let canvasHeight: CGFloat = 385

    public let screenState: ScreenNotchState
    public let hostContainerView: NotchHostContainerView
    public private(set) var isHiddenForFullScreen: Bool = false

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var localKeyMonitor: Any?

    public init(screenState: ScreenNotchState) {
        self.screenState = screenState

        let initialFrame = Self.calculateCanvasScreenFrame(for: screenState)
        let panel = AeroNotchPanel(contentRect: initialFrame)
        panel.shelfManager = screenState.appState.shelfManager

        let container = NotchHostContainerView(
            frame: NSRect(origin: .zero, size: initialFrame.size),
            screenState: screenState
        )
        container.autoresizingMask = [.width, .height]
        container.onFileURLsDropped = { [weak screenState] urls in
            screenState?.appState.shelfManager.addFileURLs(urls) ?? false
        }

        let rootView = NotchRootContainerView(screenState: screenState)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        container.addSubview(hostingView)
        panel.contentView = container

        self.hostContainerView = container
        super.init(window: panel)

        container.shouldSuppressHoverForFullScreen = { [weak self] in
            guard let self else { return false }
            self.evaluateFullScreenVisibility()
            return self.isHiddenForFullScreen
        }

        configureReactiveBindings()
        updateTransientEventMonitors(for: screenState.interactionState)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func showNotch() {
        repositionAroundHardwareNotch()
        window?.orderFrontRegardless()
        evaluateFullScreenVisibility()
    }

    public func updateScreenGeometry(_ geometry: NotchGeometry) {
        screenState.updateGeometry(geometry)
        repositionAroundHardwareNotch()
        evaluateFullScreenVisibility()
    }

    public func repositionAroundHardwareNotch() {
        let targetFrame = Self.calculateCanvasScreenFrame(for: screenState)
        if window?.frame != targetFrame {
            window?.setFrame(targetFrame, display: true)
        }
        hostContainerView.updateTrackingAreas()
    }

    // MARK: - Automatic Full-Screen Hiding Per Monitor (Never Triggered by Cmd+Shift+4)

    public func evaluateFullScreenVisibility(cachedWindowList: [[String: Any]]? = nil) {
        let fullScreenActive = Self.isScreenInTrueFullScreenMode(
            screenFrame: screenState.geometry.screenFrame,
            cachedWindowList: cachedWindowList
        )
        if fullScreenActive {
            if !isHiddenForFullScreen {
                isHiddenForFullScreen = true
                screenState.collapse(force: true)
                window?.alphaValue = 0.0
                window?.ignoresMouseEvents = true
            }
        } else {
            if isHiddenForFullScreen {
                isHiddenForFullScreen = false
                window?.ignoresMouseEvents = false
                window?.alphaValue = 1.0
                window?.orderFrontRegardless()
            } else if window?.alphaValue != 1.0 {
                window?.ignoresMouseEvents = false
                window?.alphaValue = 1.0
                window?.orderFrontRegardless()
            }
        }
    }

    /// Returns `true` ONLY when a regular user application (movie player, browser HTML5 fullscreen, or green-button fullscreen Space)
    /// covers the entire display including the top menu bar. Ignores `Cmd+Shift+4` (`screencaptureui`), `BetterDisplay`, and system overlays.
    public static func isScreenInTrueFullScreenMode(
        screenFrame: CGRect,
        cachedWindowList: [[String: Any]]? = nil
    ) -> Bool {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height
        let cgScreenRect = CGRect(
            x: screenFrame.minX,
            y: primaryHeight - screenFrame.maxY,
            width: screenFrame.width,
            height: screenFrame.height
        )

        let windowList: [[String: Any]]
        if let cachedWindowList {
            windowList = cachedWindowList
        } else {
            let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
            guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
                return false
            }
            windowList = list
        }

        let myPID = ProcessInfo.processInfo.processIdentifier

        for winInfo in windowList {
            guard let layer = winInfo[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let ownerPID = winInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != myPID else {
                continue
            }

            // Strictly verify this is a `.regular` user application (ignores screencaptureui Cmd+Shift+4, BetterDisplay, etc.)
            guard let app = NSRunningApplication(processIdentifier: ownerPID),
                  app.activationPolicy == .regular,
                  app.bundleIdentifier != "com.apple.finder" else {
                continue
            }

            guard let boundsDict = winInfo[kCGWindowBounds as String] as? NSDictionary,
                  let winRect = CGRect(dictionaryRepresentation: boundsDict) else {
                continue
            }

            // A regular app window is in Full-Screen mode on this display if and only if its layer-0 bounds
            // cover the entire screen including the top 24-32pt Menu Bar region.
            if abs(winRect.minX - cgScreenRect.minX) <= 2 &&
               abs(winRect.minY - cgScreenRect.minY) <= 2 &&
               winRect.width >= cgScreenRect.width - 2 &&
               winRect.height >= cgScreenRect.height - 2 {
                return true
            }
        }

        return false
    }

    private static func calculateCanvasScreenFrame(for screenState: ScreenNotchState) -> NSRect {
        let screen = screenState.geometry.screenFrame
        let originX = (screen.minX + (screen.width - canvasWidth) / 2.0).rounded(.toNearestOrEven)
        let originY = (screen.maxY - canvasHeight).rounded(.toNearestOrEven)
        return NSRect(x: originX, y: originY, width: canvasWidth, height: canvasHeight)
    }

    // MARK: - Event-Driven Monitors (Active Only While Expanded -> 0.0% Idle CPU)

    private func configureReactiveBindings() {
        screenState.onStateChanged = { [weak self] newState in
            guard let self else { return }
            self.hostContainerView.updateTrackingAreas()
            self.updateTransientEventMonitors(for: newState)
            if newState == .idle, self.window?.isKeyWindow == true {
                self.window?.resignKey()
            }
        }
    }

    private func updateTransientEventMonitors(for state: NotchInteractionState) {
        if state == .expanded || state == .hover {
            installTransientMonitorsIfNeeded()
        } else {
            removeTransientMonitors()
        }
    }

    private func installTransientMonitorsIfNeeded() {
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.evaluateActiveCursorPosition(eventType: event.type)
                }
            }
        }

        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved]
            ) { [weak self] event in
                self?.evaluateActiveCursorPosition(eventType: event.type)
                return event
            }
        }

        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                switch event.keyCode {
                case 53: // Escape key collapses the expanded Notch
                    self.screenState.collapse(force: true)
                    return nil
                case 49: // Spacebar triggers QuickLook on the selected Shelf item
                    if !self.screenState.appState.shelfManager.items.isEmpty {
                        self.screenState.appState.shelfManager.toggleQuickLookPreview()
                        return nil
                    }
                    return event
                default:
                    return event
                }
            }
        }
    }

    private func evaluateActiveCursorPosition(eventType: NSEvent.EventType) {
        guard !screenState.appState.isPinned else { return }
        let isInside = hostContainerView.isMouseLocationInsideActiveNotch()
        if isInside {
            screenState.cancelPendingCollapse()
        } else if eventType == .leftMouseDown || eventType == .rightMouseDown {
            screenState.collapse()
        } else {
            screenState.scheduleCollapseIfCursorOutside { [weak self] in
                self?.hostContainerView.isMouseLocationInsideActiveNotch() ?? false
            }
        }
    }

    public func removeTransientMonitors() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let localMonitor = localMouseMonitor {
            NSEvent.removeMonitor(localMonitor)
            localMouseMonitor = nil
        }
        if let keyMonitor = localKeyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            localKeyMonitor = nil
        }
    }
}

// MARK: - Multi-Monitor Coordinator (Manages All Connected Displays & Full-Screen Visibility)

@MainActor
public final class NotchMultiDisplayCoordinator {
    public let appState: AppState
    public private(set) var controllersByDisplayID: [CGDirectDisplayID: NotchWindowController] = [:]
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var appActivateObserver: NSObjectProtocol?
    private var fullScreenCheckTimer: DispatchSourceTimer?

    public init(appState: AppState) {
        self.appState = appState

        appState.onGlobalBadgesChanged = { [weak self] in
            guard let self else { return }
            for controller in self.controllersByDisplayID.values where !controller.isHiddenForFullScreen {
                controller.hostContainerView.updateTrackingAreas()
            }
        }

        appState.onRequestCollapseAllDisplays = { [weak self] in
            guard let self else { return }
            for controller in self.controllersByDisplayID.values {
                controller.screenState.collapse(force: true)
            }
        }

        appState.onRequestExpandActiveDisplay = { [weak self] in
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            if let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main,
               let controller = self.controllersByDisplayID[targetScreen.aeroDisplayID],
               !controller.isHiddenForFullScreen {
                controller.screenState.appState.setSection(.shelf)
                controller.screenState.transition(to: .expanded)
            }
        }

        synchronizeAllScreens()
        observeSystemAndSpaceChanges()
        startLowPowerFullScreenWatcher()
    }

    public func synchronizeAllScreens() {
        let currentScreens = NSScreen.screens
        var activeIDs = Set<CGDirectDisplayID>()

        for screen in currentScreens {
            let geometry = screen.notchGeometry
            let displayID = geometry.displayID
            activeIDs.insert(displayID)

            if let existing = controllersByDisplayID[displayID] {
                existing.updateScreenGeometry(geometry)
            } else {
                let screenState = ScreenNotchState(geometry: geometry, appState: appState)
                let controller = NotchWindowController(screenState: screenState)
                controllersByDisplayID[displayID] = controller
                controller.showNotch()
            }
        }

        let staleIDs = Set(controllersByDisplayID.keys).subtracting(activeIDs)
        for staleID in staleIDs {
            if let oldController = controllersByDisplayID.removeValue(forKey: staleID) {
                oldController.removeTransientMonitors()
                oldController.close()
            }
        }
    }

    public func evaluateAllDisplaysFullScreen() {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let sharedList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        for controller in controllersByDisplayID.values {
            controller.evaluateFullScreenVisibility(cachedWindowList: sharedList)
        }
    }

    private func observeSystemAndSpaceChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.synchronizeAllScreens()
            }
        }

        let wsCenter = NSWorkspace.shared.notificationCenter
        spaceObserver = wsCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateAllDisplaysFullScreen()
            }
        }

        appActivateObserver = wsCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateAllDisplaysFullScreen()
            }
        }
    }

    private func startLowPowerFullScreenWatcher() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.evaluateAllDisplaysFullScreen()
            }
        }
        fullScreenCheckTimer = timer
        timer.resume()
    }
}
