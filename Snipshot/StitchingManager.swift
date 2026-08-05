import Cocoa
import Vision

/// Stitches overlapping captures after validating that each registration is geometrically
/// plausible, visually consistent, and unambiguous. Rejected frames never become references.
final class StitchingManager {
    typealias ScrollDirection = StitchScrollDirection

    private(set) var stitchedImage: NSImage?
    private(set) var stitchedPixelHeight: CGFloat = 0
    private(set) var lockedDirection: ScrollDirection = .unknown

    var onUpdate: ((NSImage) -> Void)?
    var onDirectionLocked: ((ScrollDirection) -> Void)?
    var onFrameRejected: ((StitchMatchRejection) -> Void)?

    private var trustedCGImage: CGImage?
    private var stitchedCGImage: CGImage?
    private var framePixelHeight = 0
    private var scaleFactor: CGFloat = 1
    private var positionTracker = StitchPositionTracker()
    private let validator = StitchMatchValidator()
    private let workQueue = StitchSerialDrainQueue(
        label: "com.giyyapan.snipshot.stitching",
        qos: .userInitiated
    )

    private let pendingLock = NSLock()
    private var pendingFrameCount = 0
    private let maximumPendingFrames = 6
    private var frameIndex = 0

    /// The height (in pixels) of each captured frame.
    private var framePixelHeight: CGFloat = 0

    /// The width (in pixels) of each captured frame.
    private var framePixelWidth: CGFloat = 0

    /// Scale factor (pixels / points) derived from the first frame.
    private var scaleFactor: CGFloat = 1.0

    /// The point size of each frame (for NSImage creation).
    private var framePointSize: NSSize = .zero

    /// Current scroll position in pixels (positive = in locked direction).
    /// This tracks the actual position, going up when scrolling forward and
    /// down when scrolling back.
    private var currentPosition: CGFloat = 0

    /// The highest position ever reached. The stitched image covers from 0
    /// to `peakPosition` in the locked direction.
    private var peakPosition: CGFloat = 0

    /// Serial queue for stitching work to avoid blocking the main thread.
    private let queue = DispatchQueue(label: "com.meeseek.snipshot-bug.stitching", qos: .userInitiated)

    /// Minimum vertical offset (in pixels) to consider as a real scroll.
    private let minOffset: CGFloat = 2.0

    /// Threshold for locking direction: accumulated movement in one consistent
    /// direction must exceed this before we commit.
    private let lockThreshold: CGFloat = 5.0

    /// Accumulated movement before direction is locked (tracks net direction).
    private var preLockAccumulator: CGFloat = 0

    // MARK: - Public API

    /// Add a new captured frame.
    func addFrame(_ image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            logMessage("[Stitch] Reject reason=image_conversion_failed")
            return false
        }

        pendingLock.lock()
        guard pendingFrameCount < maximumPendingFrames else {
            let pending = pendingFrameCount
            pendingLock.unlock()
            logMessage("[Stitch] Drop reason=backpressure pending=\(pending)")
            return false
        }
        pendingFrameCount += 1
        pendingLock.unlock()

