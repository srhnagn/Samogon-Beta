import SwiftUI

/// Full Swiss-Knife Tools workspace containing the native AutoRaise (Focus-Follows-Mouse) Engine and Scrolling Capture Engine.
public struct SwissKnifeToolsView: View {
    @Bindable var autoRaiseManager: AutoRaiseManager
    @Bindable var scrollingCaptureManager: ScrollingCaptureManager

    public init(
        autoRaiseManager: AutoRaiseManager,
        scrollingCaptureManager: ScrollingCaptureManager
    ) {
        self.autoRaiseManager = autoRaiseManager
        self.scrollingCaptureManager = scrollingCaptureManager
    }

    public var body: some View {
        HStack(spacing: 10) {
            autoRaiseCard
            scrollingCaptureCard
        }
    }

    // MARK: - AutoRaise (Focus-Follows-Mouse) Card

    private var autoRaiseCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: autoRaiseManager.isEnabled ? "cursorarrow.motionlines.click" : "cursorarrow")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(autoRaiseManager.isEnabled ? Color.aeroEmerald : .white.opacity(0.45))

                Text("AUTORAISE • FOCUS MOUSE")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        autoRaiseManager.toggleEnabled()
                    }
                } label: {
                    Text(autoRaiseManager.isEnabled ? "Active" : "Enable")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(autoRaiseManager.isEnabled ? .black : .white.opacity(0.85))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(
                            Capsule()
                                .fill(autoRaiseManager.isEnabled ? Color.aeroEmerald : Color.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
            }

            Text("Automatically activates the app and window under your pointer without clicking.")
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(2)

            // Hover Delay Presets
            VStack(alignment: .leading, spacing: 4) {
                Text("HOVER DELAY")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))

                HStack(spacing: 5) {
                    ForEach(AutoRaiseDelay.allCases) { preset in
                        let isSelected = autoRaiseManager.selectedDelay == preset
                        Button {
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                                autoRaiseManager.setDelay(preset)
                            }
                        } label: {
                            Text(preset.label)
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(
                                    isSelected
                                        ? (autoRaiseManager.isEnabled ? .black : .white)
                                        : .white.opacity(0.65)
                                )
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(
                                            isSelected
                                                ? (autoRaiseManager.isEnabled ? Color.aeroEmerald : Color.white.opacity(0.16))
                                                : Color.white.opacity(0.05)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer(minLength: 2)

            // Accessibility & Window Raise Status Row
            HStack(spacing: 6) {
                Button {
                    autoRaiseManager.toggleRaiseExactWindow()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: autoRaiseManager.shouldRaiseExactWindow ? "checkmark.square.fill" : "square")
                            .font(.system(size: 10.5))
                            .foregroundStyle(autoRaiseManager.shouldRaiseExactWindow ? Color.aeroEmerald : .white.opacity(0.45))
                        Text("Raise Window to Front")
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                if !autoRaiseManager.isAccessibilityTrusted {
                    Button {
                        autoRaiseManager.promptForAccessibilityPermission()
                    } label: {
                        Text("Grant AX")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.aeroAmber)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.aeroAmber.opacity(0.15), in: Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Focused: \(autoRaiseManager.lastActivatedAppName)")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.aeroSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            autoRaiseManager.isEnabled ? Color.aeroEmerald.opacity(0.4) : Color.white.opacity(0.08),
                            lineWidth: 1
                        )
                )
        )
    }

    // MARK: - Scrolling Capture Card

    private var scrollingCaptureCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                ScrollingCaptureIconView(size: 13, color: .aeroEmerald)

                Text("SCROLLING CAPTURE")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)

                Spacer()

                Text("Apple Vision")
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.aeroEmerald.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.aeroEmerald.opacity(0.12), in: Capsule())
            }

            Text("Select any scrollable web page, code editor, or document. Samogon scrolls, stitches via Vision, and copies the tall PNG to Clipboard & Shelf.")
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(3)

            Spacer(minLength: 2)

            // Status Readout
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.aeroEmerald)
                    .frame(width: 5, height: 5)
                Text(scrollingCaptureManager.state.statusLabel)
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }

            Button {
                scrollingCaptureManager.startScrollingCapture()
            } label: {
                HStack(spacing: 6) {
                    ScrollingCaptureIconView(size: 13, color: .black)
                    Text("Start Scrolling Capture")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.aeroEmerald)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.aeroSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}
