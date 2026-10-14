import Cocoa
import os

/// Crash-safe font factory. Always obtain UI fonts through `SafeFont` instead of
/// calling `NSFont.systemFont(...)` / `NSFont.monospacedSystemFont(...)` directly.
///
/// Why: those AppKit factories are annotated nonnull, but on macOS 26.5 (25F84)
/// `monospacedSystemFont(ofSize: 11, weight: .medium)` was observed returning nil
/// inside long-running Snipshot processes (0.10.0 crashes on 2026-10-14 and
/// 2026-10-15, both in `OverlayView.drawDimensionLabel`). Swift trusts the
/// annotation, so the nil silently lands in an attributes dictionary. CoreText
/// sees no usable font, copies the dictionary to add a default one, and aborts
/// with `-[__NSPlaceholderDictionary initWithObjects:forKeys:count:]: attempt to
/// insert nil object from objects[0]` (`TAttributes::ApplyFont + 320`).
///
/// `SafeFont`:
/// 1. checks the AppKit result for nil at runtime (bit-level check that the
///    optimizer cannot fold away based on the nonnull annotation);
/// 2. caches the first good font per (design, size, weight), so hot draw paths
///    stop hitting the factory after the first success;
/// 3. falls back through other font sources when the factory fails, without
///    caching the fallback (the real font is retried next time), and logs each
///    failing (design, size, weight) once to the unified log.
enum SafeFont {
    private enum Design: Hashable { case system, monospaced }

    private struct Key: Hashable {
        let design: Design
        let size: CGFloat
        /// nil = AppKit's default weight (`systemFont(ofSize:)` without a weight).
        let weight: CGFloat?
    }

    private static let lock = NSLock()
    private static var cache: [Key: NSFont] = [:]
    private static var loggedFailures: Set<Key> = []
    private static let logger = Logger(subsystem: "com.giyyapan.snipshot", category: "font")

    /// Equivalent of `NSFont.systemFont(ofSize:)` / `NSFont.systemFont(ofSize:weight:)`.
    static func system(ofSize size: CGFloat, weight: NSFont.Weight? = nil) -> NSFont {
        font(for: Key(design: .system, size: size, weight: weight?.rawValue)) {
            if let weight { return NSFont.systemFont(ofSize: size, weight: weight) }
            return NSFont.systemFont(ofSize: size)
        }
    }

    /// Equivalent of `NSFont.monospacedSystemFont(ofSize:weight:)`.
    static func monospacedSystem(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        font(for: Key(design: .monospaced, size: size, weight: weight.rawValue)) {
            NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
    }

    /// Converts the result of an AppKit API that is declared nonnull into an
    /// honest optional. Kept out of line so the check survives optimization.
    @inline(never)
    static func nonNil(_ font: NSFont) -> NSFont? {
        unsafeBitCast(font, to: Optional<NSFont>.self)
    }

    // MARK: - Private

    private static func font(for key: Key, make: () -> NSFont) -> NSFont {
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        if let made = nonNil(make()) {
            lock.lock()
            cache[key] = made
            lock.unlock()
            return made
        }

        lock.lock()
        let shouldLog = loggedFailures.insert(key).inserted
        lock.unlock()
        if shouldLog {
            logger.fault("AppKit returned nil for \(String(describing: key.design), privacy: .public) font size=\(Double(key.size), privacy: .public) weight=\(key.weight.map { Double($0) } ?? -1, privacy: .public); using fallback")
        }
        return fallback(for: key)
    }

    private static func fallback(for key: Key) -> NSFont {
        let size = key.size
        var candidates: [() -> NSFont?] = []
        if key.design == .monospaced {
            candidates.append { NSFont.userFixedPitchFont(ofSize: size) }
            candidates.append { NSFont(name: "Menlo-Regular", size: size) }
        }
        candidates.append { nonNil(NSFont.systemFont(ofSize: size)) }
        candidates.append { NSFont.userFont(ofSize: size) }
        candidates.append { NSFont(name: "HelveticaNeue", size: size) }
        candidates.append { NSFont(name: "Helvetica", size: size) }
        for candidate in candidates {
            if let font = candidate() { return font }
        }
        // Font services are completely unavailable; nothing better is left.
        return NSFont.labelFont(ofSize: size)
    }
}
