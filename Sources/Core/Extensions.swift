import AppKit
import CoreGraphics
import SwiftUI

// MARK: - Screen & Notch Geometry

public struct NotchGeometry: Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    /// Physical or virtual notch width at the top edge of the screen.
    public let notchWidth: CGFloat
    /// Physical or virtual notch height (matches menu bar / safeAreaInsets.top).
    public let notchHeight: CGFloat
    /// Exact rect of the hardware notch in global screen coordinates.
    public let notchScreenRect: CGRect
    /// Full frame of the target screen in global coordinates.
    public let screenFrame: CGRect
    /// True when running on a display with a physical camera housing cutout.
    public let hasPhysicalNotch: Bool

    /// Balanced fallback dimensions for external monitors (e.g. Xiaomi A27Ui 4K).
    public static let fallbackWidth: CGFloat = 178.0
    public static let fallbackHeight: CGFloat = 32.0
}

extension NSScreen {
    /// Unique CoreGraphics `CGDirectDisplayID` for multi-monitor coordination.
    public var aeroDisplayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Returns the preferred primary screen if needed.
    public static var aeroTargetScreen: NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    /// Computes exact hardware notch geometry using macOS `safeAreaInsets` and auxiliary menu bar areas.
    public var notchGeometry: NotchGeometry {
        let topInset = safeAreaInsets.top
        let hasNotch = topInset > 0

        let calculatedWidth: CGFloat
        if hasNotch,
           let leftArea = auxiliaryTopLeftArea,
           let rightArea = auxiliaryTopRightArea {
            // Physical cutout on MacBook Air M3 is ~179pt; add 8pt for top ear fillets so the body
            // completely covers the physical notch with a balanced silhouette (~187pt).
            let rawCutoutWidth = frame.width - leftArea.width - rightArea.width + 8.0
            calculatedWidth = max(rawCutoutWidth, NotchGeometry.fallbackWidth)
        } else {
            calculatedWidth = NotchGeometry.fallbackWidth
        }

        // Keep exact height untouched
        let calculatedHeight: CGFloat = hasNotch ? max(topInset, NotchGeometry.fallbackHeight) : NotchGeometry.fallbackHeight
        let originX = frame.minX + (frame.width - calculatedWidth) / 2.0
        let originY = frame.maxY - calculatedHeight

        let notchRect = CGRect(
            x: originX.rounded(.toNearestOrEven),
            y: originY.rounded(.toNearestOrEven),
            width: calculatedWidth.rounded(.toNearestOrEven),
            height: calculatedHeight.rounded(.toNearestOrEven)
        )

        return NotchGeometry(
            displayID: aeroDisplayID,
            notchWidth: notchRect.width,
            notchHeight: notchRect.height,
            notchScreenRect: notchRect,
            screenFrame: frame,
            hasPhysicalNotch: hasNotch
        )
    }
}

// MARK: - Native Force Touch Trackpad Haptic Feedback

@MainActor
public enum AeroHaptics {
    /// Triggers the native macOS Force Touch trackpad tactile actuation click on hover/actions.
    public static func playHoverClick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    public static func playAlignmentTap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

// MARK: - Native Hardware Notch Shape (with Top Ear Fillets)

/// Draws the signature macOS Notch silhouette with outward-flaring top ears and smooth bottom corners.
public struct AeroNotchShape: Shape {
    public var topCornerRadius: CGFloat
    public var bottomCornerRadius: CGFloat

    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    public init(topCornerRadius: CGFloat = 9, bottomCornerRadius: CGFloat = 18) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    public func path(in rect: CGRect) -> Path {
        let topR = min(topCornerRadius, rect.width / 4, rect.height / 2)
        let botR = min(bottomCornerRadius, (rect.width - topR * 2) / 2, rect.height - topR)

        var path = Path()

        // Start at top-left outer ear edge (y = 0 in SwiftUI coordinates)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Top-left outward fillet curving down into the left vertical wall
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topR, y: rect.minY + topR),
            control: CGPoint(x: rect.minX + topR, y: rect.minY)
        )

        // Left vertical wall down to bottom-left corner start
        path.addLine(to: CGPoint(x: rect.minX + topR, y: rect.maxY - botR))

        // Bottom-left inward rounded corner
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topR + botR, y: rect.maxY),
            control: CGPoint(x: rect.minX + topR, y: rect.maxY)
        )

        // Bottom horizontal edge
        path.addLine(to: CGPoint(x: rect.maxX - topR - botR, y: rect.maxY))

        // Bottom-right inward rounded corner
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topR, y: rect.maxY - botR),
            control: CGPoint(x: rect.maxX - topR, y: rect.maxY)
        )

        // Right vertical wall up to top-right ear fillet
        path.addLine(to: CGPoint(x: rect.maxX - topR, y: rect.minY + topR))

        // Top-right outward fillet curving out to top-right edge
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topR, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}

// MARK: - Formatting & Visual Helpers

extension Int64 {
    /// Formats a byte count into a concise human-readable string without allocation churn.
    public var aeroFormattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

extension Color {
    /// True 100% #000000 hardware black matching the physical MacBook camera housing.
    public static let aeroPitchBlack = Color.black
    /// Ultra-dark pitch black surface for internal dashboard cards.
    public static let aeroSurface = Color(red: 0.018, green: 0.018, blue: 0.022)
    public static let aeroBorder = Color.white.opacity(0.055)
    public static let aeroAmber = Color(red: 1.0, green: 0.72, blue: 0.18)
    public static let aeroEmerald = Color(red: 0.22, green: 0.88, blue: 0.54)
}

// MARK: - Custom Vector Icon for Scrolling Capture (Viewfinder + Scroll Down Arrow)

/// Draws a screenshot viewfinder frame with a prominent downward scrolling arrow inside.
public struct ScrollingCaptureIconView: View {
    public var size: CGFloat
    public var color: Color

