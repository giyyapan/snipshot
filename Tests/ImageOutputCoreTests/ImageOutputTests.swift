import AppKit
import ImageIO
import XCTest
@testable import ImageOutputCore

final class ImageOutputTests: XCTestCase {
    func testRepresentationsPreservePixelDimensionsAndAlpha() throws {
        let image = try makeImage(pixelWidth: 4, pixelHeight: 2, pointSize: NSSize(width: 2, height: 1), alpha: 128)

        let encoded = try ImageOutput.representations(for: image)

        XCTAssertEqual(encoded.pixelWidth, 4)
        XCTAssertEqual(encoded.pixelHeight, 2)
        XCTAssertTrue(encoded.png.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

        for data in [encoded.png, encoded.tiff] {
            let decoded = try decode(data)
            XCTAssertEqual(decoded.width, 4)
            XCTAssertEqual(decoded.height, 2)
            XCTAssertTrue(decoded.alphaInfo == .premultipliedLast || decoded.alphaInfo == .premultipliedFirst || decoded.alphaInfo == .last || decoded.alphaInfo == .first)
            let pixels = try rgbaPixels(in: decoded)
            XCTAssertEqual(stride(from: 1, to: pixels.count, by: 4).map { pixels[$0] }, Array(repeating: 128, count: 8))
            XCTAssertEqual(stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }, Array(repeating: 128, count: 8))
        }
    }

    func testPasteboardAdvertisesPNGFirstAndTIFFAsFallback() throws {
        let image = try makeImage(pixelWidth: 2, pixelHeight: 2, pointSize: NSSize(width: 2, height: 2), alpha: 255)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.giyyapan.snipshot.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        try ImageOutput.writeToPasteboard(image, pasteboard: pasteboard)

        let types = pasteboard.types ?? []
        XCTAssertEqual(types.first, .png)
        XCTAssertLessThan(try XCTUnwrap(types.firstIndex(of: .png)), try XCTUnwrap(types.firstIndex(of: .tiff)))
        XCTAssertNotNil(pasteboard.data(forType: .png))
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
        XCTAssertFalse(types.contains { $0.rawValue == "public.heic" || $0.rawValue == "public.heif" })
    }

    func testTransparentPNGReadFromPasteboardRemainsTransparentWhenReencoded() throws {
        let original = try makeImage(pixelWidth: 2, pixelHeight: 3, pointSize: NSSize(width: 2, height: 3), alpha: 64)
        let sourcePasteboard = NSPasteboard(name: NSPasteboard.Name("com.giyyapan.snipshot.tests.source.\(UUID().uuidString)"))
        defer { sourcePasteboard.releaseGlobally() }
        let sourceItem = NSPasteboardItem()
        XCTAssertTrue(sourceItem.setData(try ImageOutput.pngData(for: original), forType: .png))
        sourcePasteboard.clearContents()
        XCTAssertTrue(sourcePasteboard.writeObjects([sourceItem]))
        let pinnedImage = try XCTUnwrap(NSImage(pasteboard: sourcePasteboard))

        let reencoded = try ImageOutput.representations(for: pinnedImage)

        for data in [reencoded.png, reencoded.tiff] {
            let pixels = try rgbaPixels(in: decode(data))
            XCTAssertEqual(stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }, Array(repeating: 64, count: 6))
        }
    }

    func testWritePNGProducesPNGBytesAtRequestedURL() throws {
        let image = try makeImage(pixelWidth: 3, pixelHeight: 5, pointSize: NSSize(width: 3, height: 5), alpha: 255)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnipshotImageOutput-\(UUID().uuidString)")
            .appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: url) }

        try ImageOutput.writePNG(image, to: url)

        let data = try Data(contentsOf: url)
        XCTAssertTrue(data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        let decoded = try decode(data)
        XCTAssertEqual(decoded.width, 3)
        XCTAssertEqual(decoded.height, 5)
    }

    private func makeImage(pixelWidth: Int, pixelHeight: Int, pointSize: NSSize, alpha: UInt8) throws -> NSImage {
        let premultipliedGreen = alpha
        var pixels = [UInt8]()
        pixels.reserveCapacity(pixelWidth * pixelHeight * 4)
        for _ in 0..<(pixelWidth * pixelHeight) {
            pixels.append(contentsOf: [0, premultipliedGreen, 0, alpha])
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: pixelWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw TestError.imageCreationFailed
        }
        return NSImage(cgImage: cgImage, size: pointSize)
    }

    private func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw TestError.imageDecodeFailed
        }
        return image
    }

    private func rgbaPixels(in image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestError.contextCreationFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    private enum TestError: Error {
        case imageCreationFailed
        case imageDecodeFailed
        case contextCreationFailed
    }
}
