import CoreImage
import CoreVideo
import ImageIO
import IOSurface
import UniformTypeIdentifiers
import Vision

/// On-device subject/background matte using the same Apple Vision request as
/// SpektraFilm Studio. The returned image is only a viewer overlay; it never
/// enters the photograph's render or export pipeline.
enum BackgroundMask {
    enum Selection: String, CaseIterable, Identifiable, Equatable {
        case background, subject, foregroundObject, otherForegroundObjects, people, custom

        var id: String { rawValue }
        var title: String {
            switch self {
            case .background: "Background"
            case .subject: "Subject"
            case .foregroundObject: "Foreground Object"
            case .otherForegroundObjects: "Other Objects"
            case .people: "People"
            case .custom: "Brush"
            }
        }
        var symbol: String {
            switch self {
            case .background: "rectangle.dashed"
            case .subject: "person.crop.rectangle"
            case .foregroundObject: "viewfinder"
            case .otherForegroundObjects: "square.3.layers.3d"
            case .people: "person.2"
            case .custom: "paintbrush.pointed"
            }
        }
    }

    struct Result {
        let overlay: CGImage
        let pngBase64: String
    }

    static func result(for surface: IOSurface, selection: Selection) -> Result? {
        guard !Task.isCancelled, surface.width > 0, surface.height > 0 else { return nil }
        let handler = VNImageRequestHandler(ciImage: CIImage(ioSurface: surface), options: [:])
        let buffer: CVPixelBuffer
        let shouldInvert: Bool
        switch selection {
        case .background, .subject, .foregroundObject, .otherForegroundObjects:
            let request = VNGenerateForegroundInstanceMaskRequest()
            guard (try? handler.perform([request])) != nil,
                  let observation = request.results?.first,
                  !observation.allInstances.isEmpty else { return nil }
            let instances: IndexSet
            switch selection {
            case .background, .subject: instances = observation.allInstances
            case .foregroundObject:
                guard let first = observation.allInstances.first else { return nil }
                instances = IndexSet(integer: first)
            case .otherForegroundObjects:
                instances = IndexSet(observation.allInstances.dropFirst())
                guard !instances.isEmpty else { return nil }
            case .people: return nil
            case .custom: return nil
            }
            guard
                  let foreground = try? observation.generateScaledMaskForImage(
                    forInstances: instances, from: handler
                  ) else { return nil }
            buffer = foreground
            shouldInvert = selection == .background
        case .people:
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            guard (try? handler.perform([request])) != nil,
                  let observation = request.results?.first else { return nil }
            buffer = observation.pixelBuffer
            shouldInvert = false
        case .custom:
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        // A bounded overlay is sufficient at preview scale and avoids a second
        // full-resolution allocation for large camera frames.
        // Keep both the total allocation and either dimension bounded. Very
        // wide panoramas could previously exceed the renderer's 4096-pixel
        // mask limit, causing the saved mask to be silently ignored.
        let scale = min(1.0, min(sqrt(Double(1 << 22) / Double(width * height)),
                                 4096.0 / Double(max(width, height))))
        let outWidth = max(1, Int((Double(width) * scale).rounded()))
        let outHeight = max(1, Int((Double(height) * scale).rounded()))
        var rgba = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
        var background = [UInt8](repeating: 0, count: outWidth * outHeight)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        for y in 0..<outHeight {
            if Task.isCancelled { return nil }
            let sy = min(height - 1, Int((Double(y) + 0.5) * Double(height) / Double(outHeight)))
            for x in 0..<outWidth {
                let sx = min(width - 1, Int((Double(x) + 0.5) * Double(width) / Double(outWidth)))
                let backgroundCoverage: UInt8
                switch format {
                case kCVPixelFormatType_OneComponent32Float:
                    let row = base.advanced(by: sy * rowBytes).assumingMemoryBound(to: Float.self)
                    let coverage = min(max(row[sx], 0), 1)
                    backgroundCoverage = UInt8(((shouldInvert ? 1 - coverage : coverage) * 255).rounded())
                case kCVPixelFormatType_OneComponent16Half:
                    let row = base.advanced(by: sy * rowBytes).assumingMemoryBound(to: UInt16.self)
                    let coverage = min(max(halfToFloat(row[sx]), 0), 1)
                    backgroundCoverage = UInt8(((shouldInvert ? 1 - coverage : coverage) * 255).rounded())
                default:
                    let row = base.advanced(by: sy * rowBytes).assumingMemoryBound(to: UInt8.self)
                    backgroundCoverage = shouldInvert ? 255 - row[sx] : row[sx]
                }
                let maskIndex = y * outWidth + x
                background[maskIndex] = backgroundCoverage
                let alpha = UInt8((Double(backgroundCoverage) * 150 / 255).rounded())
                let i = (y * outWidth + x) * 4
                let a = Double(alpha) / 255
                rgba[i] = UInt8((232 * a).rounded()); rgba[i + 1] = UInt8((157 * a).rounded())
                rgba[i + 2] = UInt8((35 * a).rounded()); rgba[i + 3] = alpha
            }
        }
        guard let overlayProvider = CGDataProvider(data: Data(rgba) as CFData),
              let overlay = CGImage(width: outWidth, height: outHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: outWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: overlayProvider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let maskProvider = CGDataProvider(data: Data(background) as CFData),
              let mask = CGImage(width: outWidth, height: outHeight, bitsPerComponent: 8, bitsPerPixel: 8,
                                 bytesPerRow: outWidth, space: CGColorSpaceCreateDeviceGray(),
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                 provider: maskProvider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, mask, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Result(overlay: overlay, pngBase64: (encoded as Data).base64EncodedString())
    }

    static func overlay(fromPNGBase64 encoded: String) -> CGImage? {
        guard let data = Data(base64Encoded: encoded),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let mask = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = mask.width, height = mask.height
        var gray = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &gray, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0 ..< gray.count {
            let alpha = UInt8((Double(gray[i]) * 150.0 / 255.0).rounded())
            let j = i * 4, a = Double(alpha) / 255
            rgba[j] = UInt8((232 * a).rounded()); rgba[j + 1] = UInt8((157 * a).rounded())
            rgba[j + 2] = UInt8((35 * a).rounded()); rgba[j + 3] = alpha
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Expands the saved preview selection to the full-resolution develop used
    /// by LaMa, while preserving soft Vision-mask edges.
    static func mask(fromPNGBase64 encoded: String, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let data = Data(base64Encoded: encoded),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let input = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let created = pixels.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(input, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
        return created
    }

    private static func halfToFloat(_ half: UInt16) -> Float {
        let sign = UInt32(half & 0x8000) << 16
        var exponent = UInt32((half >> 10) & 0x1f)
        var significand = UInt32(half & 0x03ff)
        let bits: UInt32
        if exponent == 0 {
            if significand == 0 { bits = sign }
            else {
                exponent = 1
                while significand & 0x0400 == 0 { significand <<= 1; exponent -= 1 }
                significand &= 0x03ff
                bits = sign | ((exponent + 112) << 23) | (significand << 13)
            }
        } else if exponent == 0x1f {
            bits = sign | 0x7f80_0000 | (significand << 13)
        } else {
            bits = sign | ((exponent + 112) << 23) | (significand << 13)
        }
        return Float(bitPattern: bits)
    }
}