        workQueue.enqueue { [weak self] in
            guard let self else { return }
            defer {
                self.pendingLock.lock()
                self.pendingFrameCount -= 1
                self.pendingLock.unlock()
            }
            self.processFrame(cgImage, pointSize: image.size)
        }
        return true
    }

    /// Calls completion only after every frame accepted before this call has been processed.
    func finish(completion: @escaping (NSImage?) -> Void) {
        workQueue.drain { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let result = self.makeResultImage()
            DispatchQueue.main.async { completion(result) }
        }
    }

    func reset() {
        workQueue.drain { [weak self] in
            guard let self else { return }
            self.trustedCGImage = nil
            self.stitchedCGImage = nil
            self.framePixelHeight = 0
            self.scaleFactor = 1
            self.positionTracker = StitchPositionTracker()
            self.frameIndex = 0
            DispatchQueue.main.async {
                self.stitchedImage = nil
                self.stitchedPixelHeight = 0
                self.lockedDirection = .unknown
            }
        }
    }

    private func processFrame(_ current: CGImage, pointSize: NSSize) {
        frameIndex += 1

        guard let previous = trustedCGImage else {
            trustedCGImage = current
            stitchedCGImage = current
            framePixelHeight = current.height
            scaleFactor = pointSize.height > 0 ? CGFloat(current.height) / pointSize.height : 1
            publishCurrentImage()
            logMessage("[Stitch] frame=\(frameIndex) initialized size=\(current.width)x\(current.height) scale=\(format(scaleFactor))")
            return
        }

        guard previous.width == current.width, previous.height == current.height else {
            reject(
                .frameGeometryChanged,
                details: "frame=\(frameIndex) previous=\(previous.width)x\(previous.height) current=\(current.width)x\(current.height)"
            )
            return
        }

        guard let transform = detectOffset(previous: previous, current: current) else { return }
        let visionDelta = -Double(transform.ty)
        guard let quality = ImageOverlapAnalyzer.measure(
            previous: previous,
            current: current,
            candidateVerticalDelta: visionDelta
        ) else {
            reject(.highResidual, details: "frame=\(frameIndex) reason=analysis_failed")
            return
        }

        let measurement = StitchMatchMeasurement(
            horizontalOffset: Double(transform.tx),
            verticalDelta: quality.refinedVerticalDelta,
            overlapRatio: quality.overlapRatio,
            residual: quality.residual,
            secondBestResidual: quality.secondBestResidual,
            previousSize: (previous.width, previous.height),
            currentSize: (current.width, current.height)
        )

        let secondBestText = quality.secondBestResidual.map { format($0) } ?? "n/a"
        let diagnostic = "frame=\(frameIndex) tx=\(format(transform.tx)) visionDelta=\(format(visionDelta)) refinedDelta=\(format(quality.refinedVerticalDelta)) overlap=\(format(quality.overlapRatio)) residual=\(format(quality.residual)) second=\(secondBestText)"

        switch validator.validate(measurement) {
        case .rejected(let reason):
            reject(reason, details: diagnostic)
            // Keep `previous` as the trusted reference so one bad frame cannot
            // poison every subsequent registration.
            return

        case .ignoredSmallMovement:
            trustedCGImage = current
            logMessage("[Stitch] Ignore reason=small_movement \(diagnostic)")
            return

        case .accepted(let pixelDelta):
            trustedCGImage = current
            let update = positionTracker.consume(pixelDelta: pixelDelta)
            logMessage("[Stitch] Accept delta=\(pixelDelta) position=\(positionTracker.position) peak=\(positionTracker.peakPosition) pending=\(positionTracker.pendingDelta) \(diagnostic)")
            apply(update, currentCGImage: current)
        }
    }

    private func detectOffset(previous: CGImage, current: CGImage) -> CGAffineTransform? {
        guard let previousROI = ImageOverlapAnalyzer.stableRegion(of: previous),
              let currentROI = ImageOverlapAnalyzer.stableRegion(of: current) else {
            reject(.frameGeometryChanged, details: "frame=\(frameIndex) reason=invalid_stable_roi")
            return nil
        }

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: currentROI)
        let handler = VNImageRequestHandler(cgImage: previousROI, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
                reject(.highResidual, details: "frame=\(frameIndex) reason=no_vision_observation")
                return nil
            }
            return observation.alignmentTransform
        } catch {
            logMessage("[Stitch] Vision error frame=\(frameIndex) error=\(error.localizedDescription)")
            reject(.highResidual, details: "frame=\(frameIndex) reason=vision_error")
            return nil
        }
    }

    private func apply(_ update: StitchPositionUpdate, currentCGImage: CGImage) {
        if let direction = update.lockedDirection {
            DispatchQueue.main.async { [weak self] in
                self?.lockedDirection = direction
                self?.onDirectionLocked?(direction)
            }
        }

        switch update.action {
        case .none:
            return
        case .append(let pixelHeight):
            if positionTracker.direction == .down {
                appendContentAtBottom(from: currentCGImage, newPixelHeight: pixelHeight)
            } else {
                appendContentAtTop(from: currentCGImage, newPixelHeight: pixelHeight)
            }
        case .crop(let position):
            cropStitchedImage(toTotalHeight: framePixelHeight + position)
        }
    }

    private func appendContentAtBottom(from source: CGImage, newPixelHeight: Int) {
        guard let existing = stitchedCGImage else { return }
        let clampedNew = min(newPixelHeight, source.height)
        guard clampedNew > 0,
              let croppedNew = source.cropping(to: CGRect(
                x: 0,
                y: source.height - clampedNew,
                width: source.width,
                height: clampedNew
              )),
              let context = makeContext(
                width: max(existing.width, source.width),
                height: existing.height + clampedNew,
                reference: existing
              ) else { return }

        context.draw(existing, in: CGRect(x: 0, y: clampedNew, width: existing.width, height: existing.height))
        context.draw(croppedNew, in: CGRect(x: 0, y: 0, width: source.width, height: clampedNew))
        finalizeStitch(context: context)
    }

    private func appendContentAtTop(from source: CGImage, newPixelHeight: Int) {
        guard let existing = stitchedCGImage else { return }
        let clampedNew = min(newPixelHeight, source.height)
        guard clampedNew > 0,
              let croppedNew = source.cropping(to: CGRect(x: 0, y: 0, width: source.width, height: clampedNew)),
              let context = makeContext(
                width: max(existing.width, source.width),
                height: existing.height + clampedNew,
                reference: existing
              ) else { return }

        context.draw(existing, in: CGRect(x: 0, y: 0, width: existing.width, height: existing.height))
        context.draw(croppedNew, in: CGRect(x: 0, y: existing.height, width: source.width, height: clampedNew))
        finalizeStitch(context: context)
    }

    private func cropStitchedImage(toTotalHeight targetHeight: Int) {
        guard let existing = stitchedCGImage,
              targetHeight >= framePixelHeight,
              targetHeight < existing.height else { return }

        let y = positionTracker.direction == .down ? 0 : existing.height - targetHeight
        guard let cropped = existing.cropping(to: CGRect(
            x: 0,
            y: y,
            width: existing.width,
            height: targetHeight
        )) else { return }

        stitchedCGImage = cropped
        publishCurrentImage()
    }

    private func makeContext(width: Int, height: Int, reference: CGImage) -> CGContext? {
        guard let colorSpace = reference.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: reference.bitsPerComponent,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: reference.bitmapInfo.rawValue
              ) else {
            logMessage("[Stitch] Failed to create compositing context size=\(width)x\(height)")
            return nil
        }
        return context
    }

    private func finalizeStitch(context: CGContext) {
        guard let composited = context.makeImage() else {
            logMessage("[Stitch] Failed to create composited image")
            return
        }
        stitchedCGImage = composited
        publishCurrentImage()
    }

    private func makeResultImage() -> NSImage? {
        guard let image = stitchedCGImage else { return nil }
        return NSImage(
            cgImage: image,
            size: NSSize(width: CGFloat(image.width) / scaleFactor, height: CGFloat(image.height) / scaleFactor)
        )
    }

    private func publishCurrentImage() {
        guard let result = makeResultImage(), let cgImage = stitchedCGImage else { return }
        let pixelHeight = CGFloat(cgImage.height)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stitchedImage = result
            self.stitchedPixelHeight = pixelHeight
            self.onUpdate?(result)
        }
    }

    private func reject(_ reason: StitchMatchRejection, details: String) {
        logMessage("[Stitch] Reject reason=\(reason.rawValue) \(details)")
        DispatchQueue.main.async { [weak self] in
            self?.onFrameRejected?(reason)
        }
    }

    private func format<T: BinaryFloatingPoint>(_ value: T) -> String {
        String(format: "%.4f", Double(value))
    }
}

