import AppKit
import CoreAudio
import Foundation
import Observation

/// Universal System-Wide Now Playing & Multi-Application CoreAudio Mixer Coordinator.
@MainActor
@Observable
public final class AudioManager: NSObject {
    private static let perAppVolumesKey = "com.zerotrust.aero.audio.perAppVolumes"

    public var activeBundleID: String = ""
    public var activeAppName: String = "Media"
    public var isPlaying: Bool = false
    public var trackTitle: String = "Nothing Playing"
    public var artistName: String = ""
    public var albumName: String = ""
    public var artworkImage: NSImage?
    public var appIcon: NSImage?

    /// Media duration & elapsed time in seconds.
    public var duration: Double = 0
    public var elapsedTime: Double = 0

    /// Open applications discovered via CoreAudio whose volumes can be independently controlled.
    public var mixerApps: [AudioMixerAppItem] = []
    /// Per-application volume levels (0...100), keyed by bundle identifier.
    public var perAppVolumes: [String: Double] = [:]
    /// Per-application mute state, keyed by bundle identifier.
    public var mutedBundleIDs: Set<String> = []

    /// Mac Master Output Volume (0...100)
    public var masterVolume: Double = 65.0

    public var onPlaybackChanged: ((Bool, String, String) -> Void)?

    private var activeTapSessions: [String: AppAudioTapSession] = [:]
    private var observedProcessObjectIDs: Set<AudioObjectID> = []
    private var observedOutputDeviceID: AudioDeviceID = 0
    private var lastActiveSnapshot: SystemNowPlayingSnapshot?
    private var manualToggleLockUntil: Date = .distantPast
    /// Prevents Chromium's ~1.2s silent CoreAudio buffer drain from re-enabling `isPlaying` after an instant MediaRemote pause event.
    private var coreAudioTailCooldownUntil: Date = .distantPast
    private var lastKnownMediaRemotePlaying: Bool = false
    private var terminationObserver: NSObjectProtocol?
    private var refreshDebounceWorkItem: DispatchWorkItem?
    private var delayedFollowUpWorkItem: DispatchWorkItem?
    private var activePlaybackWatchTimer: Timer?
    private var watchTickCount: Int = 0
    private var globalMediaTriggerMonitor: Any?

