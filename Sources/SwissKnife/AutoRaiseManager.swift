import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import Observation

/// Hover delay presets for AutoRaise (Focus-Follows-Mouse).
public enum AutoRaiseDelay: Int, CaseIterable, Identifiable, Sendable {
    case instant = 25
    case fast = 75
    case balanced = 140
    case relaxed = 260

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .instant: return "25ms"
        case .fast: return "75ms"
        case .balanced: return "140ms"
        case .relaxed: return "260ms"
        }
    }
}

/// Native, Zero-Trust AutoRaise (Focus-Follows-Mouse) Engine.
/// Activates and raises the window beneath the mouse cursor with zero background daemons.
@MainActor
@Observable
public final class AutoRaiseManager {
    private static let enabledKey = "com.zerotrust.aero.autoraise.enabled"
    private static let delayKey = "com.zerotrust.aero.autoraise.delayMs"
    private static let raiseWindowKey = "com.zerotrust.aero.autoraise.raiseWindow"

    public var isEnabled: Bool = false
    public var selectedDelay: AutoRaiseDelay = .fast
    public var shouldRaiseExactWindow: Bool = true
    public private(set) var isAccessibilityTrusted: Bool = AXIsProcessTrusted()
    public private(set) var lastActivatedAppName: String = "—"

    private var globalMouseMoveMonitor: Any?
    private var debounceWorkItem: DispatchWorkItem?
    private var lastRaisedWindowNumber: Int = -1
    private var lastRaisedPID: pid_t = -1

    private static let ignoredOwnerNames: Set<String> = [
        "Window Server",
        "WindowServer",
        "Dock",
        "Control Center",
        "Notification Center",
        "Spotlight",
        "Aero",
        "Samogon"
    ]

    public init() {
        let defaults = UserDefaults.standard
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        if let savedDelay = AutoRaiseDelay(rawValue: defaults.integer(forKey: Self.delayKey)) {
            self.selectedDelay = savedDelay
        }
        if defaults.object(forKey: Self.raiseWindowKey) != nil {
            self.shouldRaiseExactWindow = defaults.bool(forKey: Self.raiseWindowKey)
        } else {
            self.shouldRaiseExactWindow = true
        }

        updateMonitorState()
    }

    // MARK: - User Actions & Persistence

    public func toggleEnabled() {
        isEnabled.toggle()
        UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
        AeroHaptics.playAlignmentTap()
        refreshAccessibilityStatus()
        updateMonitorState()
    }

    public func setDelay(_ delay: AutoRaiseDelay) {
        selectedDelay = delay
        UserDefaults.standard.set(delay.rawValue, forKey: Self.delayKey)
        AeroHaptics.playAlignmentTap()
    }

    public func toggleRaiseExactWindow() {
        shouldRaiseExactWindow.toggle()
        UserDefaults.standard.set(shouldRaiseExactWindow, forKey: Self.raiseWindowKey)
        AeroHaptics.playAlignmentTap()
        if shouldRaiseExactWindow && !isAccessibilityTrusted {
            promptForAccessibilityPermission()
        }
    }

    public func refreshAccessibilityStatus() {
        isAccessibilityTrusted = AXIsProcessTrusted()
    }

    public func promptForAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        isAccessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Event-Driven Mouse Monitor (0.0% CPU When Disabled)

    private func updateMonitorState() {
        if isEnabled {
            guard globalMouseMoveMonitor == nil else { return }
            globalMouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleHoverEvaluation()
                }
            }
        } else {
            debounceWorkItem?.cancel()
            debounceWorkItem = nil
            if let monitor = globalMouseMoveMonitor {
                NSEvent.removeMonitor(monitor)
                globalMouseMoveMonitor = nil
            }
        }
    }

    private func scheduleHoverEvaluation() {
        debounceWorkItem?.cancel()

        // Never switch window focus while any mouse button is pressed (e.g. dragging files or selecting text)
        guard NSEvent.pressedMouseButtons == 0 else { return }

        let delaySeconds = Double(selectedDelay.rawValue) / 1000.0
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.evaluateWindowUnderCursor()
            }
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds, execute: workItem)
    }

    private func evaluateWindowUnderCursor() {
        guard isEnabled, NSEvent.pressedMouseButtons == 0 else { return }

        let appKitMouse = NSEvent.mouseLocation
        // Convert AppKit bottom-left screen coordinates to CoreGraphics top-left global coordinates
        // In CoreGraphics, screen (0,0) is the top-left of the primary display (NSScreen.screens.first)
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080.0
        let cgPoint = CGPoint(x: appKitMouse.x, y: primaryScreenHeight - appKitMouse.y)

        // Ignore top 38pt menu bar / Notch region so hovering the Notch doesn't trigger underlying windows
        for screen in NSScreen.screens where screen.frame.contains(appKitMouse) {
            if appKitMouse.y >= screen.frame.maxY - 40 {
                return
            }
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return
        }

        let myPID = ProcessInfo.processInfo.processIdentifier

        for winInfo in windowList {
            guard let layer = winInfo[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let ownerPID = winInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != myPID else {
                continue
            }

            let ownerName = (winInfo[kCGWindowOwnerName as String] as? String) ?? ""
            if Self.ignoredOwnerNames.contains(ownerName) {
                continue
            }

            guard let boundsDict = winInfo[kCGWindowBounds as String] as? NSDictionary,
                  let windowRect = CGRect(dictionaryRepresentation: boundsDict),
                  windowRect.width > 40,
                  windowRect.height > 40 else {
                continue
            }

            // Found the topmost normal window containing the cursor
            if windowRect.contains(cgPoint) {
                let windowNumber = (winInfo[kCGWindowNumber as String] as? Int) ?? 0
                if windowNumber == lastRaisedWindowNumber && ownerPID == lastRaisedPID && NSWorkspace.shared.frontmostApplication?.processIdentifier == ownerPID {
                    return
                }

                lastRaisedWindowNumber = windowNumber
                lastRaisedPID = ownerPID

                if let targetApp = NSRunningApplication(processIdentifier: ownerPID), !targetApp.isTerminated {
                    lastActivatedAppName = targetApp.localizedName ?? ownerName
                    if !targetApp.isActive {
                        targetApp.activate()
                    }
                    if shouldRaiseExactWindow && AXIsProcessTrusted() {
                        raiseSpecificWindowViaAX(pid: ownerPID, targetCGWindowRect: windowRect)
                    }
                }
                return
            }
        }
    }

    private func raiseSpecificWindowViaAX(pid: pid_t, targetCGWindowRect: CGRect) {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement] else {
            return
        }

        for axWin in axWindows {
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            var pos = CGPoint.zero
            var size = CGSize.zero

            if AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &posRef) == .success,
               let posVal = posRef {
                AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
            }
            if AXUIElementCopyAttributeValue(axWin, kAXSizeAttribute as CFString, &sizeRef) == .success,
               let sizeVal = sizeRef {
                AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
            }

            if abs(pos.x - targetCGWindowRect.origin.x) < 12 &&
               abs(pos.y - targetCGWindowRect.origin.y) < 12 &&
               abs(size.width - targetCGWindowRect.width) < 12 {
                AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(axWin, kAXMainAttribute as CFString, kCFBooleanTrue)
                return
            }
        }
    }
}
