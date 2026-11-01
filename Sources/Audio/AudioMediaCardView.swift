import AppKit
import SwiftUI

/// Universal Media Playback HUD & Multi-Application Independent Audio Mixer.
public struct AudioMediaCardView: View {
    @Bindable var audioManager: AudioManager
    public var isFullTab: Bool

    public init(audioManager: AudioManager, isFullTab: Bool = false) {
        self.audioManager = audioManager
        self.isFullTab = isFullTab
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Top Track Info & Transport Row
            HStack(spacing: 10) {
                artworkThumbnail

                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(audioManager.isPlaying ? Color.aeroEmerald : .white.opacity(0.3))
                            .frame(width: 5, height: 5)
                        Text("\(audioManager.activeAppName.uppercased()) • \(audioManager.isPlaying ? "PLAYING" : "PAUSED")")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .tracking(0.4)
                            .foregroundStyle(audioManager.isPlaying ? Color.aeroEmerald.opacity(0.95) : .white.opacity(0.45))
                            .lineLimit(1)
                    }

                    Text(audioManager.trackTitle)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if !audioManager.artistName.isEmpty {
                        Text(audioManager.artistName)
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Transport Controls
                HStack(spacing: 5) {
                    transportButton(icon: "backward.fill", size: 9.5) {
                        audioManager.previousTrack()
                    }

                    Button {
                        audioManager.togglePlayPause()
                    } label: {
                        Image(systemName: audioManager.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 25, height: 25)
                            .background(audioManager.isPlaying ? Color.aeroEmerald : Color.white.opacity(0.9), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .id(audioManager.isPlaying)

                    transportButton(icon: "forward.fill", size: 9.5) {
                        audioManager.nextTrack()
                    }
                }
            }

            if isFullTab && audioManager.duration > 0 {
                seekSliderRow
            }

            Divider()
                .overlay(Color.white.opacity(0.08))

            // Multi-Application Audio Mixer (Master + All Open Audio Apps)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 5) {
                    // Master Output Slider
                    mixerSliderRow(
                        label: "Mac Out",
                        icon: audioManager.masterVolume < 1 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        isActiveStream: false,
                        isMuted: audioManager.masterVolume < 1,
                        accent: .white,
                        value: Binding(
                            get: { audioManager.masterVolume },
                            set: { audioManager.updateMasterVolume($0) }
                        ),
                        onIconTap: {
                            audioManager.updateMasterVolume(audioManager.masterVolume > 1 ? 0 : 65)
                        }
                    )

                    // Individual Per-Application Sliders
                    ForEach(audioManager.mixerApps) { app in
                        let currentVol = audioManager.volume(for: app)
                        let muted = audioManager.isMuted(app)
                        mixerSliderRow(
                            label: app.displayName,
                            icon: muted || currentVol < 1 ? "speaker.slash.fill" : (app.isRunningOutput ? "waveform" : "app.fill"),
                            isActiveStream: app.isRunningOutput,
                            isMuted: muted || currentVol < 1,
                            accent: app.isRunningOutput ? .aeroEmerald : .white.opacity(0.75),
                            value: Binding(
                                get: { audioManager.volume(for: app) },
                                set: { audioManager.setVolume($0, for: app) }
                            ),
                            onIconTap: {
                                audioManager.toggleMute(for: app)
                            }
                        )
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(maxHeight: isFullTab ? .infinity : 56)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.aeroSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            audioManager.isPlaying ? Color.aeroEmerald.opacity(0.35) : Color.white.opacity(0.08),
                            lineWidth: 1
                        )
                )
        )
    }

    // MARK: - Artwork / App Icon Emblem

    @ViewBuilder
    private var artworkThumbnail: some View {
        if let nsImage = audioManager.artworkImage {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if let icon = audioManager.appIcon {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 36, height: 36)

                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 26, height: 26)
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.aeroEmerald.opacity(0.24), Color.white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)

                Image(systemName: audioManager.isPlaying ? "waveform" : "play.tv")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(audioManager.isPlaying ? Color.aeroEmerald : .white.opacity(0.5))
            }
        }
    }

    private func transportButton(icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 23, height: 23)
                .background(Color.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func mixerSliderRow(
        label: String,
        icon: String,
        isActiveStream: Bool,
        isMuted: Bool,
        accent: Color,
        value: Binding<Double>,
        onIconTap: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Button(action: onIconTap) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(isMuted ? Color.aeroAmber : accent.opacity(0.9))
                    .frame(width: 15, height: 15)
            }
            .buttonStyle(.plain)
            .help("Click to Mute / Unmute \(label)")

            HStack(spacing: 3) {
                if isActiveStream {
                    Circle()
                        .fill(Color.aeroEmerald)
                        .frame(width: 4, height: 4)
                }
                Text(label)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(isActiveStream ? .white : .white.opacity(0.65))
                    .lineLimit(1)
            }
            .frame(width: isFullTab ? 110 : 62, alignment: .leading)

            Slider(value: value, in: 0...100)
                .controlSize(.mini)
                .tint(isMuted ? Color.aeroAmber : accent)

            Text("\(Int(value.wrappedValue.rounded()))%")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 30, alignment: .trailing)
        }
    }

    private var seekSliderRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "clock.fill")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Color.aeroEmerald.opacity(0.85))
                .frame(width: 14)

            Text(AudioManager.formatTime(audioManager.elapsedTime))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 44, alignment: .leading)
                .lineLimit(1)

            Slider(
                value: Binding(
                    get: { min(audioManager.elapsedTime, max(audioManager.duration, 1)) },
                    set: { audioManager.seek(to: $0) }
                ),
                in: 0...max(audioManager.duration, 1)
            )
            .controlSize(.mini)
            .tint(Color.aeroEmerald)

            Text(AudioManager.formatTime(audioManager.duration))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 42, alignment: .trailing)
                .lineLimit(1)
        }
    }
}