enum ImageOverlapAnalyzer {
    struct Quality {
        let refinedVerticalDelta: Double
        let overlapRatio: Double
        let residual: Double
        let secondBestResidual: Double?
    }

    private struct GrayFrame {
        let width: Int
        let height: Int
        let pixels: [UInt8]
        let verticalScale: Double
    }

    /// Removes edges and the top/bottom bands most likely to contain scrollbars,
    /// sticky headers, or sticky footers before both Vision and residual analysis.
    static func stableRegion(of image: CGImage) -> CGImage? {
        let horizontalInset = max(1, Int((Double(image.width) * 0.08).rounded()))
        let verticalInset = max(1, Int((Double(image.height) * 0.12).rounded()))
        let rect = CGRect(
            x: horizontalInset,
            y: verticalInset,
            width: image.width - horizontalInset * 2,
            height: image.height - verticalInset * 2
        )
        guard rect.width >= 32, rect.height >= 32 else { return nil }
        return image.cropping(to: rect)
    }

    static func measure(
        previous: CGImage,
        current: CGImage,
        candidateVerticalDelta: Double
    ) -> Quality? {
        guard let previousGray = makeGrayFrame(previous),
              let currentGray = makeGrayFrame(current),
              previousGray.width == currentGray.width,
              previousGray.height == currentGray.height else { return nil }

        let baseDelta = Int((candidateVerticalDelta * previousGray.verticalScale).rounded())
        let candidateDeltas = Array(Set((-4...4).map { baseDelta + $0 })).sorted()
        let scored = candidateDeltas.compactMap { delta -> (delta: Int, score: Double)? in
            guard let score = residual(previous: previousGray, current: currentGray, verticalDelta: delta) else {
                return nil
            }
            return (delta, score)
        }.sorted { lhs, rhs in
            if lhs.score == rhs.score { return abs(lhs.delta - baseDelta) < abs(rhs.delta - baseDelta) }
            return lhs.score < rhs.score
        }

        guard let best = scored.first else { return nil }
        let secondBest = scored.first { abs($0.delta - best.delta) >= 3 }
        // Preserve Vision's subpixel estimate when the local search agrees with
        // its rounded sample. Only apply the measured neighborhood correction.
        let refinedDelta = candidateVerticalDelta
            + Double(best.delta - baseDelta) / previousGray.verticalScale
        let overlapRatio = max(0, 1 - abs(refinedDelta) / Double(previous.height))
        return Quality(
            refinedVerticalDelta: refinedDelta,
            overlapRatio: overlapRatio,
            residual: best.score,
            secondBestResidual: secondBest?.score
        )
    }

