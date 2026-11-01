import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Observation
@preconcurrency import ScreenCaptureKit
import Vision

/// State of the native Scrolling Capture engine.
public enum ScrollingCaptureState: Equatable, Sendable {
    case idle
    case selectingRegion
    case capturing(frameCount: Int)
    case stitching
    case completed(String)
    case failed(String)

    public var statusLabel: String {
        switch self {
        case .idle:
            return "Ready • Copies to Clipboard & Shelf"
        case .selectingRegion:
            return "Select scrollable area on screen..."
        case .capturing(let count):
            return "Scrolling & capturing (\(count) frames)... Esc to finish"
        case .stitching:
            return "Stitching frames via Apple Vision..."
        case .completed(let summary):
            return summary
        case .failed(let reason):
            return reason
        }
    }
}

/// Native, Zero-Dependency Scrolling Screenshot Engine using `ScreenCaptureKit`, `CGEvent` scroll synthesis, and `Vision` (`VNTranslationalImageRegistrationRequest`).
@MainActor
@Observable
public final class ScrollingCaptureManager {
    public private(set) var state: ScrollingCaptureState = .idle
    public var onCaptureCompleted: ((URL) -> Void)?
    public var onRequestCollapseNotch: (() -> Void)?
    public var onRequestExpandNotch: (() -> Void)?

    private var selectionPanel: ScrollingRegionOverlayPanel?
    private var stopCaptureFlag: Bool = false
    private var escapeKeyMonitor: Any?

    public init() {}

    // MARK: - Public Entry Point

