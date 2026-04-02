import Cocoa
import Vision

/// Stitches a sequence of overlapping screen captures into a single tall image.
///
/// Uses Apple's Vision framework (`VNTranslationalImageRegistrationRequest`) to detect
/// the vertical offset between consecutive frames. Supports both scroll-down and
/// scroll-up capture with automatic direction lock.
///
/// **Reversible capture**: scrolling in the locked direction grows the image;
/// scrolling back shrinks it (crops from the growing end). The user can "undo"
/// over-captured content by simply scrolling back.
///
/// Internally, the stitched image is rebuilt by tracking the cumulative scroll
/// position. When the position decreases, the stitched image is cropped from
/// the growing end to match.
class StitchingManager {

    // MARK: - Scroll Direction

    enum ScrollDirection {
        case unknown   // Not yet determined
        case down      // User is scrolling down (new content at bottom)
        case up        // User is scrolling up (new content at top)
    }

    // MARK: - Public State

    /// The current stitched result (updated on the main queue after each successful stitch).
    private(set) var stitchedImage: NSImage?

    /// Total pixel height of the stitched image so far (in image pixels, not points).
    private(set) var stitchedPixelHeight: CGFloat = 0

    /// The locked scroll direction (readable for UI feedback).
    private(set) var lockedDirection: ScrollDirection = .unknown

    /// Called on the main queue whenever the stitched image is updated.
    var onUpdate: ((NSImage) -> Void)?

    /// Called on the main queue when the scroll direction is locked.
    var onDirectionLocked: ((ScrollDirection) -> Void)?

    // MARK: - Internal State

    /// The previous frame's CGImage, kept for Vision comparison.
    private var previousCGImage: CGImage?

    /// Running stitched result stored as a CGImage for efficient compositing.
    private var stitchedCGImage: CGImage?

