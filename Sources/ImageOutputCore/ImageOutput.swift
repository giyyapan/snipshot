import Cocoa
import ImageIO
import UniformTypeIdentifiers

struct EncodedImageRepresentations {
    let png: Data
    let tiff: Data
    let pixelWidth: Int
    let pixelHeight: Int
}

enum ImageOutputError: LocalizedError {
    case missingCGImage
    case destinationCreationFailed(UTType)
    case encodingFailed(UTType)
    case pasteboardItemCreationFailed
    case pasteboardWriteFailed

    var errorDescription: String? {
        switch self {
        case .missingCGImage:
            return "The image has no bitmap representation."
        case .destinationCreationFailed(let type):
            return "Could not create an encoder for \(type.identifier)."
        case .encodingFailed(let type):
            return "Could not encode the image as \(type.identifier)."
        case .pasteboardItemCreationFailed:
            return "The encoded image representations could not be added to a pasteboard item."
        case .pasteboardWriteFailed:
            return "The image could not be written to the pasteboard."
        }
    }
}

/// Produces deterministic image data for user-facing copy and save operations.
/// PNG and TIFF are encoded from the same CGImage so their pixel dimensions,
/// color space, and alpha channel do not diverge between pasteboard consumers.
enum ImageOutput {
    static func representations(for image: NSImage) throws -> EncodedImageRepresentations {
        let cgImage = try sourceCGImage(for: image)
        return EncodedImageRepresentations(
            png: try encode(cgImage, as: .png),
            tiff: try encode(cgImage, as: .tiff),
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height
        )
    }

    static func pngData(for image: NSImage) throws -> Data {
        try encode(sourceCGImage(for: image), as: .png)
    }

    static func pasteboardItem(for image: NSImage) throws -> NSPasteboardItem {
        let encoded = try representations(for: image)
        let item = NSPasteboardItem()

        // Declaration order matters: cross-platform consumers should prefer PNG,
        // while TIFF remains available for macOS apps that expect it.
        guard item.setData(encoded.png, forType: .png),
              item.setData(encoded.tiff, forType: .tiff) else {
            throw ImageOutputError.pasteboardItemCreationFailed
        }
        return item
    }

    static func writeToPasteboard(_ image: NSImage, pasteboard: NSPasteboard = .general) throws {
        // Encode before clearing so a failed conversion does not destroy the
        // user's existing clipboard contents.
        let item = try pasteboardItem(for: image)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw ImageOutputError.pasteboardWriteFailed
        }
    }

    static func writePNG(_ image: NSImage, to url: URL) throws {
        try pngData(for: image).write(to: url, options: .atomic)
    }

    private static func sourceCGImage(for image: NSImage) throws -> CGImage {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImageOutputError.missingCGImage
        }
        return cgImage
    }

    private static func encode(_ cgImage: CGImage, as type: UTType) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageOutputError.destinationCreationFailed(type)
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageOutputError.encodingFailed(type)
        }
        return data as Data
    }
}