    public init(size: CGFloat = 12, color: Color = .aeroEmerald) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let strokeWidth = max(1.3, min(w, h) * 0.125)
            let inset = strokeWidth * 0.65
            let arm = min(w, h) * 0.27
            let r = min(w, h) * 0.12

            var corners = Path()

            // Top-Left Corner Bracket
            corners.move(to: CGPoint(x: inset, y: inset + arm))
            corners.addLine(to: CGPoint(x: inset, y: inset + r))
            corners.addQuadCurve(to: CGPoint(x: inset + r, y: inset), control: CGPoint(x: inset, y: inset))
            corners.addLine(to: CGPoint(x: inset + arm, y: inset))

            // Top-Right Corner Bracket
            corners.move(to: CGPoint(x: w - inset - arm, y: inset))
            corners.addLine(to: CGPoint(x: w - inset - r, y: inset))
            corners.addQuadCurve(to: CGPoint(x: w - inset, y: inset + r), control: CGPoint(x: w - inset, y: inset))
            corners.addLine(to: CGPoint(x: w - inset, y: inset + arm))

            // Bottom-Left Corner Bracket
            corners.move(to: CGPoint(x: inset, y: h - inset - arm))
            corners.addLine(to: CGPoint(x: inset, y: h - inset - r))
            corners.addQuadCurve(to: CGPoint(x: inset + r, y: h - inset), control: CGPoint(x: inset, y: h - inset))
            corners.addLine(to: CGPoint(x: inset + arm, y: h - inset))

            // Bottom-Right Corner Bracket
            corners.move(to: CGPoint(x: w - inset - arm, y: h - inset))
            corners.addLine(to: CGPoint(x: w - inset - r, y: h - inset))
            corners.addQuadCurve(to: CGPoint(x: w - inset, y: h - inset - r), control: CGPoint(x: w - inset, y: h - inset))
            corners.addLine(to: CGPoint(x: w - inset, y: h - inset - arm))

            let style = StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
            context.stroke(corners, with: .color(color), style: style)

            // Center Downward Scrolling Arrow
            let midX = w * 0.5
            let arrowTopY = h * 0.23
            let arrowTipY = h * 0.77
            let wingDX = w * 0.21
            let wingY = h * 0.56

            var arrow = Path()
            arrow.move(to: CGPoint(x: midX, y: arrowTopY))
            arrow.addLine(to: CGPoint(x: midX, y: arrowTipY))
            arrow.move(to: CGPoint(x: midX - wingDX, y: wingY))
            arrow.addLine(to: CGPoint(x: midX, y: arrowTipY))
            arrow.addLine(to: CGPoint(x: midX + wingDX, y: wingY))

            context.stroke(arrow, with: .color(color), style: style)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Custom Vector Brand Emblem for Samogon (Faceted Spirit Drop & Flame)

/// Draws the signature Samogon faceted distilled spirit drop/flame in emerald green and amber gold.
public struct SamogonLogoMarkView: View {
    public var size: CGFloat

    public init(size: CGFloat = 13) {
        self.size = size
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height

            // Outer dual-peak distilled spirit flame / drop contour
            var drop = Path()
            drop.move(to: CGPoint(x: w * 0.48, y: h * 0.04))
            drop.addQuadCurve(
                to: CGPoint(x: w * 0.14, y: h * 0.64),
                control: CGPoint(x: w * 0.16, y: h * 0.36)
            )
            drop.addQuadCurve(
                to: CGPoint(x: w * 0.50, y: h * 0.96),
                control: CGPoint(x: w * 0.14, y: h * 0.92)
            )
            drop.addQuadCurve(
                to: CGPoint(x: w * 0.86, y: h * 0.64),
                control: CGPoint(x: w * 0.86, y: h * 0.92)
            )
            drop.addQuadCurve(
                to: CGPoint(x: w * 0.72, y: h * 0.28),
                control: CGPoint(x: w * 0.86, y: h * 0.46)
            )
            drop.addLine(to: CGPoint(x: w * 0.62, y: h * 0.42))
            drop.addLine(to: CGPoint(x: w * 0.48, y: h * 0.04))
            drop.closeSubpath()

            let gradient = Gradient(colors: [Color.aeroEmerald, Color.aeroAmber])
            context.fill(
                drop,
                with: .linearGradient(
                    gradient,
                    startPoint: CGPoint(x: w * 0.15, y: h * 0.5),
                    endPoint: CGPoint(x: w * 0.85, y: h * 0.5)
                )
            )

            // Precision internal Swiss-knife geometric facets
            var facets = Path()
            facets.move(to: CGPoint(x: w * 0.48, y: h * 0.06))
            facets.addLine(to: CGPoint(x: w * 0.50, y: h * 0.94))
            facets.move(to: CGPoint(x: w * 0.22, y: h * 0.56))
            facets.addLine(to: CGPoint(x: w * 0.50, y: h * 0.74))
            facets.addLine(to: CGPoint(x: w * 0.78, y: h * 0.56))
            facets.move(to: CGPoint(x: w * 0.28, y: h * 0.78))
            facets.addLine(to: CGPoint(x: w * 0.50, y: h * 0.38))
            facets.addLine(to: CGPoint(x: w * 0.72, y: h * 0.78))

            context.stroke(
                facets,
                with: .color(.black.opacity(0.45)),
                style: StrokeStyle(lineWidth: max(0.8, w * 0.065), lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: size, height: size)
    }
}
