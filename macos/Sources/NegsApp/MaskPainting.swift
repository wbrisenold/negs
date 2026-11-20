import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Editable grayscale selection used by the mask brush. Coordinates are
/// normalized from the upper-left of the uncropped photograph.
final class MaskPainter {
    let width: Int
    let height: Int
    private var pixels: [UInt8]
    private var previous: CGPoint?

    init?(width: Int, height: Int, pngBase64: String? = nil) {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 16_777_216 else { return nil }
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height)
        guard let pngBase64, let data = Data(base64Encoded: pngBase64),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .high
            // Keep the decoded row order identical to BackgroundMask's
            // Vision output and PNG overlay path. Flipping here made an
            // edited brush mask appear on the opposite vertical side.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func stroke(to point: CGPoint, diameter: Double, subtract: Bool) {
        let point = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        let current = CGPoint(x: point.x * CGFloat(width), y: point.y * CGFloat(height))
        let radius = max(1.0, CGFloat(diameter) * 0.5)
        let start = previous ?? current
        let dx = current.x - start.x, dy = current.y - start.y
        let distance = hypot(dx, dy)
        let steps = max(1, Int(ceil(distance / max(radius * 0.35, 1))))
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            dab(at: CGPoint(x: start.x + dx * t, y: start.y + dy * t), radius: radius, subtract: subtract)
        }
        previous = current
    }

    func endStroke() { previous = nil }

    /// Swaps selected and unselected pixels without changing the source photo.
    func invert() {
        for index in pixels.indices { pixels[index] = 255 - pixels[index] }
    }

    func makeResult() -> BackgroundMask.Result? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let mask = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                 bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, mask, nil)
        guard CGImageDestinationFinalize(destination), let overlay = overlayImage() else { return nil }
        return BackgroundMask.Result(overlay: overlay, pngBase64: (encoded as Data).base64EncodedString())
    }

    func overlayImage() -> CGImage? {
        let scale = min(1.0, min(1280.0 / Double(max(width, height)), sqrt(1_000_000.0 / Double(width * height))))
        let outWidth = max(1, Int((Double(width) * scale).rounded()))
        let outHeight = max(1, Int((Double(height) * scale).rounded()))
        var rgba = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
        for y in 0..<outHeight {
            let sy = min(height - 1, Int((Double(y) + 0.5) * Double(height) / Double(outHeight)))
            for x in 0..<outWidth {
                let sx = min(width - 1, Int((Double(x) + 0.5) * Double(width) / Double(outWidth)))
                let alpha = UInt8((Double(pixels[sy * width + sx]) * 150 / 255).rounded())
                let a = Double(alpha) / 255
                let i = (y * outWidth + x) * 4
                rgba[i] = UInt8((232 * a).rounded()); rgba[i + 1] = UInt8((157 * a).rounded())
                rgba[i + 2] = UInt8((35 * a).rounded()); rgba[i + 3] = alpha
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: outWidth, height: outHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: outWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func dab(at center: CGPoint, radius: CGFloat, subtract: Bool) {
        let feather = max(1, radius * 0.22)
        let innerRadius = max(0, radius - feather)
        let minX = max(0, Int(floor(center.x - radius)))
        let maxX = min(width - 1, Int(ceil(center.x + radius)))
        let minY = max(0, Int(floor(center.y - radius)))
        let maxY = min(height - 1, Int(ceil(center.y + radius)))
        guard minX <= maxX, minY <= maxY else { return }
        for y in minY...maxY {
            for x in minX...maxX {
                let distance = hypot(CGFloat(x) + 0.5 - center.x, CGFloat(y) + 0.5 - center.y)
                guard distance < radius else { continue }
                let coverage = distance <= innerRadius ? 1 : (radius - distance) / feather
                let index = y * width + x
                if subtract {
                    pixels[index] = UInt8((Double(pixels[index]) * Double(1 - coverage)).rounded())
                } else {
                    pixels[index] = max(pixels[index], UInt8((coverage * 255).rounded()))
                }
            }
        }
    }
}