    /// The first frame's CGImage, kept as the base for the stitched image.
    private var firstFrameCGImage: CGImage?

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
    private let queue = DispatchQueue(label: "com.giyyapan.snipshot.stitching", qos: .userInitiated)

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
            logMessage("[Stitch] Failed to get CGImage from frame.")
            return
        }

        queue.async { [weak self] in
            guard let self = self else { return }

            if self.previousCGImage == nil {
                // First frame: initialise
                self.previousCGImage = cgImage
                self.firstFrameCGImage = cgImage
                self.stitchedCGImage = cgImage
                self.framePixelHeight = CGFloat(cgImage.height)
                self.framePixelWidth = CGFloat(cgImage.width)
                self.framePointSize = image.size
                self.scaleFactor = CGFloat(cgImage.height) / image.size.height
                self.stitchedPixelHeight = CGFloat(cgImage.height)
                let result = NSImage(cgImage: cgImage, size: image.size)
                DispatchQueue.main.async {
                    self.stitchedImage = result
                    self.onUpdate?(result)
                }
                return
            }

            // Compare with previous frame using Vision
            self.detectOffset(current: cgImage) { rawTy in
                self.handleOffset(rawTy, currentCGImage: cgImage)
            }
        }
    }

    /// Reset all state for a new capture session.
    func reset() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.previousCGImage = nil
            self.firstFrameCGImage = nil
            self.stitchedCGImage = nil
            self.stitchedPixelHeight = 0
            self.framePixelHeight = 0
            self.framePixelWidth = 0
            self.scaleFactor = 1.0
            self.framePointSize = .zero
            self.currentPosition = 0
            self.peakPosition = 0
            self.preLockAccumulator = 0
            self.lockedDirection = .unknown
            DispatchQueue.main.async {
                self.stitchedImage = nil
            }
        }
    }

    // MARK: - Vision Offset Detection

    private func detectOffset(current: CGImage, completion: @escaping (CGFloat) -> Void) {
        guard let previous = self.previousCGImage else {
            completion(0)
            return
        }

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: current)
        let handler = VNImageRequestHandler(cgImage: previous, options: [:])
        do {
            try handler.perform([request])
            if let observation = request.results?.first as? VNImageTranslationAlignmentObservation {
                let ty = observation.alignmentTransform.ty
                completion(ty)
            } else {
                completion(0)
            }
        } catch {
            logMessage("[Stitch] Vision error: \(error.localizedDescription)")
            completion(0)
        }
    }

    // MARK: - Offset Handling

    private func handleOffset(_ rawTy: CGFloat, currentCGImage: CGImage) {
        // rawTy is negative when user scrolls down, positive when scrolls up.
        let negatedTy = -rawTy
        let absTy = abs(negatedTy)

        guard absTy > minOffset else {
            self.previousCGImage = currentCGImage
            return
        }

        let frameDirection: ScrollDirection = negatedTy > 0 ? .down : .up

        // --- Direction locking ---
        if lockedDirection == .unknown {
            // Accumulate movement: positive = down, negative = up
            preLockAccumulator += negatedTy

            if abs(preLockAccumulator) >= lockThreshold {
                lockedDirection = preLockAccumulator > 0 ? .down : .up
                logMessage("[Stitch] Direction locked: \(lockedDirection) (accumulated: \(String(format: "%.1f", preLockAccumulator)))")
                let dir = lockedDirection
                DispatchQueue.main.async { [weak self] in
                    self?.onDirectionLocked?(dir)
                }
            } else {
                self.previousCGImage = currentCGImage
                return
            }
        }

        // --- Bidirectional position tracking ---
        let previousPosition = currentPosition

        if frameDirection == lockedDirection {
            currentPosition += absTy
        } else {
            currentPosition -= absTy
            if currentPosition < 0 { currentPosition = 0 }
        }

        // Always update previous frame
        self.previousCGImage = currentCGImage

        if currentPosition > peakPosition {
            // Scrolling forward past the peak: append new content
            let newPixels = currentPosition - peakPosition
            peakPosition = currentPosition

            logMessage("[Stitch] Append \(String(format: "%.1f", newPixels))px. Position=\(String(format: "%.1f", currentPosition)) Peak=\(String(format: "%.1f", peakPosition))")

            if lockedDirection == .down {
                appendContentAtBottom(from: currentCGImage, newPixelHeight: newPixels)
            } else {
                appendContentAtTop(from: currentCGImage, newPixelHeight: newPixels)
            }
        } else if currentPosition < previousPosition {
            // Scrolling back: crop the stitched image from the growing end
            let targetTotalHeight = framePixelHeight + currentPosition
            if targetTotalHeight < framePixelHeight {
                // Don't shrink below the first frame
                return
            }

            logMessage("[Stitch] Shrink to \(String(format: "%.1f", targetTotalHeight))px. Position=\(String(format: "%.1f", currentPosition)) Peak=\(String(format: "%.1f", peakPosition))")

            cropStitchedImage(toTotalHeight: targetTotalHeight)
            // Update peak to match current position so re-scrolling forward re-captures
            peakPosition = currentPosition
        }
        // else: currentPosition == previousPosition or between previousPosition and peakPosition
        // (scrolling forward but not past peak yet) — no change needed
    }

    // MARK: - Compositing: Append at Bottom (scroll down)

    private func appendContentAtBottom(from source: CGImage, newPixelHeight: CGFloat) {
        guard let existing = self.stitchedCGImage else { return }

        let sourceWidth = CGFloat(source.width)
        let sourceHeight = CGFloat(source.height)
        let clampedNew = min(newPixelHeight, sourceHeight)
        guard clampedNew > 0 else { return }

        // CGImage coords: y=0 is top-left. Bottom strip starts at (sourceHeight - clampedNew).
        let cropRect = CGRect(x: 0, y: sourceHeight - clampedNew, width: sourceWidth, height: clampedNew)
        guard let croppedNew = source.cropping(to: cropRect) else {
            logMessage("[Stitch] Failed to crop bottom content.")
            return
        }

        let existingWidth = CGFloat(existing.width)
        let existingHeight = CGFloat(existing.height)
        let newTotalHeight = existingHeight + clampedNew
        let canvasWidth = max(existingWidth, sourceWidth)

        guard let context = makeContext(width: Int(canvasWidth), height: Int(newTotalHeight), reference: existing) else { return }

        // CGContext coords: y=0 is bottom-left.
        // Existing at top (y = clampedNew), new content at bottom (y = 0).
        context.draw(existing, in: CGRect(x: 0, y: clampedNew, width: existingWidth, height: existingHeight))
        context.draw(croppedNew, in: CGRect(x: 0, y: 0, width: sourceWidth, height: clampedNew))

        finalizeStitch(context: context, totalHeight: newTotalHeight, canvasWidth: canvasWidth)
    }

    // MARK: - Compositing: Append at Top (scroll up)

    private func appendContentAtTop(from source: CGImage, newPixelHeight: CGFloat) {
        guard let existing = self.stitchedCGImage else { return }

        let sourceWidth = CGFloat(source.width)
        let sourceHeight = CGFloat(source.height)
        let clampedNew = min(newPixelHeight, sourceHeight)
        guard clampedNew > 0 else { return }

        // CGImage coords: y=0 is top-left. Top strip starts at y=0.
        let cropRect = CGRect(x: 0, y: 0, width: sourceWidth, height: clampedNew)
        guard let croppedNew = source.cropping(to: cropRect) else {
            logMessage("[Stitch] Failed to crop top content.")
            return
        }

        let existingWidth = CGFloat(existing.width)
        let existingHeight = CGFloat(existing.height)
        let newTotalHeight = existingHeight + clampedNew
        let canvasWidth = max(existingWidth, sourceWidth)

        guard let context = makeContext(width: Int(canvasWidth), height: Int(newTotalHeight), reference: existing) else { return }

        // CGContext coords: y=0 is bottom-left.
        // Existing at bottom (y = 0), new content at top (y = existingHeight).
        context.draw(existing, in: CGRect(x: 0, y: 0, width: existingWidth, height: existingHeight))
        context.draw(croppedNew, in: CGRect(x: 0, y: existingHeight, width: sourceWidth, height: clampedNew))

        finalizeStitch(context: context, totalHeight: newTotalHeight, canvasWidth: canvasWidth)
    }

    // MARK: - Cropping (shrink on scroll-back)

    /// Crop the stitched image to the given total pixel height.
    /// For scroll-down: crops from the bottom (removes newest content).
    /// For scroll-up: crops from the top (removes newest content).
    private func cropStitchedImage(toTotalHeight targetHeight: CGFloat) {
        guard let existing = self.stitchedCGImage else { return }

        let existingWidth = CGFloat(existing.width)
        let existingHeight = CGFloat(existing.height)

        guard targetHeight > 0 && targetHeight < existingHeight else { return }

        let cropRect: CGRect
        if lockedDirection == .down {
            // Scroll down: new content is at the bottom (CGImage y=0 is top-left).
            // Keep the top portion.
            cropRect = CGRect(x: 0, y: 0, width: existingWidth, height: targetHeight)
        } else {
            // Scroll up: new content is at the top (CGImage y=0 is top-left).
            // Keep the bottom portion.
            cropRect = CGRect(x: 0, y: existingHeight - targetHeight, width: existingWidth, height: targetHeight)
        }

        guard let cropped = existing.cropping(to: cropRect) else {
            logMessage("[Stitch] Failed to crop stitched image.")
            return
        }

        self.stitchedCGImage = cropped
        self.stitchedPixelHeight = targetHeight

        let pointWidth = existingWidth / scaleFactor
        let pointHeight = targetHeight / scaleFactor
        let result = NSImage(cgImage: cropped, size: NSSize(width: pointWidth, height: pointHeight))

        DispatchQueue.main.async {
            self.stitchedImage = result
            self.onUpdate?(result)
        }
    }

    // MARK: - Helpers

    private func makeContext(width: Int, height: Int, reference: CGImage) -> CGContext? {
        guard let colorSpace = reference.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: reference.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: reference.bitmapInfo.rawValue
        ) else {
            logMessage("[Stitch] Failed to create compositing context.")
            return nil
        }
        return context
    }

    private func finalizeStitch(context: CGContext, totalHeight: CGFloat, canvasWidth: CGFloat) {
        guard let composited = context.makeImage() else {
            logMessage("[Stitch] Failed to create composited image.")
            return
        }

        self.stitchedCGImage = composited
        self.stitchedPixelHeight = totalHeight

        let pointWidth = canvasWidth / scaleFactor
        let pointHeight = totalHeight / scaleFactor
        let result = NSImage(cgImage: composited, size: NSSize(width: pointWidth, height: pointHeight))

        DispatchQueue.main.async {
            self.stitchedImage = result
            self.onUpdate?(result)
        }
    }
}