    public func startScrollingCapture() {
        guard state != .selectingRegion else { return }
        if case .capturing = state {
            stopCaptureFlag = true
            return
        }

        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        if !AXIsProcessTrusted() {
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }

        AeroHaptics.playHoverClick()
        onRequestCollapseNotch?()

        // Allow 180ms for the Notch to collapse cleanly before presenting the selection crosshair
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.presentRegionSelectorOverlay()
        }
    }

    public func stopActiveCapture() {
        stopCaptureFlag = true
    }

    // MARK: - Step 1: Interactive Screen Region Selection

    private func presentRegionSelectorOverlay() {
        let mouseLoc = NSEvent.mouseLocation
        guard let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLoc) }) ?? NSScreen.main else {
            state = .failed("No active display found")
            return
        }

        state = .selectingRegion
        stopCaptureFlag = false

        let panel = ScrollingRegionOverlayPanel(screen: targetScreen)
        panel.onRegionSelected = { [weak self] selectedAppKitRect in
            guard let self else { return }
            self.dismissSelectionOverlay()
            Task { @MainActor in
                await self.executeScrollingCaptureLoop(appKitRect: selectedAppKitRect, screen: targetScreen)
            }
        }
        panel.onCancelled = { [weak self] in
            guard let self else { return }
            self.dismissSelectionOverlay()
            self.state = .idle
        }

        self.selectionPanel = panel
        panel.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.push()
    }

    private func dismissSelectionOverlay() {
        NSCursor.pop()
        selectionPanel?.orderOut(nil)
        selectionPanel = nil
    }

    // MARK: - Step 2: Automated Scroll + ScreenCaptureKit + Vision Stitching

    private func executeScrollingCaptureLoop(appKitRect: CGRect, screen: NSScreen) async {
        state = .capturing(frameCount: 1)
        stopCaptureFlag = false

        let displayID = screen.aeroDisplayID
        let scale = screen.backingScaleFactor

        // Convert AppKit bottom-left screen rect into display-local top-left coordinates for ScreenCaptureKit
        let localX = appKitRect.minX - screen.frame.minX
        let localTopY = screen.frame.maxY - appKitRect.maxY
        let localCropRect = CGRect(
            x: max(0, localX),
            y: max(0, localTopY),
            width: appKitRect.width,
            height: appKitRect.height
        )

        // Convert AppKit center point into CoreGraphics global top-left coordinates for CGEvent mouse/scroll targeting
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cgCenterPoint = CGPoint(
            x: appKitRect.midX,
            y: primaryScreenHeight - appKitRect.midY
        )

        // Reactivate the target application underneath the selected region and hover the pointer over it
        let targetPID = Self.findTopmostApplicationPID(at: cgCenterPoint)
        if targetPID > 0, let targetApp = NSRunningApplication(processIdentifier: targetPID) {
            targetApp.activate()
        }

        CGWarpMouseCursorPosition(cgCenterPoint)
        if let moveEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: cgCenterPoint,
            mouseButton: .left
        ) {
            moveEvent.post(tap: .cghidEventTap)
        }

        try? await Task.sleep(nanoseconds: 110_000_000)

        installStopKeyMonitors()
        defer { removeStopKeyMonitors() }

        var capturedFrames: [CGImage] = []
        var verticalPixelShifts: [Int] = []

        guard let firstFrame = await captureScreenRegion(
            displayID: displayID,
            cropRectInPoints: localCropRect,
            scale: scale
        ) else {
            state = .failed("Screen Recording permission required in System Settings")
            onRequestExpandNotch?()
            return
        }

        capturedFrames.append(firstFrame)

        let maxFrames = 28
        // Scroll ~42% of the selected box height per step for fast, snappy capture while keeping ~58% overlap for Vision registration
        let scrollPointsPerStep = Int32(max(135, min(320, appKitRect.height * 0.42)))

        for frameIndex in 2...maxFrames {
            if stopCaptureFlag { break }

            // Post fast synthetic downward scroll wheel burst
            postSmoothScrollWheel(
                at: cgCenterPoint,
                totalDeltaYPoints: -scrollPointsPerStep,
                targetPID: targetPID
            )

            // Wait 135ms for scroll rendering to settle
            try? await Task.sleep(nanoseconds: 135_000_000)
            if stopCaptureFlag { break }

            guard let nextFrame = await captureScreenRegion(
                displayID: displayID,
                cropRectInPoints: localCropRect,
                scale: scale
            ) else {
                break
            }

            let previousFrame = capturedFrames[capturedFrames.count - 1]
            var shiftPixels = Self.computeVerticalPixelShift(from: previousFrame, to: nextFrame)

            // If first scroll step yielded < 8px shift, try one stronger scroll burst before concluding bottom reached
            if shiftPixels < 8 && !stopCaptureFlag {
                postSmoothScrollWheel(
                    at: cgCenterPoint,
                    totalDeltaYPoints: -(scrollPointsPerStep * 2),
                    targetPID: targetPID
                )
                try? await Task.sleep(nanoseconds: 150_000_000)
                if let retryFrame = await captureScreenRegion(
                    displayID: displayID,
                    cropRectInPoints: localCropRect,
                    scale: scale
                ) {
                    shiftPixels = Self.computeVerticalPixelShift(from: previousFrame, to: retryFrame)
                    if shiftPixels >= 8 {
                        capturedFrames.append(retryFrame)
                        verticalPixelShifts.append(shiftPixels)
                        state = .capturing(frameCount: frameIndex)
                        continue
                    }
                }
                break
            }

            capturedFrames.append(nextFrame)
            verticalPixelShifts.append(shiftPixels)
            state = .capturing(frameCount: frameIndex)
        }

        state = .stitching
        guard let stitchedCGImage = Self.stitchCapturedFrames(
            frames: capturedFrames,
            shifts: verticalPixelShifts
        ) else {
            state = .failed("Failed to stitch captured frames")
            return
        }

        saveAndPublishStitchedImage(stitchedCGImage, frameCount: capturedFrames.count)
    }

    private static func findTopmostApplicationPID(at cgPoint: CGPoint) -> pid_t {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return 0
        }
        for win in windowList {
            guard let layer = win[kCGWindowLayer as String] as? Int, layer == 0,
                  let ownerPID = win[kCGWindowOwnerPID as String] as? pid_t, ownerPID != selfPID,
                  let boundsDict = win[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"], let y = boundsDict["Y"],
                  let w = boundsDict["Width"], let h = boundsDict["Height"] else {
                continue
            }
            let rect = CGRect(x: x, y: y, width: w, height: h)
            if rect.contains(cgPoint) {
                return ownerPID
            }
        }
        return 0
    }

    // MARK: - ScreenCaptureKit + Native CLI Fallback Single-Region Capture

    private func captureScreenRegion(
        displayID: CGDirectDisplayID,
        cropRectInPoints: CGRect,
        scale: CGFloat
    ) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let scDisplay = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first {
                let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = max(1, Int((CGFloat(scDisplay.width) * scale).rounded()))
                config.height = max(1, Int((CGFloat(scDisplay.height) * scale).rounded()))
                config.showsCursor = false
                config.capturesAudio = false

                let fullImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: config
                )

                let scaleX = CGFloat(fullImage.width) / max(1, CGFloat(scDisplay.width))
                let scaleY = CGFloat(fullImage.height) / max(1, CGFloat(scDisplay.height))
                let pixelRect = CGRect(
                    x: (cropRectInPoints.minX * scaleX).rounded(),
                    y: (cropRectInPoints.minY * scaleY).rounded(),
                    width: max(1, (cropRectInPoints.width * scaleX).rounded()),
                    height: max(1, (cropRectInPoints.height * scaleY).rounded())
                )
                if let cropped = fullImage.cropping(to: pixelRect) {
                    return cropped
                }
            }
        } catch {}

        // Fallback: /usr/sbin/screencapture -x -R x,y,w,h
        let tmpPath = NSTemporaryDirectory() + "aero_cap_\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let rectArg = "\(Int(cropRectInPoints.minX.rounded())),\(Int(cropRectInPoints.minY.rounded())),\(Int(cropRectInPoints.width.rounded())),\(Int(cropRectInPoints.height.rounded()))"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-x", "-R", rectArg, tmpPath]
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0,
               let dataProvider = CGDataProvider(filename: tmpPath),
               let cgImg = CGImage(
                   pngDataProviderSource: dataProvider,
                   decode: nil,
                   shouldInterpolate: true,
                   intent: .defaultIntent
               ) {
                return cgImg
            }
        } catch {}

        return nil
    }

    // MARK: - Smooth Synthetic Scroll Wheel Generator (Dual Line + Pixel Deltas)

    private func postSmoothScrollWheel(at cgPoint: CGPoint, totalDeltaYPoints: Int32, targetPID: pid_t) {
        let subSteps: Int32 = 6
        let stepDelta = min(-16, totalDeltaYPoints / subSteps)
        let isAXTrusted = AXIsProcessTrusted()

        for stepIdx in 0..<subSteps {
            if let scrollEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 1,
                wheel1: -2,
                wheel2: 0,
                wheel3: 0
            ) {
                scrollEvent.location = cgPoint
                scrollEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                scrollEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(stepDelta))
                // Set scroll phase: 1 = began, 2 = changed, 4 = ended
                let phase: Int64 = (stepIdx == 0) ? 1 : (stepIdx == subSteps - 1 ? 4 : 2)
                scrollEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)

                if isAXTrusted {
                    scrollEvent.post(tap: .cghidEventTap)
                } else if targetPID > 0 {
                    scrollEvent.postToPid(targetPID)
                } else {
                    scrollEvent.post(tap: .cghidEventTap)
                }
            }
            usleep(7_000)
        }
    }

    // MARK: - Apple Vision Translational Image Registration + 1D Row-Profile SAD Fallback

    nonisolated private static func computeVerticalPixelShift(from prev: CGImage, to next: CGImage) -> Int {
        let width = prev.width
        let height = prev.height
        guard width > 40, height > 80, next.width == width, next.height == height else { return 0 }

        // Ignore top 10% and bottom 10% to avoid sticky navigation headers or fixed footers skewing registration
        let insetY = Int(Double(height) * 0.10)
        let interiorHeight = height - (insetY * 2)
        let interiorRect = CGRect(x: 0, y: insetY, width: width, height: interiorHeight)

        guard let prevInterior = prev.cropping(to: interiorRect),
              let nextInterior = next.cropping(to: interiorRect) else {
            return 0
        }

        // 1. Primary: Apple Vision VNTranslationalImageRegistrationRequest
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: prevInterior, options: [:])
        let handler = VNImageRequestHandler(cgImage: nextInterior, options: [:])
        if (try? handler.perform([request])) != nil,
           let observation = request.results?.first as? VNImageTranslationAlignmentObservation {
            let dy = abs(Int(observation.alignmentTransform.ty.rounded()))
            if dy >= 8 && dy <= Int(Double(interiorHeight) * 0.85) {
                return dy
            }
        }

        // 2. Fallback: 1D Horizontal Row-Luminance SAD Matcher (for dark editors / uniform backgrounds)
        return computeRowProfileShiftFallback(prev: prevInterior, next: nextInterior)
    }

    nonisolated private static func computeRowProfileShiftFallback(prev: CGImage, next: CGImage) -> Int {
        let w = min(prev.width, 160)
        let h = prev.height
        guard h > 60 else { return 0 }

        func rowSignature(for img: CGImage) -> [Double] {
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            guard let ctx = CGContext(
                data: &bytes,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return [] }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

            var profile = [Double](repeating: 0, count: h)
            for y in 0..<h {
                var sum = 0
                let rowOffset = y * w * 4
                for x in 0..<w {
                    let p = rowOffset + x * 4
                    sum += Int(bytes[p]) + Int(bytes[p + 1]) * 2 + Int(bytes[p + 2])
                }
                profile[y] = Double(sum) / Double(w * 4)
            }
            return profile
        }

        let profPrev = rowSignature(for: prev)
        let profNext = rowSignature(for: next)
        guard profPrev.count == h, profNext.count == h else { return 0 }

        // Check if images are nearly identical (zero scroll occurred)
        var zeroShiftDiff = 0.0
        for y in 0..<h {
            zeroShiftDiff += abs(profPrev[y] - profNext[y])
        }
        if (zeroShiftDiff / Double(h)) < 0.35 {
            return 0
        }

        let minShift = 10
        let maxShift = min(Int(Double(h) * 0.65), h - 24)
        guard maxShift > minShift else { return 0 }

        var bestShift = 0
        var bestScore = Double.greatestFiniteMagnitude

        for dy in minShift...maxShift {
            let overlap = h - dy
            var diff = 0.0
            for y in 0..<overlap {
                // Content scrolled up by dy rows: prev[y + dy] matches next[y]
                diff += abs(profPrev[y + dy] - profNext[y])
            }
            let normalized = diff / Double(overlap)
            if normalized < bestScore {
                bestScore = normalized
                bestShift = dy
            }
        }

        return bestScore < 12.0 ? bestShift : 0
    }

    // MARK: - Vertical Strip Compositor

    nonisolated private static func stitchCapturedFrames(frames: [CGImage], shifts: [Int]) -> CGImage? {
        guard let first = frames.first else { return nil }
        if frames.count == 1 || shifts.isEmpty {
            return first
        }

        let width = first.width
        let frameHeight = first.height
        let totalShift = shifts.reduce(0, +)
        let totalHeight = frameHeight + totalShift

        guard let colorSpace = first.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: totalHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return first
        }

        // Ignore bottom 8% sticky footer when appending intermediate slices
        let bottomFooterMargin = Int(Double(frameHeight) * 0.08)

        // In CoreGraphics bitmap context, y = 0 is at the bottom and y = totalHeight is at the top.
        var currentTopY = totalHeight

        // Draw the full first frame at the very top of the canvas
        let firstDestRect = CGRect(x: 0, y: currentTopY - frameHeight, width: width, height: frameHeight)
        context.draw(first, in: firstDestRect)
        currentTopY -= frameHeight

        // For each subsequent frame, crop the newly revealed strip of height `shift` above the bottom margin
        for (index, shift) in shifts.enumerated() {
            let frame = frames[index + 1]
            let isLastFrame = (index == shifts.count - 1)
            let margin = isLastFrame ? 0 : bottomFooterMargin

            // In CGImage coordinates (top-left origin), the newly scrolled-in band near the bottom is:
            let cropY = max(0, frameHeight - margin - shift)
            let cropHeight = min(shift + margin, frameHeight - cropY)
            let cropRect = CGRect(x: 0, y: cropY, width: width, height: cropHeight)

            if let strip = frame.cropping(to: cropRect) {
                let destY = currentTopY + margin - cropHeight
                let destRect = CGRect(x: 0, y: destY, width: width, height: cropHeight)
                context.draw(strip, in: destRect)
            }
            currentTopY -= shift
        }

        return context.makeImage()
    }

    // MARK: - Save to Clipboard & Shelf

    private func saveAndPublishStitchedImage(_ cgImage: CGImage, frameCount: Int) {
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

        // 1. Copy directly to Clipboard (NSPasteboard)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])

        // 2. Save PNG to ~/Pictures/Samogon Captures/ and add to File Shelf
        let picturesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Samogon Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: picturesDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let fileName = "Samogon-Scroll-\(formatter.string(from: Date())).png"
        let fileURL = picturesDir.appendingPathComponent(fileName)

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            try? pngData.write(to: fileURL, options: .atomic)
            onCaptureCompleted?(fileURL)
        }

        AeroHaptics.playHoverClick()
        state = .completed("Saved (\(frameCount) frames • \(cgImage.width)×\(cgImage.height)px) → Clipboard & Shelf")
        onRequestExpandNotch?()
    }

    // MARK: - Escape / Right-Click Stop Monitor During Active Capture

    private func installStopKeyMonitors() {
        escapeKeyMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .rightMouseDown]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if event.type == .keyDown && event.keyCode == 53 {
                    self.stopCaptureFlag = true
                } else if event.type == .rightMouseDown {
                    self.stopCaptureFlag = true
                }
            }
        }
    }

    private func removeStopKeyMonitors() {
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }
    }
}

