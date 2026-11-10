import AppKit

/// One-shot, on-device gray-world estimate from the local source preview.
/// It is a starting point for RAW WB, not a camera-neutral measurement.
enum WhiteBalanceEstimator {
    static func estimate(_ image: CGImage) -> (temperature: Double, tint: Double)? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let step = max(1, max(bitmap.pixelsWide, bitmap.pixelsHigh) / 256)
        var red = 0.0, green = 0.0, blue = 0.0, count = 0.0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let (r, g, b) = (color.redComponent, color.greenComponent, color.blueComponent)
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                guard luma > 0.08, luma < 0.9, max(r, g, b) < 0.98 else { continue }
                red += r; green += g; blue += b; count += 1
            }
        }
        guard count >= 16 else { return nil }
        let (r, g, b) = (red / count, green / count, blue / count)
        guard r > 0.001, g > 0.001, b > 0.001 else { return nil }
        let temperature = min(25000, max(1667, 6504 + (b - r) * 8500))
        let tint = min(4, max(0.01, 1 - (g - (r + b) / 2) * 2.5))
        return (temperature, tint)
    }
}