    private static func makeGrayFrame(_ image: CGImage) -> GrayFrame? {
        guard let roi = stableRegion(of: image) else { return nil }
        let width = min(192, roi.width)
        let height = min(256, roi.height)
        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let created = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            context.interpolationQuality = .medium
            // Bitmap row zero is y=0. Flip the draw so row indices follow the
            // same top-to-bottom convention used by CGImage cropping and offset math.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(roi, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard created else { return nil }
        return GrayFrame(
            width: width,
            height: height,
            pixels: pixels,
            verticalScale: Double(height) / Double(roi.height)
        )
    }

    private static func residual(
        previous: GrayFrame,
        current: GrayFrame,
        verticalDelta: Int
    ) -> Double? {
        let overlapHeight = previous.height - abs(verticalDelta)
        guard overlapHeight >= max(16, previous.height / 4) else { return nil }

        // The bitmap context stores row zero at its lower edge. After the draw
        // transform above, a positive scroll delta aligns previous row 0 with a
        // later row in the current buffer.
        let previousStart = verticalDelta < 0 ? -verticalDelta : 0
        let currentStart = verticalDelta > 0 ? verticalDelta : 0
        var totalDifference: UInt64 = 0
        var sampleCount: UInt64 = 0

        // Skip two columns on each edge and sample every other pixel for predictable cost.
        for row in stride(from: 0, to: overlapHeight, by: 2) {
            let previousRow = (previousStart + row) * previous.width
            let currentRow = (currentStart + row) * current.width
            for column in stride(from: 2, to: previous.width - 2, by: 2) {
                let lhs = Int(previous.pixels[previousRow + column])
                let rhs = Int(current.pixels[currentRow + column])
                totalDifference += UInt64(abs(lhs - rhs))
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else { return nil }
        return Double(totalDifference) / Double(sampleCount) / 255
    }
}
