import AppKit
import Foundation
import IOKit.pwr_mgt
import Observation

/// Hardware power assertion mode backed directly by `IOKit.pwr_mgt`.
public enum CaffeinateMode: String, CaseIterable, Identifiable, Sendable {
    /// Prevents both display and system idle sleep (`kIOPMAssertionTypePreventUserIdleDisplaySleep`).
    case displayAndSystem = "Display + System"
    /// Allows screen to dim/sleep while keeping CPU & disk awake (`kIOPMAssertionTypePreventUserIdleSystemSleep`).
    case systemOnly = "System Only"

    public var id: String { rawValue }

    public var ioKitAssertionType: String {
        switch self {
        case .displayAndSystem:
            return kIOPMAssertionTypePreventUserIdleDisplaySleep as String
        case .systemOnly:
            return kIOPMAssertionTypePreventUserIdleSystemSleep as String
        }
    }

    public var iconName: String {
        switch self {
        case .displayAndSystem:
            return "sun.max.fill"
        case .systemOnly:
            return "cpu.fill"
        }
    }
}

/// Timed or indefinite duration presets for Caffeinate assertions.
public enum CaffeinateDuration: String, CaseIterable, Identifiable, Sendable {
    case infinite = "∞"
    case fifteenMinutes = "15m"
    case thirtyMinutes = "30m"
    case oneHour = "1h"
    case twoHours = "2h"

    public var id: String { rawValue }

    public var seconds: TimeInterval? {
        switch self {
        case .infinite: return nil
        case .fifteenMinutes: return 15 * 60
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 60 * 60
        case .twoHours: return 120 * 60
        }
    }
}

/// Zero-daemon native IOKit Power Assertion Engine (`IOPMAssertionCreateWithName`) with persistent settings.
@MainActor
@Observable
public final class PowerManager {
    private static let modeKey = "com.zerotrust.aero.power.mode"
    private static let durationKey = "com.zerotrust.aero.power.duration"
    private static let isActiveKey = "com.zerotrust.aero.power.isActive"

    public private(set) var isActive: Bool = false
    public private(set) var activeAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    public var selectedMode: CaffeinateMode = .displayAndSystem
    public var selectedDuration: CaffeinateDuration = .infinite
    public private(set) var remainingSeconds: TimeInterval?

    /// Callback invoked whenever power assertion state or badge text changes.
    public var onStatusChanged: ((Bool, String) -> Void)?

    private var expirationDate: Date?
    private var countdownTimer: DispatchSourceTimer?
    private var terminationObserver: NSObjectProtocol?

    public init() {
        let defaults = UserDefaults.standard
        if let savedModeRaw = defaults.string(forKey: Self.modeKey),
           let savedMode = CaffeinateMode(rawValue: savedModeRaw) {
            self.selectedMode = savedMode
        }
        if let savedDurRaw = defaults.string(forKey: Self.durationKey),
           let savedDur = CaffeinateDuration(rawValue: savedDurRaw) {
            self.selectedDuration = savedDur
        }
        let wasActive = defaults.bool(forKey: Self.isActiveKey)
        if wasActive {
            activateAssertion(mode: selectedMode, duration: selectedDuration, triggerHaptic: false)
        }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Release the kernel assertion on exit without erasing the user's saved preference
                self?.releaseKernelLockOnlyForShutdown()
            }
        }
    }

    private func persistSettings() {
        let defaults = UserDefaults.standard
        defaults.set(selectedMode.rawValue, forKey: Self.modeKey)
        defaults.set(selectedDuration.rawValue, forKey: Self.durationKey)
        defaults.set(isActive, forKey: Self.isActiveKey)
    }

    // MARK: - Formatted Status Badge

    public var statusBadgeText: String {
        guard isActive else { return "Off" }
        guard let remaining = remainingSeconds, remaining > 0 else {
            return "∞ Awake"
        }
        let minutes = Int(ceil(remaining / 60.0))
        if minutes >= 60 {
            let hrs = minutes / 60
            let mins = minutes % 60
            return mins > 0 ? "\(hrs)h \(mins)m" : "\(hrs)h"
        }
        return "\(minutes)m"
    }

    public var assertionHexLabel: String {
        guard isActive else { return "No Active Lock" }
        return String(format: "IOPMAssertion 0x%04X", activeAssertionID)
    }

    // MARK: - Toggle & Activation Lifecycle

    public func toggle() {
        if isActive {
            deactivateAssertion()
        } else {
            activateAssertion(mode: selectedMode, duration: selectedDuration)
        }
    }

    public func selectAndActivate(duration: CaffeinateDuration) {
        selectedDuration = duration
        activateAssertion(mode: selectedMode, duration: duration)
    }

    public func setMode(_ mode: CaffeinateMode) {
        selectedMode = mode
        persistSettings()
        if isActive {
            activateAssertion(mode: mode, duration: selectedDuration)
        } else {
            AeroHaptics.playAlignmentTap()
        }
    }

    public func activateAssertion(
        mode: CaffeinateMode,
        duration: CaffeinateDuration,
        triggerHaptic: Bool = true
    ) {
        releaseCurrentKernelAssertion()
        cancelTimer()

        var newAssertionID = IOPMAssertionID(0)
        let reason = "Samogon Zero-Trust Power Lock (\(mode.rawValue), \(duration.rawValue))" as CFString
        let assertionType = mode.ioKitAssertionType as CFString

        let result = IOPMAssertionCreateWithName(
            assertionType,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &newAssertionID
        )

        guard result == kIOReturnSuccess else {
            isActive = false
            activeAssertionID = 0
            remainingSeconds = nil
            persistSettings()
            onStatusChanged?(false, "")
            return
        }

        activeAssertionID = newAssertionID
        isActive = true

        if let totalSeconds = duration.seconds {
            let targetDate = Date().addingTimeInterval(totalSeconds)
            expirationDate = targetDate
            remainingSeconds = totalSeconds
            startLowOverheadExpirationTimer()
        } else {
            expirationDate = nil
            remainingSeconds = nil
        }

        persistSettings()
        if triggerHaptic {
            AeroHaptics.playAlignmentTap()
        }
        onStatusChanged?(true, statusBadgeText)
    }

    public func deactivateAssertion() {
        releaseCurrentKernelAssertion()
        cancelTimer()
        isActive = false
        expirationDate = nil
        remainingSeconds = nil
        persistSettings()
        AeroHaptics.playAlignmentTap()
        onStatusChanged?(false, "")
    }

    private func releaseKernelLockOnlyForShutdown() {
        releaseCurrentKernelAssertion()
        cancelTimer()
    }

    // MARK: - Low-Overhead DispatchSourceTimer (Only Active During Timed Modes)

    private func startLowOverheadExpirationTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(3))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let expirationDate = self.expirationDate else { return }
                let remaining = expirationDate.timeIntervalSinceNow
                if remaining <= 0 {
                    self.deactivateAssertion()
                } else {
                    self.remainingSeconds = remaining
                    self.onStatusChanged?(true, self.statusBadgeText)
                }
            }
        }
        countdownTimer = timer
        timer.resume()
    }

    private func cancelTimer() {
        countdownTimer?.cancel()
        countdownTimer = nil
    }

    private func releaseCurrentKernelAssertion() {
        if activeAssertionID != 0 {
            IOPMAssertionRelease(activeAssertionID)
            activeAssertionID = 0
        }
    }
}
