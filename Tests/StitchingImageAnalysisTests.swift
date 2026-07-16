import Cocoa

private struct AnalysisTestFailure: Error {
    let message: String
}

@main
private enum StitchingImageAnalysisTests {
    static func main() throws {
        let previous = try makeFrame(startRow: 0, width: 160, height: 200)
        let current = try makeFrame(startRow: 20, width: 160, height: 200)
        guard let quality = ImageOverlapAnalyzer.measure(
            previous: previous,
            current: current,
            candidateVerticalDelta: 20
        ) else {
            throw AnalysisTestFailure(message: "overlap analysis returned nil")
        }

        try expect(abs(quality.refinedVerticalDelta - 20) <= 1, "refined delta was \(quality.refinedVerticalDelta)")
        try expect(quality.overlapRatio > 0.85, "unexpected overlap: \(quality.overlapRatio)")
        try expect(quality.residual < 0.01, "synthetic exact overlap residual was \(quality.residual)")

        let flatPrevious = try makeFlatFrame(value: 90, width: 160, height: 200)
        let flatCurrent = try makeFlatFrame(value: 90, width: 160, height: 200)
        guard let ambiguous = ImageOverlapAnalyzer.measure(
            previous: flatPrevious,
            current: flatCurrent,
            candidateVerticalDelta: 18
        ) else {
            throw AnalysisTestFailure(message: "flat overlap analysis returned nil")
        }
        let validation = StitchMatchValidator().validate(StitchMatchMeasurement(
            horizontalOffset: 0,
            verticalDelta: ambiguous.refinedVerticalDelta,
            overlapRatio: ambiguous.overlapRatio,
            residual: ambiguous.residual,
            secondBestResidual: ambiguous.secondBestResidual,
            previousSize: (160, 200),
            currentSize: (160, 200)
        ))
        try expect(validation == .rejected(.ambiguousMatch), "flat repeated content was not rejected: \(validation)")

        print("StitchingImageAnalysisTests: 2 tests passed")
    }

    private static func makeFrame(startRow: Int, width: Int, height: Int) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let globalY = startRow + y
            for x in 0..<width {
                var value = UInt64(globalY * width + x) &+ 0x9e3779b97f4a7c15
                value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
                value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
                value ^= value >> 31
                pixels[y * width + x] = UInt8(truncatingIfNeeded: value)
            }
        }
        return try makeImage(pixels: pixels, width: width, height: height)
    }

    private static func makeFlatFrame(value: UInt8, width: Int, height: Int) throws -> CGImage {
        try makeImage(pixels: [UInt8](repeating: value, count: width * height), width: width, height: height)
    }

    private static func makeImage(pixels: [UInt8], width: Int, height: Int) throws -> CGImage {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw AnalysisTestFailure(message: "failed to create test CGImage")
        }
        return image
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw AnalysisTestFailure(message: message) }
    }
}
