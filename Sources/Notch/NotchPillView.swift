import SwiftUI

/// Renders the compact Idle state of the Aero Notch around the physical camera housing in pure #000000 black.
public struct NotchPillView: View {
    @Bindable var screenState: ScreenNotchState
    @Bindable var appState: AppState

    public init(screenState: ScreenNotchState) {
        self.screenState = screenState
        self.appState = screenState.appState
    }

    public var body: some View {
        HStack(spacing: 0) {
            leftWing
                .frame(maxWidth: .infinity, alignment: .leading)

            // Reserved physical camera housing cutout space (179pt on M3)
            Spacer(minLength: max(screenState.geometry.notchWidth - 8, 110))

            rightWing
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 11)
        .frame(height: screenState.geometry.notchHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            screenState.toggleExpanded()
        }
    }

    // MARK: - Left Wing (Power Assertion Amber Dot & Shelf Status)

    @ViewBuilder
    private var leftWing: some View {
        HStack(spacing: 5) {
            if appState.isCaffeinateActive {
                Circle()
                    .fill(Color.aeroAmber)
                    .frame(width: 7, height: 7)
                    .shadow(color: Color.aeroAmber.opacity(0.9), radius: 4)
                    .help("Caffeinate Active (\(appState.caffeinateBadgeText))")
            }

            if appState.shelvedFileCount > 0 {
                HStack(spacing: 2.5) {
                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 8.5, weight: .bold))
                    Text("\(appState.shelvedFileCount)")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 4.5)
                .padding(.vertical, 1.5)
                .background(Color.white.opacity(0.14), in: Capsule())
            }
        }
    }

    // MARK: - Right Wing (Animated 3-Bar Green Audio Waveform)

    @ViewBuilder
    private var rightWing: some View {
        HStack(spacing: 5) {
            if appState.isAudioPlaying {
                MiniWaveformEqualizer(isPlaying: appState.isAudioPlaying)
            }
        }
    }
}

// MARK: - Zero-Polling 3-Bar Mini Audio Equalizer

/// CoreAnimation-backed PhaseAnimator equalizer that only runs when `isPlaying` is true.
public struct MiniWaveformEqualizer: View {
    public let isPlaying: Bool

    public init(isPlaying: Bool) {
        self.isPlaying = isPlaying
    }

    public var body: some View {
        if isPlaying {
            PhaseAnimator([false, true]) { phase in
                HStack(alignment: .center, spacing: 2.2) {
                    capsuleBar(height: phase ? 12 : 4)
                    capsuleBar(height: phase ? 5 : 13)
                    capsuleBar(height: phase ? 10 : 5)
                }
            } animation: { _ in
                .easeInOut(duration: 0.36)
            }
            .frame(height: 14)
        } else {
            HStack(alignment: .center, spacing: 2.2) {
                capsuleBar(height: 3)
                capsuleBar(height: 3)
                capsuleBar(height: 3)
            }
            .frame(height: 14)
        }
    }

    private func capsuleBar(height: CGFloat) -> some View {
        Capsule()
            .fill(Color.aeroEmerald)
            .frame(width: 2.4, height: height)
    }
}
