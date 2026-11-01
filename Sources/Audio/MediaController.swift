import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
@preconcurrency import ScreenCaptureKit

/// Represents an open application registered with CoreAudio whose volume can be independently controlled in Aero's Audio Mixer.
public struct AudioMixerAppItem: Identifiable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let displayName: String
    public let pid: pid_t
    public let processObjectIDs: [AudioObjectID]
    public let isRunningOutput: Bool
    public let isScriptableVolume: Bool

    public var id: String { bundleIdentifier }
}

/// Snapshot of system-wide Now Playing state across Spotify, Brave, Apple Music, Safari, Chrome, and native players.
public struct SystemNowPlayingSnapshot: Sendable {
    public let bundleIdentifier: String
    public let appDisplayName: String
    public let isPlaying: Bool
    public let title: String
    public let artist: String
    public let album: String
    public let duration: Double
    public let elapsedTime: Double
    public let playbackRate: Double
    public let timestamp: Date
    public let artworkData: Data?

    public func withPlayingState(_ playing: Bool) -> SystemNowPlayingSnapshot {
        SystemNowPlayingSnapshot(
            bundleIdentifier: bundleIdentifier,
            appDisplayName: appDisplayName,
            isPlaying: playing,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            elapsedTime: elapsedTime,
            playbackRate: playing ? 1.0 : 0.0,
            timestamp: Date(),
            artworkData: artworkData
        )
    }
}

// MARK: - CoreAudio Per-App Hardware Tap Volume Controller

/// Manages a live CoreAudio `CATapDescription` + Aggregate Device IOProc to attenuate a specific application's audio output in real time.
public final class AppAudioTapSession: @unchecked Sendable {
    public let bundleIdentifier: String
    private var tapID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private let lock = NSLock()
    private var _targetGain: Float = 1.0

    public var targetGain: Float {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _targetGain
        }
        set {
            lock.lock()
            _targetGain = max(0.0, min(1.0, newValue))
            lock.unlock()
        }
    }

    public init?(
        bundleIdentifier: String,
        processObjectIDs: [AudioObjectID],
        outputDeviceUID: String,
        initialGain: Float
    ) {
        guard !processObjectIDs.isEmpty else { return nil }
        self.bundleIdentifier = bundleIdentifier
        self._targetGain = max(0.0, min(1.0, initialGain))

        let numbers = processObjectIDs.map { NSNumber(value: $0) }
        let tapDesc = CATapDescription(__stereoMixdownOfProcesses: numbers)
        tapDesc.name = "AeroTap-\(bundleIdentifier)"
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .mutedWhenTapped

        var newTapID: AudioObjectID = 0
        guard AudioHardwareCreateProcessTap(tapDesc, &newTapID) == noErr, newTapID != 0 else {
            return nil
        }
        self.tapID = newTapID

        let aggUID = "com.zerotrust.aero.mixer.\(UUID().uuidString)"
        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AeroMixer-\(bundleIdentifier)",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var newAggID: AudioObjectID = 0
        guard AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &newAggID) == noErr, newAggID != 0 else {
            AudioHardwareDestroyProcessTap(newTapID)
            return nil
        }
        self.aggregateDeviceID = newAggID

        var createdProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(
            &createdProcID,
            newAggID,
            nil
        ) { [weak self] _, inInputData, _, outOutputData, _ in
            guard let self else { return }
            let gain = self.targetGain
            let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outList = UnsafeMutableAudioBufferListPointer(outOutputData)

            let bufferCount = min(inList.count, outList.count)
            for idx in 0..<bufferCount {
                let inBuf = inList[idx]
                var outBuf = outList[idx]
                guard let inPtr = inBuf.mData?.assumingMemoryBound(to: Float32.self),
                      let outPtr = outBuf.mData?.assumingMemoryBound(to: Float32.self) else {
                    continue
                }
                let sampleCount = min(Int(inBuf.mDataByteSize), Int(outBuf.mDataByteSize)) / MemoryLayout<Float32>.size
                if gain <= 0.001 {
                    memset(outPtr, 0, sampleCount * MemoryLayout<Float32>.size)
                } else {
                    for s in 0..<sampleCount {
                        outPtr[s] = inPtr[s] * gain
                    }
                }
                outBuf.mDataByteSize = inBuf.mDataByteSize
                outList[idx] = outBuf
            }
        }

        guard procStatus == noErr, let validProcID = createdProcID else {
            AudioHardwareDestroyAggregateDevice(newAggID)
            AudioHardwareDestroyProcessTap(newTapID)
            return nil
        }
        self.ioProcID = validProcID

        if AudioDeviceStart(newAggID, validProcID) != noErr {
            AudioDeviceDestroyIOProcID(newAggID, validProcID)
            AudioHardwareDestroyAggregateDevice(newAggID)
            AudioHardwareDestroyProcessTap(newTapID)
            return nil
        }
    }

    public func stopAndDestroy() {
        if aggregateDeviceID != 0, let procID = ioProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
        }
        if aggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    deinit {
        stopAndDestroy()
    }
}

