import SwiftUI

/// Interactive SwiftUI card controlling native `IOKit.pwr_mgt` sleep assertions.
public struct CaffeinateControlView: View {
    @Bindable var powerManager: PowerManager

    public init(powerManager: PowerManager) {
        self.powerManager = powerManager
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row: Title + Active Toggle Switch
            HStack(spacing: 6) {
                Image(systemName: powerManager.isActive ? "bolt.shield.fill" : "bolt.slash.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(powerManager.isActive ? Color.aeroAmber : .white.opacity(0.45))

                Text("CAFFEINATE")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 4)

                if powerManager.isActive {
                    Text(String(format: "0x%04X", powerManager.activeAssertionID))
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.aeroAmber.opacity(0.75))
                        .lineLimit(1)
                }

                Button {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.8)) {
                        powerManager.toggle()
                    }
                } label: {
                    Text(powerManager.isActive ? powerManager.statusBadgeText : "Enable")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(powerManager.isActive ? .black : .white.opacity(0.85))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(powerManager.isActive ? Color.aeroAmber : Color.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
            }

            // Mode Selector (Display + System vs System Only)
            HStack(spacing: 5) {
                ForEach(CaffeinateMode.allCases) { mode in
                    let isSelected = powerManager.selectedMode == mode
                    Button {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.8)) {
                            powerManager.setMode(mode)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: mode.iconName)
                                .font(.system(size: 9, weight: .semibold))
                            Text(mode.rawValue)
                                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                        }
                        .foregroundStyle(isSelected ? .white : .white.opacity(0.48))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isSelected ? Color.white.opacity(0.13) : Color.white.opacity(0.04))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            // Duration Pills (∞, 15m, 30m, 1h, 2h)
            HStack(spacing: 4) {
                ForEach(CaffeinateDuration.allCases) { duration in
                    let isSelected = powerManager.isActive && powerManager.selectedDuration == duration
                    Button {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.8)) {
                            powerManager.selectAndActivate(duration: duration)
                        }
                    } label: {
                        Text(duration.rawValue)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(isSelected ? .black : .white.opacity(0.75))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4.5)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(
                                        isSelected
                                            ? Color.aeroAmber
                                            : (powerManager.selectedDuration == duration
                                                ? Color.white.opacity(0.12)
                                                : Color.white.opacity(0.05))
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.aeroSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            powerManager.isActive ? Color.aeroAmber.opacity(0.45) : Color.white.opacity(0.08),
                            lineWidth: 1
                        )
                )
        )
    }
}