// MARK: - Interactive Crosshair Region Selection Overlay Window

@MainActor
private final class ScrollingRegionOverlayPanel: NSPanel {
    var onRegionSelected: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let selectionView = RegionDragSelectionNSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        selectionView.onSelectionCompleted = { [weak self] localRect in
            guard let self else { return }
            let globalRect = CGRect(
                x: screen.frame.minX + localRect.minX,
                y: screen.frame.minY + localRect.minY,
                width: localRect.width,
                height: localRect.height
            )
            self.onRegionSelected?(globalRect)
        }
        selectionView.onCancel = { [weak self] in
            self?.onCancelled?()
        }
        self.contentView = selectionView
    }

    override var canBecomeKey: Bool { true }
}

@MainActor
private final class RegionDragSelectionNSView: NSView {
    var onSelectionCompleted: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = startPoint, let end = currentPoint else {
            onCancel?()
            return
        }
        let rect = normalizedRect(from: start, to: end)
        if rect.width >= 60 && rect.height >= 60 {
            onSelectionCompleted?(rect)
        } else {
            onCancel?()
        }
    }

    private func normalizedRect(from p1: NSPoint, to p2: NSPoint) -> NSRect {
        NSRect(
            x: min(p1.x, p2.x),
            y: min(p1.y, p2.y),
            width: abs(p2.x - p1.x),
            height: abs(p2.y - p1.y)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.32).setFill()
        dirtyRect.fill()

        // Draw top instruction banner
        let bannerText = "SAMOGON SCROLLING CAPTURE • Drag to select scrollable area (Esc to cancel, Right-Click/Esc to finish scrolling)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = bannerText.size(withAttributes: attrs)
        let bannerRect = NSRect(
            x: (bounds.width - textSize.width - 28) / 2,
            y: bounds.height - 90,
            width: textSize.width + 28,
            height: 34
        )
        let bannerPath = NSBezierPath(roundedRect: bannerRect, xRadius: 17, yRadius: 17)
        NSColor.black.withAlphaComponent(0.82).setFill()
        bannerPath.fill()
        bannerText.draw(
            at: NSPoint(x: bannerRect.minX + 14, y: bannerRect.minY + 8),
            withAttributes: attrs
        )

        if let start = startPoint, let end = currentPoint {
            let sel = normalizedRect(from: start, to: end)
            NSColor.clear.setFill()
            sel.fill(using: .copy)

            let borderPath = NSBezierPath(roundedRect: sel, xRadius: 6, yRadius: 6)
            borderPath.lineWidth = 2.0
            NSColor(srgbRed: 0.22, green: 0.88, blue: 0.54, alpha: 0.95).setStroke()
            borderPath.stroke()
        }
    }
}