    public override init() {
        super.init()
        self.masterVolume = MediaController.getMasterOutputVolume()

        if let savedVolumes = UserDefaults.standard.dictionary(forKey: Self.perAppVolumesKey) as? [String: Double] {
            self.perAppVolumes = savedVolumes
        }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.destroyAllTapSessions()
            }
        }

        MediaController.registerForSystemMediaNotifications()
        registerMediaRemoteObservers()
        registerCoreAudioProcessListeners()
        installEventDrivenInteractionTrigger()
        refreshSystemMediaState()
    }

    // MARK: - Event-Driven CoreAudio Hardware Process Listeners

    private func registerCoreAudioProcessListeners() {
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        _ = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddr,
            DispatchQueue.main
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.attachListenersToCurrentProcessObjects()
                self.scheduleCoalescedRefresh(withFollowUp: true)
            }
        }

        attachOutputDeviceRunningListener()
        attachListenersToCurrentProcessObjects()
    }

    private func attachOutputDeviceRunningListener() {
        guard let devID = MediaController.defaultOutputDeviceID(), devID != observedOutputDeviceID else { return }
        observedOutputDeviceID = devID
        var runSomewhereAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectAddPropertyListenerBlock(
            devID,
            &runSomewhereAddr,
            DispatchQueue.main
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.scheduleCoalescedRefresh(withFollowUp: true)
            }
        }
    }

    private func attachListenersToCurrentProcessObjects() {
        let allIDs = MediaController.allCoreAudioProcessObjectIDs()
        for objID in allIDs where !observedProcessObjectIDs.contains(objID) {
            observedProcessObjectIDs.insert(objID)

            var wildcardAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertySelectorWildcard,
                mScope: kAudioObjectPropertyScopeWildcard,
                mElement: kAudioObjectPropertyElementWildcard
            )
            _ = AudioObjectAddPropertyListenerBlock(
                objID,
                &wildcardAddr,
                DispatchQueue.main
            ) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.scheduleCoalescedRefresh(withFollowUp: true)
                }
            }
        }
    }

    /// Catches browser play/pause clicks or Spacebar/K presses immediately.
    private func installEventDrivenInteractionTrigger() {
        globalMediaTriggerMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp, .keyDown]
        ) { [weak self] event in
            if event.type == .keyDown {
                let code = event.keyCode
                guard code == 49 || code == 40 || code == 36 else { return }
            }
            Task { @MainActor [weak self] in
                self?.scheduleCoalescedRefresh(withFollowUp: true)
            }
        }
    }

    private func scheduleCoalescedRefresh(withFollowUp: Bool = false) {
        refreshDebounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshSystemMediaState()
            }
        }
        refreshDebounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)

        if withFollowUp {
            delayedFollowUpWorkItem?.cancel()
            let followUp = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    self?.refreshSystemMediaState()
                }
            }
            delayedFollowUpWorkItem = followUp
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: followUp)
        }
    }

    /// Runs a 0.15s ultra-fast check ONLY while `isPlaying == true` so pausing in Brave or Spotify stops the green waveform instantaneously.
    /// Automatically invalidates the moment `isPlaying` becomes `false` (strictly 0.0% idle CPU).
    private func updateActivePlaybackWatchTimer() {
        if isPlaying {
            guard activePlaybackWatchTimer == nil else { return }
            watchTickCount = 0
            activePlaybackWatchTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if !self.isPlaying {
                        self.activePlaybackWatchTimer?.invalidate()
                        self.activePlaybackWatchTimer = nil
                        return
                    }
                    self.performFastPlaybackPulseCheck()
                }
            }
        } else {
            activePlaybackWatchTimer?.invalidate()
            activePlaybackWatchTimer = nil
        }
    }

    /// 0.05ms synchronous C-memory + 10ms MediaRemote check that stops the green waveform immediately without waiting for Chromium's 1.2s buffer drain.
    private func performFastPlaybackPulseCheck() {
        guard Date() >= manualToggleLockUntil else { return }

        // 1. Check MediaRemote instant playback state (~10ms) to catch Chromium/Brave HTML5 video pause before CoreAudio drains
        MediaController.querySystemMediaRemoteIsPlaying { [weak self] mrPlaying in
            guard let self, self.isPlaying, Date() >= self.manualToggleLockUntil else { return }
            if self.lastKnownMediaRemotePlaying && !mrPlaying {
                self.lastKnownMediaRemotePlaying = false
                self.coreAudioTailCooldownUntil = Date().addingTimeInterval(1.75)
                self.isPlaying = false
                if let recent = self.lastActiveSnapshot {
                    self.lastActiveSnapshot = recent.withPlayingState(false)
                }
                self.updateActivePlaybackWatchTimer()
                self.onPlaybackChanged?(false, self.trackTitle, self.artistName)
                return
            }
            self.lastKnownMediaRemotePlaying = mrPlaying
        }

        // 2. Direct CoreAudio check
        let activeBundles = MediaController.activeAudioOutputBundleIDs()
        if activeBundles.isEmpty || Date() < coreAudioTailCooldownUntil {
            isPlaying = false
            if let recent = lastActiveSnapshot {
                lastActiveSnapshot = recent.withPlayingState(false)
            }
            mixerApps = MediaController.queryMixerAudioApps()
            updateActivePlaybackWatchTimer()
            onPlaybackChanged?(false, trackTitle, artistName)
            return
        }

        watchTickCount += 1
        // Refresh full metadata title every ~1.2s while playing (e.g. if the browser tab title changed)
        if watchTickCount % 8 == 0 {
            refreshSystemMediaState()
        }
    }

    // MARK: - System-Wide MediaRemote & Distributed Notification Observers

    private func registerMediaRemoteObservers() {
        let nc = NotificationCenter.default
        let mrNotificationNames = [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"
        ]

        for name in mrNotificationNames {
            nc.addObserver(
                self,
                selector: #selector(onSystemMediaNotification(_:)),
                name: Notification.Name(name),
                object: nil
            )
        }

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            self,
            selector: #selector(onSpotifyNotification(_:)),
            name: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        dnc.addObserver(
            self,
            selector: #selector(onAppleMusicNotification(_:)),
            name: Notification.Name("com.apple.Music.playerInfo"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc nonisolated private func onSystemMediaNotification(_ notification: Notification) {
        let name = notification.name.rawValue
        Task { @MainActor [weak self] in
            guard let self else { return }
            if name == "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification" {
                MediaController.querySystemMediaRemoteIsPlaying { [weak self] mrPlaying in
                    guard let self else { return }
                    self.lastKnownMediaRemotePlaying = mrPlaying
                    if !mrPlaying {
                        // Instant pause (10ms) for Brave Browser / Safari / Chrome / Spotify:
                        // Suppress Chromium's 1.2s silent CoreAudio buffer drain!
                        self.coreAudioTailCooldownUntil = Date().addingTimeInterval(1.75)
                        self.isPlaying = false
                        if let recent = self.lastActiveSnapshot {
                            self.lastActiveSnapshot = recent.withPlayingState(false)
                        }
                        self.updateActivePlaybackWatchTimer()
                        self.onPlaybackChanged?(false, self.trackTitle, self.artistName)
                    } else {
                        // Instant resume (10ms)
                        self.coreAudioTailCooldownUntil = .distantPast
                        self.isPlaying = true
                        if let recent = self.lastActiveSnapshot {
                            self.lastActiveSnapshot = recent.withPlayingState(true)
                        }
                        self.updateActivePlaybackWatchTimer()
                        self.onPlaybackChanged?(true, self.trackTitle, self.artistName)
                        self.scheduleCoalescedRefresh(withFollowUp: false)
                    }
                }
                return
            }
            self.scheduleCoalescedRefresh(withFollowUp: true)
        }
    }

    @objc nonisolated private func onSpotifyNotification(_ notification: Notification) {
        let info = notification.userInfo
        let state = (info?["Player State"] as? String) ?? ""
        let name = (info?["Name"] as? String) ?? ""
        let artist = (info?["Artist"] as? String) ?? ""
        let album = (info?["Album"] as? String) ?? ""
        let durMs = (info?["Duration"] as? NSNumber)?.doubleValue ?? 0
        let posSec = (info?["Playback Position"] as? NSNumber)?.doubleValue ?? 0

        Task { @MainActor [weak self] in
            guard let self else { return }
            let spotifyPlaying = (state.lowercased() == "playing")
            if !name.isEmpty && (spotifyPlaying || self.activeBundleID.isEmpty || self.activeBundleID == "com.spotify.client") {
                self.activeBundleID = "com.spotify.client"
                self.activeAppName = "Spotify"
                self.isPlaying = spotifyPlaying
                self.trackTitle = name
                self.artistName = artist.isEmpty ? "Spotify" : artist
                self.albumName = album
                self.duration = durMs > 1000 ? durMs / 1000.0 : durMs
                self.elapsedTime = posSec
                self.appIcon = MediaController.resolveAppIcon(for: "com.spotify.client")
                self.lastActiveSnapshot = SystemNowPlayingSnapshot(
                    bundleIdentifier: "com.spotify.client",
                    appDisplayName: "Spotify",
                    isPlaying: spotifyPlaying,
                    title: name,
                    artist: self.artistName,
                    album: album,
                    duration: self.duration,
                    elapsedTime: posSec,
                    playbackRate: spotifyPlaying ? 1.0 : 0.0,
                    timestamp: Date(),
                    artworkData: nil
                )
                self.updateActivePlaybackWatchTimer()
                self.onPlaybackChanged?(self.isPlaying, self.trackTitle, self.artistName)
            }
        }
    }

    @objc nonisolated private func onAppleMusicNotification(_ notification: Notification) {
        let info = notification.userInfo
        let state = (info?["Player State"] as? String) ?? ""
        let name = (info?["Name"] as? String) ?? ""
        let artist = (info?["Artist"] as? String) ?? ""
        let album = (info?["Album"] as? String) ?? ""
        let totalTimeMs = (info?["Total Time"] as? NSNumber)?.doubleValue ?? 0

        Task { @MainActor [weak self] in
            guard let self else { return }
            let musicPlaying = (state.lowercased() == "playing")
            if !name.isEmpty && (musicPlaying || self.activeBundleID.isEmpty || self.activeBundleID == "com.apple.Music") {
                self.activeBundleID = "com.apple.Music"
                self.activeAppName = "Apple Music"
                self.isPlaying = musicPlaying
                self.trackTitle = name
                self.artistName = artist.isEmpty ? "Apple Music" : artist
                self.albumName = album
                self.duration = totalTimeMs > 1000 ? totalTimeMs / 1000.0 : totalTimeMs
                self.appIcon = MediaController.resolveAppIcon(for: "com.apple.Music")
                self.lastActiveSnapshot = SystemNowPlayingSnapshot(
                    bundleIdentifier: "com.apple.Music",
                    appDisplayName: "Apple Music",
                    isPlaying: musicPlaying,
                    title: name,
                    artist: self.artistName,
                    album: album,
                    duration: self.duration,
                    elapsedTime: 0,
                    playbackRate: musicPlaying ? 1.0 : 0.0,
                    timestamp: Date(),
                    artworkData: nil
                )
                self.updateActivePlaybackWatchTimer()
                self.onPlaybackChanged?(self.isPlaying, self.trackTitle, self.artistName)
            }
        }
    }

    // MARK: - Live State Synchronization ("Keep the Most Recent Player")

    public func refreshSystemMediaState() {
        masterVolume = MediaController.getMasterOutputVolume()
        attachOutputDeviceRunningListener()
        attachListenersToCurrentProcessObjects()
        let currentMixerApps = MediaController.queryMixerAudioApps()
        mixerApps = currentMixerApps

        let isInTailCooldown = Date() < coreAudioTailCooldownUntil
        let anyOutputtingNow = !isInTailCooldown && currentMixerApps.contains(where: \.isRunningOutput)
        if !anyOutputtingNow && Date() >= manualToggleLockUntil && isPlaying {
            isPlaying = false
            onPlaybackChanged?(false, trackTitle, artistName)
        }

        MediaController.querySystemMediaRemoteIsPlaying { [weak self] mrPlaying in
            self?.lastKnownMediaRemotePlaying = mrPlaying
        }

        let preferredID = lastActiveSnapshot?.bundleIdentifier ?? activeBundleID

        MediaController.fetchSystemNowPlaying(
            mixerApps: currentMixerApps,
            preferredBundleID: preferredID
        ) { [weak self] fetchedSnapshot in
            guard let self else { return }
            let isLockedByManualToggle = Date() < self.manualToggleLockUntil
            let suppressTail = Date() < self.coreAudioTailCooldownUntil

            let effectiveSnapshot: SystemNowPlayingSnapshot?
            if let fetched = fetchedSnapshot {
                let adjustedFetched = suppressTail ? fetched.withPlayingState(false) : fetched
                if adjustedFetched.isPlaying {
                    effectiveSnapshot = adjustedFetched
                } else if let recent = self.lastActiveSnapshot,
                          recent.bundleIdentifier != adjustedFetched.bundleIdentifier,
                          NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == recent.bundleIdentifier && !$0.isTerminated }) {
                    effectiveSnapshot = recent.withPlayingState(false)
                } else {
                    effectiveSnapshot = adjustedFetched
                }
            } else if let recent = self.lastActiveSnapshot,
                      NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == recent.bundleIdentifier && !$0.isTerminated }) {
                effectiveSnapshot = recent.withPlayingState(false)
            } else {
                effectiveSnapshot = nil
            }

            if let snapshot = effectiveSnapshot {
                self.lastActiveSnapshot = snapshot
                self.activeBundleID = snapshot.bundleIdentifier
                self.activeAppName = snapshot.appDisplayName
                if !isLockedByManualToggle {
                    self.isPlaying = snapshot.isPlaying
                }
                self.trackTitle = snapshot.title
                self.artistName = snapshot.artist.isEmpty ? snapshot.appDisplayName : snapshot.artist
                self.albumName = snapshot.album
                self.duration = snapshot.duration
                self.elapsedTime = snapshot.elapsedTime

                if let artData = snapshot.artworkData, let img = NSImage(data: artData) {
                    self.artworkImage = img
                } else {
                    self.artworkImage = nil
                }
                self.appIcon = MediaController.resolveAppIcon(for: snapshot.bundleIdentifier)
            } else {
                if !isLockedByManualToggle {
                    self.isPlaying = false
                }
            }

            self.updateActivePlaybackWatchTimer()
            self.onPlaybackChanged?(self.isPlaying, self.trackTitle, self.artistName)
        }
    }

    public func refreshMasterVolumeOnly() {
        refreshSystemMediaState()
    }

    // MARK: - Transport & Seek Actions

    public func togglePlayPause() {
        AeroHaptics.playAlignmentTap()
        isPlaying.toggle()
        manualToggleLockUntil = Date().addingTimeInterval(0.75)
        updateActivePlaybackWatchTimer()
        onPlaybackChanged?(isPlaying, trackTitle, artistName)
        MediaController.togglePlayPause(bundleIdentifier: activeBundleID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshSystemMediaState()
        }
    }

    public func nextTrack() {
        AeroHaptics.playAlignmentTap()
        MediaController.nextTrack(bundleIdentifier: activeBundleID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.refreshSystemMediaState()
        }
    }

    public func previousTrack() {
        AeroHaptics.playAlignmentTap()
        MediaController.previousTrack(bundleIdentifier: activeBundleID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.refreshSystemMediaState()
        }
    }

    public func seek(to newSeconds: Double) {
        elapsedTime = newSeconds
        MediaController.seek(to: newSeconds, bundleIdentifier: activeBundleID)
    }

    // MARK: - Master & Per-Application Independent Volume Mixer

    public func updateMasterVolume(_ newValue: Double) {
        masterVolume = newValue
        MediaController.setMasterOutputVolume(newValue)
    }

    public func volume(for app: AudioMixerAppItem) -> Double {
        if mutedBundleIDs.contains(app.bundleIdentifier) {
            return 0
        }
        return perAppVolumes[app.bundleIdentifier] ?? 100.0
    }

    public func isMuted(_ app: AudioMixerAppItem) -> Bool {
        mutedBundleIDs.contains(app.bundleIdentifier)
    }

    public func toggleMute(for app: AudioMixerAppItem) {
        AeroHaptics.playAlignmentTap()
        if mutedBundleIDs.contains(app.bundleIdentifier) {
            mutedBundleIDs.remove(app.bundleIdentifier)
            let restored = perAppVolumes[app.bundleIdentifier] ?? 100.0
            applyAppVolume(restored, for: app)
        } else {
            mutedBundleIDs.insert(app.bundleIdentifier)
            applyAppVolume(0.0, for: app)
        }
    }

    public func setVolume(_ newValue: Double, for app: AudioMixerAppItem) {
        let clamped = min(100.0, max(0.0, newValue))
        perAppVolumes[app.bundleIdentifier] = clamped
        if clamped > 0.5 {
            mutedBundleIDs.remove(app.bundleIdentifier)
        }
        UserDefaults.standard.set(perAppVolumes, forKey: Self.perAppVolumesKey)
        applyAppVolume(clamped, for: app)
    }

    private func applyAppVolume(_ volumePercent: Double, for app: AudioMixerAppItem) {
        if app.isScriptableVolume {
            MediaController.setScriptableAppVolume(volumePercent, bundleIdentifier: app.bundleIdentifier)
            return
        }

        let gain = Float(volumePercent / 100.0)
        // If volume is at 100% and unmuted, tear down tap session for 0% CPU overhead
        if gain >= 0.995 && !mutedBundleIDs.contains(app.bundleIdentifier) {
            if let existing = activeTapSessions.removeValue(forKey: app.bundleIdentifier) {
                existing.stopAndDestroy()
            }
            return
        }

        if let existing = activeTapSessions[app.bundleIdentifier] {
            existing.targetGain = gain
        } else if let outputUID = MediaController.defaultOutputDeviceUID(),
                  let newSession = AppAudioTapSession(
                      bundleIdentifier: app.bundleIdentifier,
                      processObjectIDs: app.processObjectIDs,
                      outputDeviceUID: outputUID,
                      initialGain: gain
                  ) {
            activeTapSessions[app.bundleIdentifier] = newSession
        }
    }

    public func destroyAllTapSessions() {
        for session in activeTapSessions.values {
            session.stopAndDestroy()
        }
        activeTapSessions.removeAll()
    }

    public static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }
}