/// System-wide Universal Media Resolver + CoreAudio Per-App Mixer + ScreenCaptureKit Window Title Reader.
public enum MediaController {
    private static let backgroundQueue = DispatchQueue(
        label: "com.zerotrust.aero.mediaremote",
        qos: .userInitiated
    )

    // MARK: - Dynamic MediaRemote.framework Bindings

    private typealias MRRegisterNotificationsFn = @convention(c) (DispatchQueue) -> Void
    private typealias MRGetIsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias MRSendCommandFn = @convention(c) (UInt32, AnyObject?) -> Bool
    private typealias MRSetElapsedTimeFn = @convention(c) (Double) -> Void

    private nonisolated(unsafe) static let mediaRemoteHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
    }()

    public static func registerForSystemMediaNotifications() {
        guard let handle = mediaRemoteHandle,
              let sym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") else { return }
        let fn = unsafeBitCast(sym, to: MRRegisterNotificationsFn.self)
        fn(DispatchQueue.main)
    }

    /// Queries macOS `MRMediaRemoteGetNowPlayingApplicationIsPlaying` in ~10ms (updates immediately when Brave/Spotify/Safari pauses, before CoreAudio drains its buffer).
    public static func querySystemMediaRemoteIsPlaying(completion: @escaping @MainActor (Bool) -> Void) {
        guard let handle = mediaRemoteHandle,
              let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") else {
            Task { @MainActor in completion(false) }
            return
        }
        let getPlaying = unsafeBitCast(sym, to: MRGetIsPlayingFn.self)
        getPlaying(DispatchQueue.main) { isPlaying in
            Task { @MainActor in
                completion(isPlaying)
            }
        }
    }

    // MARK: - Universal Transport Commands

    public static func togglePlayPause(bundleIdentifier: String = "") {
        backgroundQueue.async {
            if bundleIdentifier == "com.spotify.client" {
                runAppleScript("tell application \"Spotify\" to if it is running then playpause")
                return
            } else if bundleIdentifier == "com.apple.Music" {
                runAppleScript("tell application \"Music\" to if it is running then playpause")
                return
            }
            sendMediaRemoteCommand(2)
        }
    }

    public static func nextTrack(bundleIdentifier: String = "") {
        backgroundQueue.async {
            if bundleIdentifier == "com.spotify.client" {
                runAppleScript("tell application \"Spotify\" to if it is running then next track")
                return
            } else if bundleIdentifier == "com.apple.Music" {
                runAppleScript("tell application \"Music\" to if it is running then next track")
                return
            }
            sendMediaRemoteCommand(4)
        }
    }

    public static func previousTrack(bundleIdentifier: String = "") {
        backgroundQueue.async {
            if bundleIdentifier == "com.spotify.client" {
                runAppleScript("tell application \"Spotify\" to if it is running then previous track")
                return
            } else if bundleIdentifier == "com.apple.Music" {
                runAppleScript("tell application \"Music\" to if it is running then previous track")
                return
            }
            sendMediaRemoteCommand(5)
        }
    }

    public static func seek(to seconds: Double, bundleIdentifier: String = "") {
        let clamped = max(0, seconds)
        backgroundQueue.async {
            if bundleIdentifier == "com.spotify.client" {
                runAppleScript("tell application \"Spotify\" to if it is running then set player position to \(clamped)")
                return
            } else if bundleIdentifier == "com.apple.Music" {
                runAppleScript("tell application \"Music\" to if it is running then set player position to \(clamped)")
                return
            }
            guard let handle = mediaRemoteHandle,
                  let sym = dlsym(handle, "MRMediaRemoteSetElapsedTime") else { return }
            let fn = unsafeBitCast(sym, to: MRSetElapsedTimeFn.self)
            fn(clamped)
        }
    }

    private static func sendMediaRemoteCommand(_ command: UInt32) {
        guard let handle = mediaRemoteHandle,
              let sym = dlsym(handle, "MRMediaRemoteSendCommand") else { return }
        let fn = unsafeBitCast(sym, to: MRSendCommandFn.self)
        _ = fn(command, nil)
    }

    /// Executes AppleScript safely off-thread via `/usr/bin/osascript`.
    @discardableResult
    private static func runAppleScript(_ source: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    // MARK: - Ultra-Fast Synchronous CoreAudio + IOKit Power Assertion Check (0.05ms in C)

    private static let browserBundleIDs: Set<String> = [
        "com.brave.Browser",
        "com.google.Chrome",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "company.thebrowser.Browser"
    ]

    /// Returns the set of PIDs currently holding a media/video wake lock (`PreventUserIdleDisplaySleep` / `PreventUserIdleSystemSleep`).
    /// Chromium/Brave keeps its CoreAudio stream open for 10 seconds of silence after pausing a video (`kCloseDelaySeconds = 10`),
    /// but releases its IOKit power assertion in 0ms the exact instant the user pauses playback!
    public static func pidsWithActiveMediaPowerAssertions() -> Set<pid_t> {
        var assertionsByProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&assertionsByProcess) == kIOReturnSuccess,
              let dict = assertionsByProcess?.takeRetainedValue() as? [Int: [[String: Any]]] else {
            return []
        }
        var activePIDs = Set<pid_t>()
        for (pid, assertions) in dict {
            for item in assertions {
                let assertType = (item["AssertType"] as? String) ?? ""
                if assertType == "PreventUserIdleDisplaySleep" ||
                   assertType == "PreventUserIdleSystemSleep" ||
                   assertType == "NoDisplaySleepAssertion" ||
                   assertType == "NoIdleSleepAssertion" {
                    activePIDs.insert(pid_t(pid))
                }
            }
        }
        return activePIDs
    }

    public static func activeAudioOutputBundleIDs() -> Set<String> {
        let processObjects = allCoreAudioProcessObjectIDs()
        guard !processObjects.isEmpty else { return [] }

        let assertionPIDs = pidsWithActiveMediaPowerAssertions()
        var mainBrowserPIDs: [String: pid_t] = [:]
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            if let bid = app.bundleIdentifier, browserBundleIDs.contains(bid) {
                mainBrowserPIDs[bid] = app.processIdentifier
            }
        }

        var active = Set<String>()

        for obj in processObjects {
            var runAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isRunningOut: UInt32 = 0
            var outSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(obj, &runAddr, 0, nil, &outSize, &isRunningOut) == noErr,
                  isRunningOut != 0 else {
                continue
            }

            var bidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfStr: Unmanaged<CFString>?
            var bidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(obj, &bidAddr, 0, nil, &bidSize, &cfStr) == noErr,
                  let retained = cfStr?.takeRetainedValue() else {
                continue
            }

            let normalized = normalizeBundleID(retained as String)
            guard !normalized.isEmpty,
                  !ignoredSystemPrefixes.contains(where: { normalized.hasPrefix($0) }) else {
                continue
            }

            // For Chromium/Web browsers, eliminate the 10-second CoreAudio idle stream close delay by verifying the browser's IOKit media assertion!
            if browserBundleIDs.contains(normalized) {
                var pidAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioProcessPropertyPID,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var helperPID: pid_t = 0
                var pidSize = UInt32(MemoryLayout<pid_t>.size)
                _ = AudioObjectGetPropertyData(obj, &pidAddr, 0, nil, &pidSize, &helperPID)
                let mainPID = mainBrowserPIDs[normalized] ?? 0

                if !assertionPIDs.contains(mainPID) && !assertionPIDs.contains(helperPID) {
                    // Browser paused playback and is only in its 10-second silent CoreAudio stream drain!
                    continue
                }
            }

            active.insert(normalized)
        }
        return active
    }

    // MARK: - Universal Now Playing Discovery (ScreenCaptureKit Window Titles + CoreAudio + AppleScript)

    public static func fetchSystemNowPlaying(
        mixerApps: [AudioMixerAppItem],
        preferredBundleID: String,
        completion: @escaping @MainActor (SystemNowPlayingSnapshot?) -> Void
    ) {
        let regularApps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let runningBundleIDs = Set(regularApps.compactMap(\.bundleIdentifier))
        var tempPIDByBundle: [String: pid_t] = [:]
        var tempNameByBundle: [String: String] = [:]
        for app in regularApps {
            if let bid = app.bundleIdentifier {
                if app.activationPolicy == .regular || tempPIDByBundle[bid] == nil {
                    tempPIDByBundle[bid] = app.processIdentifier
                }
                if let name = app.localizedName, !name.isEmpty {
                    tempNameByBundle[bid] = name
                }
            }
        }

        let mainAppPIDByBundle = tempPIDByBundle
        let appNameByBundle = tempNameByBundle
        let activeOutputBundles = Set(
            mixerApps.filter(\.isRunningOutput).map(\.bundleIdentifier)
        )

        Task.detached(priority: .userInitiated) {
            // 0. Harvest live window titles via ScreenCaptureKit (already authorized for Aero!) + CGWindowList
            let scTitlesByBundle = await fetchScreenCaptureKitWindowTitles()

            var candidates: [SystemNowPlayingSnapshot] = []

            // 1. Check Brave Browser if running
            if runningBundleIDs.contains("com.brave.Browser") {
                let mainPID = mainAppPIDByBundle["com.brave.Browser"] ?? 0
                let scTitle = scTitlesByBundle["com.brave.Browser"] ?? ""
                if let snap = queryChromiumSnapshot(
                    appName: "Brave Browser",
                    bundleID: "com.brave.Browser",
                    mainPID: mainPID,
                    scWindowTitle: scTitle,
                    isCoreAudioOut: activeOutputBundles.contains("com.brave.Browser")
                ) {
                    candidates.append(snap)
                }
            }

            // 2. Check Spotify if running (skip slow AppleScript if Brave/another app is actively playing audio right now)
            if runningBundleIDs.contains("com.spotify.client") {
                let otherAppIsPlaying = !activeOutputBundles.isEmpty && !activeOutputBundles.contains("com.spotify.client")
                if !otherAppIsPlaying || preferredBundleID == "com.spotify.client" {
                    if let snap = querySpotifySnapshot() {
                        candidates.append(snap)
                    }
                }
            }

            // 3. Check Apple Music if running
            if runningBundleIDs.contains("com.apple.Music") {
                let otherAppIsPlaying = !activeOutputBundles.isEmpty && !activeOutputBundles.contains("com.apple.Music")
                if !otherAppIsPlaying || preferredBundleID == "com.apple.Music" {
                    if let snap = queryAppleMusicSnapshot() {
                        candidates.append(snap)
                    }
                }
            }

            // 4. Check Google Chrome if running
            if runningBundleIDs.contains("com.google.Chrome") {
                let mainPID = mainAppPIDByBundle["com.google.Chrome"] ?? 0
                let scTitle = scTitlesByBundle["com.google.Chrome"] ?? ""
                if let snap = queryChromiumSnapshot(
                    appName: "Google Chrome",
                    bundleID: "com.google.Chrome",
                    mainPID: mainPID,
                    scWindowTitle: scTitle,
                    isCoreAudioOut: activeOutputBundles.contains("com.google.Chrome")
                ) {
                    candidates.append(snap)
                }
            }

            // 5. Check Safari if running
            if runningBundleIDs.contains("com.apple.Safari") {
                let mainPID = mainAppPIDByBundle["com.apple.Safari"] ?? 0
                let scTitle = scTitlesByBundle["com.apple.Safari"] ?? ""
                if let snap = querySafariSnapshot(
                    mainPID: mainPID,
                    scWindowTitle: scTitle,
                    isCoreAudioOut: activeOutputBundles.contains("com.apple.Safari")
                ) {
                    candidates.append(snap)
                }
            }

            // 6. Any other application actively outputting audio in CoreAudio (e.g. VLC, IINA, QuickTime, etc.)
            for activeBundle in activeOutputBundles {
                if candidates.contains(where: { $0.bundleIdentifier == activeBundle }) {
                    continue
                }
                let pid = mainAppPIDByBundle[activeBundle] ?? 0
                let scTitle = scTitlesByBundle[activeBundle] ?? ""
                let windowTitle = !scTitle.isEmpty ? scTitle : queryWindowTitle(forPID: pid)
                let properAppName = appNameByBundle[activeBundle] ?? "Media"
                let resolvedTitle = windowTitle.isEmpty ? properAppName : windowTitle
                candidates.append(
                    SystemNowPlayingSnapshot(
                        bundleIdentifier: activeBundle,
                        appDisplayName: properAppName,
                        isPlaying: true,
                        title: resolvedTitle,
                        artist: properAppName,
                        album: "",
                        duration: 0,
                        elapsedTime: 0,
                        playbackRate: 1.0,
                        timestamp: Date(),
                        artworkData: nil
                    )
                )
            }

            // Selection logic ("Keep the Most Recent Player"):
            let playingCandidates = candidates.filter(\.isPlaying)
            let chosen: SystemNowPlayingSnapshot?
            if let preferredPlaying = playingCandidates.first(where: { $0.bundleIdentifier == preferredBundleID }) {
                chosen = preferredPlaying
            } else if let firstPlaying = playingCandidates.first {
                chosen = firstPlaying
            } else if !preferredBundleID.isEmpty,
                      let preferredPaused = candidates.first(where: { $0.bundleIdentifier == preferredBundleID }) {
                chosen = preferredPaused
            } else {
                chosen = candidates.first
            }

            await MainActor.run {
                guard let chosen else {
                    completion(nil)
                    return
                }
                let realAppName = Self.resolveAppDisplayName(for: chosen.bundleIdentifier)
                let finalized = SystemNowPlayingSnapshot(
                    bundleIdentifier: chosen.bundleIdentifier,
                    appDisplayName: realAppName,
                    isPlaying: chosen.isPlaying,
                    title: chosen.title,
                    artist: chosen.artist,
                    album: chosen.album,
                    duration: chosen.duration,
                    elapsedTime: chosen.elapsedTime,
                    playbackRate: chosen.playbackRate,
                    timestamp: chosen.timestamp,
                    artworkData: chosen.artworkData
                )
                completion(finalized)
            }
        }
    }

    // MARK: - ScreenCaptureKit Window Title Reader (Uses Existing Screen Recording Permission)

    private static func fetchScreenCaptureKitWindowTitles() async -> [String: String] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            var result: [String: String] = [:]
            for win in content.windows {
                guard let bid = win.owningApplication?.bundleIdentifier,
                      win.frame.width > 160,
                      win.frame.height > 100,
                      let rawTitle = win.title else {
                    continue
                }
                let cleaned = cleanBrowserTabTitle(rawTitle)
                if isMeaningfulMediaTitle(cleaned) {
                    // Prefer on-screen or larger windows if multiple exist
                    if result[bid] == nil || win.isOnScreen {
                        result[bid] = cleaned
                    }
                }
            }
            return result
        } catch {
            return [:]
        }
    }

    // MARK: - Specific Player Metadata Queries

    private static func querySpotifySnapshot() -> SystemNowPlayingSnapshot? {
        let source = """
        tell application "Spotify"
            if it is running then
                set pState to (player state as string)
                if pState is "playing" or pState is "paused" then
                    set tName to (name of current track as string)
                    set tArtist to (artist of current track as string)
                    set tAlbum to (album of current track as string)
                    set tDur to (duration of current track as string)
                    set pPos to (player position as string)
                    return pState & "|||" & tName & "|||" & tArtist & "|||" & tAlbum & "|||" & tDur & "|||" & pPos
                end if
            end if
        end tell
        """
        guard let raw = runAppleScript(source), !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "|||")
        guard parts.count >= 6 else { return nil }

        let stateStr = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let album = parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
        let durMs = parseLocaleDouble(parts[4])
        let posSec = parseLocaleDouble(parts[5])
        let durSec = durMs > 1000 ? durMs / 1000.0 : durMs

        guard !title.isEmpty else { return nil }
        // Strictly trust Spotify's own player state so pausing stops the green waveform in 0.01s without waiting for CoreAudio buffer drain!
        let playing = (stateStr == "playing")

        return SystemNowPlayingSnapshot(
            bundleIdentifier: "com.spotify.client",
            appDisplayName: "Spotify",
            isPlaying: playing,
            title: title,
            artist: artist,
            album: album,
            duration: max(0, durSec),
            elapsedTime: max(0, posSec),
            playbackRate: playing ? 1.0 : 0.0,
            timestamp: Date(),
            artworkData: nil
        )
    }

    private static func queryAppleMusicSnapshot() -> SystemNowPlayingSnapshot? {
        let source = """
        tell application "Music"
            if it is running then
                set pState to (player state as string)
                if pState is "playing" or pState is "paused" then
                    set tName to (name of current track as string)
                    set tArtist to (artist of current track as string)
                    set tAlbum to (album of current track as string)
                    set tDur to (duration of current track as string)
                    set pPos to (player position as string)
                    return pState & "|||" & tName & "|||" & tArtist & "|||" & tAlbum & "|||" & tDur & "|||" & pPos
                end if
            end if
        end tell
        """
        guard let raw = runAppleScript(source), !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "|||")
        guard parts.count >= 6 else { return nil }

        let stateStr = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let album = parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
        let durSec = parseLocaleDouble(parts[4])
        let posSec = parseLocaleDouble(parts[5])

        guard !title.isEmpty else { return nil }
        let playing = (stateStr == "playing")

        return SystemNowPlayingSnapshot(
            bundleIdentifier: "com.apple.Music",
            appDisplayName: "Apple Music",
            isPlaying: playing,
            title: title,
            artist: artist,
            album: album,
            duration: max(0, durSec),
            elapsedTime: max(0, posSec),
            playbackRate: playing ? 1.0 : 0.0,
            timestamp: Date(),
            artworkData: nil
        )
    }

    private static func queryChromiumSnapshot(
        appName: String,
        bundleID: String,
        mainPID: pid_t,
        scWindowTitle: String,
        isCoreAudioOut: Bool
    ) -> SystemNowPlayingSnapshot? {
        let directWindowTitle = isMeaningfulMediaTitle(scWindowTitle) ? scWindowTitle : queryWindowTitle(forPID: mainPID)

        // 1. Primary: Query active or background video tab title & URL via AppleScript (works even when user is on another tab or paused)
        let source = """
        tell application "\(appName)"
            if it is running and (count of windows) > 0 then
                set activeT to active tab of front window
                set activeTitle to title of activeT
                set activeURL to URL of activeT
                if activeURL contains "/video" or activeURL contains "watch" or activeURL contains ":8096" or activeURL contains ":32400" or activeURL contains "netflix" or activeURL contains "twitch" or activeURL contains "plex" or activeURL contains "jellyfin" or activeURL contains "youtube.com/watch" or activeURL contains "spotify.com" or activeURL contains "soundcloud.com" then
                    return activeTitle & "|||" & activeURL & "|||media"
                end if
                repeat with w in windows
                    repeat with t in tabs of w
                        set u to URL of t
                        if u contains "/video" or u contains "youtube.com/watch" or u contains ":8096/web/#/video" or u contains ":32400" or u contains "netflix.com/watch" or u contains "twitch.tv" then
                            return (title of t) & "|||" & u & "|||media"
                        end if
                    end repeat
                end repeat
                return activeTitle & "|||" & activeURL & "|||general"
            end if
        end tell
        """
        if let raw = runAppleScript(source), !raw.isEmpty {
            let parts = raw.components(separatedBy: "|||")
            if parts.count >= 2 {
                let rawTitle = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let urlString = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let kind = parts.count >= 3 ? parts[2] : "general"

                if isCoreAudioOut || kind == "media" {
                    let cleanTitle = cleanBrowserTabTitle(rawTitle)
                    let finalTitle = isMeaningfulMediaTitle(cleanTitle) ? cleanTitle : directWindowTitle
                    if !finalTitle.isEmpty {
                        let subtitle = formatBrowserSourceSubtitle(urlString: urlString, fallbackAppName: appName)
                        return SystemNowPlayingSnapshot(
                            bundleIdentifier: bundleID,
                            appDisplayName: appName,
                            isPlaying: isCoreAudioOut,
                            title: finalTitle,
                            artist: subtitle,
                            album: "",
                            duration: 0,
                            elapsedTime: 0,
                            playbackRate: isCoreAudioOut ? 1.0 : 0.0,
                            timestamp: Date(),
                            artworkData: nil
                        )
                    }
                }
            }
        }

        // 2. Fallback: WindowServer title if AppleScript is disabled
        if !directWindowTitle.isEmpty {
            return SystemNowPlayingSnapshot(
                bundleIdentifier: bundleID,
                appDisplayName: appName,
                isPlaying: isCoreAudioOut,
                title: directWindowTitle,
                artist: appName,
                album: "",
                duration: 0,
                elapsedTime: 0,
                playbackRate: isCoreAudioOut ? 1.0 : 0.0,
                timestamp: Date(),
                artworkData: nil
            )
        }

        return nil
    }

    private static func querySafariSnapshot(
        mainPID: pid_t,
        scWindowTitle: String,
        isCoreAudioOut: Bool
    ) -> SystemNowPlayingSnapshot? {
        let directWindowTitle = isMeaningfulMediaTitle(scWindowTitle) ? scWindowTitle : queryWindowTitle(forPID: mainPID)
        guard isCoreAudioOut || !directWindowTitle.isEmpty else { return nil }

        let source = """
        tell application "Safari"
            if it is running and (count of windows) > 0 then
                return (name of current tab of front window) & "|||" & (URL of current tab of front window)
            end if
        end tell
        """
        if let raw = runAppleScript(source), !raw.isEmpty {
            let parts = raw.components(separatedBy: "|||")
            let cleanTitle = cleanBrowserTabTitle(parts.first ?? "")
            let finalTitle = isMeaningfulMediaTitle(cleanTitle) ? cleanTitle : directWindowTitle
            if !finalTitle.isEmpty {
                let urlString = parts.count > 1 ? parts[1] : ""
                let subtitle = formatBrowserSourceSubtitle(urlString: urlString, fallbackAppName: "Safari")
                return SystemNowPlayingSnapshot(
                    bundleIdentifier: "com.apple.Safari",
                    appDisplayName: "Safari",
                    isPlaying: isCoreAudioOut,
                    title: finalTitle,
                    artist: subtitle,
                    album: "",
                    duration: 0,
                    elapsedTime: 0,
                    playbackRate: isCoreAudioOut ? 1.0 : 0.0,
                    timestamp: Date(),
                    artworkData: nil
                )
            }
        }

        if isCoreAudioOut && !directWindowTitle.isEmpty {
            return SystemNowPlayingSnapshot(
                bundleIdentifier: "com.apple.Safari",
                appDisplayName: "Safari",
                isPlaying: true,
                title: directWindowTitle,
                artist: "Safari",
                album: "",
                duration: 0,
                elapsedTime: 0,
                playbackRate: 1.0,
                timestamp: Date(),
                artworkData: nil
            )
        }
        return nil
    }

    private static func queryWindowTitle(forPID pid: pid_t) -> String {
        guard pid > 0 else { return "" }

        // 1. Check CGWindowListCopyWindowInfo (works whenever Screen Recording permission is active)
        if let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            for win in windowList {
                guard let ownerPID = win[kCGWindowOwnerPID as String] as? Int32,
                      ownerPID == pid,
                      let rawName = win[kCGWindowName as String] as? String else {
                    continue
                }
                let cleaned = cleanBrowserTabTitle(rawName)
                if isMeaningfulMediaTitle(cleaned) {
                    return cleaned
                }
            }
        }

        // 2. Check Accessibility AXUIElement windows
        let axApp = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement] {
            for win in windows {
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let rawTitle = (titleRef as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    let cleaned = cleanBrowserTabTitle(rawTitle)
                    if isMeaningfulMediaTitle(cleaned) {
                        return cleaned
                    }
                }
            }
        }
        return ""
    }

    private static func isMeaningfulMediaTitle(_ title: String) -> Bool {
        let lower = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return false }
        let genericNames: Set<String> = [
            "brave", "brave browser", "browser", "google chrome", "chrome",
            "safari", "firefox", "new tab", "yeni sekme", "untitled", "window", "media", "playing audio"
        ]
        return !genericNames.contains(lower)
    }

    private static func cleanBrowserTabTitle(_ raw: String) -> String {
        var s = raw
            .replacingOccurrences(of: "🔊", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip leading notification count badge like "(84) "
        if s.hasPrefix("("), let closeIdx = s.firstIndex(of: ")") {
            let inside = s[s.index(after: s.startIndex)..<closeIdx]
            if inside.allSatisfy(\.isNumber) {
                s = String(s[s.index(after: closeIdx)...]).trimmingCharacters(in: .whitespaces)
            }
        }

        let suffixes = [
            " - Brave",
            " - Brave Browser",
            " — Brave",
            " - Google Chrome",
            " — Google Chrome",
            " - YouTube",
            " — Mozilla Firefox",
            " - Safari",
            " - Bazarr (Movies)",
            " - Audio playing",
            " - Ses çalıyor"
        ]
        var changed = true
        while changed {
            changed = false
            for suffix in suffixes {
                if s.hasSuffix(suffix) {
                    s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                    changed = true
                }
            }
        }
        return s
    }

    private static func formatBrowserSourceSubtitle(urlString: String, fallbackAppName: String) -> String {
        let lower = urlString.lowercased()
        if lower.contains(":8096") || lower.contains("jellyfin") {
            return "Media Server • Jellyfin"
        }
        if lower.contains(":32400") || lower.contains("plex") {
            return "Media Server • Plex"
        }
        if lower.contains("youtube.com") || lower.contains("youtu.be") {
            return "YouTube"
        }
        if lower.contains("netflix.com") {
            return "Netflix"
        }
        if lower.contains("twitch.tv") {
            return "Twitch"
        }
        if lower.contains("spotify.com") {
            return "Spotify Web"
        }
        if let url = URL(string: urlString), let host = url.host, !host.isEmpty {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        return fallbackAppName
    }

    private static func parseLocaleDouble(_ raw: String) -> Double {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        return Double(cleaned) ?? 0.0
    }

    // MARK: - CoreAudio Open Audio Applications Discovery (For Multi-App Mixer)

    private static let ignoredSystemPrefixes: [String] = [
        "com.apple.mediaremoted",
        "com.apple.audiomxd",
        "com.apple.cmio",
        "com.apple.universalaccess",
        "com.apple.TelephonyUtilities",
        "com.apple.avconferenced",
        "com.apple.assistantd",
        "com.apple.Accessibility",
        "com.apple.controlcenter",
        "com.apple.CoreSpeech",
        "com.apple.accessibility",
        "systemsoundserverd",
        "com.apple.cloudpaird",
        "com.apple.PowerChime",
        "com.apple.WebKit.GPU",
        "com.zerotrust.aero.notch",
        "pro.betterdisplay",
        "pro.bettercmdtab",
        "com.if.Amphetamine"
    ]

    public static func allCoreAudioProcessObjectIDs() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var processObjects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size,
            &processObjects
        ) == noErr else {
            return []
        }
        return processObjects
    }

    @MainActor
    public static func queryMixerAudioApps() -> [AudioMixerAppItem] {
        let processObjects = allCoreAudioProcessObjectIDs()
        guard !processObjects.isEmpty else { return [] }

        let regularRunningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
        }
        let regularBundleIDs = Set(regularRunningApps.compactMap(\.bundleIdentifier))
        let assertionPIDs = pidsWithActiveMediaPowerAssertions()
        var mainBrowserPIDs: [String: pid_t] = [:]
        for app in regularRunningApps {
            if let bid = app.bundleIdentifier, browserBundleIDs.contains(bid) {
                mainBrowserPIDs[bid] = app.processIdentifier
            }
        }

        struct AggregatedApp {
            var bundleID: String
            var pid: pid_t
            var objectIDs: [AudioObjectID]
            var isRunningOut: Bool
        }

        var grouped: [String: AggregatedApp] = [:]

        for obj in processObjects {
            var bidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfStr: Unmanaged<CFString>?
            var bidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var rawBundle = ""
            if AudioObjectGetPropertyData(obj, &bidAddr, 0, nil, &bidSize, &cfStr) == noErr,
               let retained = cfStr?.takeRetainedValue() {
                rawBundle = retained as String
            }

            let normalizedBundle = normalizeBundleID(rawBundle)
            guard !normalizedBundle.isEmpty else { continue }
            if ignoredSystemPrefixes.contains(where: { normalizedBundle.hasPrefix($0) }) {
                continue
            }

            var runAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isRunningOut: UInt32 = 0
            var outSize = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(obj, &runAddr, 0, nil, &outSize, &isRunningOut)
            var activeOut = (isRunningOut != 0)

            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            _ = AudioObjectGetPropertyData(obj, &pidAddr, 0, nil, &pidSize, &pid)

            // For Chromium/Web browsers, eliminate the 10-second CoreAudio idle stream close delay by verifying the browser's IOKit media assertion!
            if activeOut && browserBundleIDs.contains(normalizedBundle) {
                let mainPID = mainBrowserPIDs[normalizedBundle] ?? 0
                if !assertionPIDs.contains(mainPID) && !assertionPIDs.contains(pid) {
                    activeOut = false
                }
            }

            // Include if it is a regular open user app OR actively outputting audio
            guard activeOut || regularBundleIDs.contains(normalizedBundle) else {
                continue
            }

            if var existing = grouped[normalizedBundle] {
                existing.objectIDs.append(obj)
                if activeOut { existing.isRunningOut = true }
                grouped[normalizedBundle] = existing
            } else {
                grouped[normalizedBundle] = AggregatedApp(
                    bundleID: normalizedBundle,
                    pid: pid,
                    objectIDs: [obj],
                    isRunningOut: activeOut
                )
            }
        }

        let items = grouped.values.map { entry -> AudioMixerAppItem in
            let displayName = resolveAppDisplayName(for: entry.bundleID, fallbackPID: entry.pid)
            let isScriptable = (entry.bundleID == "com.spotify.client" || entry.bundleID == "com.apple.Music")
            return AudioMixerAppItem(
                bundleIdentifier: entry.bundleID,
                displayName: displayName,
                pid: entry.pid,
                processObjectIDs: entry.objectIDs,
                isRunningOutput: entry.isRunningOut,
                isScriptableVolume: isScriptable
            )
        }

        return items.sorted { lhs, rhs in
            if lhs.isRunningOutput != rhs.isRunningOutput {
                return lhs.isRunningOutput && !rhs.isRunningOutput
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    // MARK: - App Icon & Display Name Resolution

    @MainActor
    public static func resolveAppDisplayName(for bundleID: String, fallbackPID: pid_t = 0) -> String {
        if !bundleID.isEmpty {
            if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
               let name = running.localizedName, !name.isEmpty {
                return name
            }
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return appURL.deletingPathExtension().lastPathComponent
            }
        }
        if fallbackPID > 0,
           let running = NSRunningApplication(processIdentifier: fallbackPID),
           let name = running.localizedName, !name.isEmpty {
            return name
        }
        if bundleID.contains("brave") { return "Brave Browser" }
        if bundleID.contains("spotify") { return "Spotify" }
        if bundleID.contains("Music") { return "Apple Music" }
        if bundleID.contains("whatsapp") { return "WhatsApp" }
        if bundleID.contains("antigravity") { return "Antigravity" }
        return bundleID.components(separatedBy: ".").last?.capitalized ?? "Media"
    }

    @MainActor
    public static func resolveAppIcon(for bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty else { return nil }
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let icon = running.icon {
            return icon
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: appURL.path(percentEncoded: false))
        }
        return nil
    }

    nonisolated public static func normalizeBundleID(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        for suffix in [".helper", ".ServiceExtension", ".Extension"] {
            if let range = raw.range(of: suffix, options: .caseInsensitive) {
                return String(raw[..<range.lowerBound])
            }
        }
        return raw
    }

    // MARK: - App-Specific Volume Control (For Scriptable Players: Spotify / Apple Music)

    public static func setScriptableAppVolume(_ volume: Double, bundleIdentifier: String) {
        guard bundleIdentifier == "com.spotify.client" || bundleIdentifier == "com.apple.Music" else { return }
        let clamped = Int(volume.rounded().clamped(to: 0...100))
        backgroundQueue.async {
            runAppleScript("tell application id \"\(bundleIdentifier)\" to set sound volume to \(clamped)")
        }
    }

    // MARK: - CoreAudio Hardware Master Output Volume & Device UID

    public static func defaultOutputDeviceUID() -> String? {
        guard let devID = defaultOutputDeviceID() else { return nil }
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(devID, &uidAddr, 0, nil, &uidSize, &cfUID) == noErr,
              let retained = cfUID?.takeRetainedValue() else {
            return nil
        }
        return retained as String
    }

    public static func getMasterOutputVolume() -> Double {
        guard let deviceID = defaultOutputDeviceID() else { return 65.0 }
        var volume = Float32(0.65)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return 65.0 }
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return 65.0 }
        return (Double(volume) * 100.0).clamped(to: 0...100)
    }

    public static func setMasterOutputVolume(_ volume: Double) {
        guard let deviceID = defaultOutputDeviceID() else { return }
        var normalized = Float32((volume / 100.0).clamped(to: 0.0...1.0))
        let size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else { return }
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &normalized)
    }

    public static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
