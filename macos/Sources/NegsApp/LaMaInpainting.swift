import CoreGraphics
import CoreImage
import CoreML
import CryptoKit
import Foundation
import ImageIO
import Vision

/// Local LaMa inpainting, with the converted Core ML package fetched only when
/// the user first removes an object. The package is pinned and its large weight
/// file is verified before Core ML is allowed to compile it.
enum LaMaInpainting {
    static let modelRevision = "5ed76e3799ab4cad31381750d29880c267477e18"
    static let weightSHA256 = "d0541f6044a94cd4982bfdac074fc1ccfe11d8f1f590c299d6b5071b501fc184"
    private static let weightBytes: Int64 = 215_544_960
    private static let side = 800
    private static let modelLock = NSLock()
    private static var cachedModel: MLModel?
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    struct Patch {
        let image: CGImage
        /// Normalized top-left bounds in the full developed frame.
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    enum Failure: LocalizedError {
        case invalidImage, emptyMask, modelUnavailable, outputMissing, encodeFailed

        var errorDescription: String? {
            switch self {
            case .invalidImage: "Could not read the developed image for object removal."
            case .emptyMask: "The selected mask is empty. Create or refine a mask first."
            case .modelUnavailable: "The LaMa inpainting model could not be installed. Check the connection and available disk space, then try again."
            case .outputMissing: "LaMa did not return a repaired image."
            case .encodeFailed: "The repaired patch could not be saved in the edit."
            }
        }
    }

    static func inpaint(image: CGImage, mask: CGImage) async throws -> Patch {
        let model = try await loadModel()
        return try await Task.detached(priority: .userInitiated) {
            try run(model: model, image: image, mask: mask)
        }.value
    }

    static func pngBase64(_ image: CGImage) throws -> String {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw Failure.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodeFailed }
        return (data as Data).base64EncodedString()
    }

    private static func loadModel() async throws -> MLModel {
        if let model = modelLock.withLock({ cachedModel }) { return model }
        let package = try await ensureModelPackage()
        let model = try await Task.detached(priority: .utility) {
            let compiled = package.deletingLastPathComponent().appendingPathComponent("LaMa.mlmodelc", isDirectory: true)
            if !FileManager.default.fileExists(atPath: compiled.path) {
                let temporary = try MLModel.compileModel(at: package)
                try? FileManager.default.removeItem(at: compiled)
                try FileManager.default.moveItem(at: temporary, to: compiled)
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndGPU
            return try MLModel(contentsOf: compiled, configuration: configuration)
        }.value
        return modelLock.withLock {
            if let cachedModel { return cachedModel }
            cachedModel = model
            return model
        }
    }

    private static func ensureModelPackage() async throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                 appropriateFor: nil, create: true)
        let package = support.appendingPathComponent("Negs/Models/LaMa.mlpackage", isDirectory: true)
        let manifest = package.appendingPathComponent("Manifest.json")
        let model = package.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel")
        let weights = package.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
        if fm.fileExists(atPath: manifest.path), fm.fileExists(atPath: model.path),
           try verifiedWeights(at: weights) { return package }

        try? fm.removeItem(at: package)
        try fm.createDirectory(at: weights.deletingLastPathComponent(), withIntermediateDirectories: true)
        let root = URL(string: "https://huggingface.co/mlboydaisuke/LaMa-CoreML/resolve/\(modelRevision)/LaMa.mlpackage")!
        do {
            let manifestData = try await URLSession.shared.data(from: root.appendingPathComponent("Manifest.json")).0
            try manifestData.write(to: manifest, options: .atomic)
            let modelURL = root.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel")
            let modelData = try await URLSession.shared.data(from: modelURL).0
            try modelData.write(to: model, options: .atomic)
            let weightURL = root.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
            let (temporary, response) = try await URLSession.shared.download(from: weightURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  try verifiedWeights(at: temporary) else { throw Failure.modelUnavailable }
            try fm.moveItem(at: temporary, to: weights)
            return package
        } catch {
            try? fm.removeItem(at: package)
            throw Failure.modelUnavailable
        }
    }

    private static func verifiedWeights(at url: URL) throws -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.int64Value == weightBytes,
              let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        var hasher = SHA256()
        do {
            while true {
                guard let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
        } catch {
            return false
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == weightSHA256
    }

    private static func run(model: MLModel, image: CGImage, mask: CGImage) throws -> Patch {
        guard image.width > 0, image.height > 0, image.width == mask.width, image.height == mask.height else {
            throw Failure.invalidImage
        }
        guard let bounds = maskBounds(mask) else { throw Failure.emptyMask }
        let frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let crop = cropRect(maskBounds: bounds, imageSize: frame.size)
        guard let imageCrop = image.cropping(to: crop), let maskCrop = mask.cropping(to: crop) else {
            throw Failure.invalidImage
        }
        let imageInput = try pixelBuffer(from: imageCrop, gray: false)
        let maskInput = try pixelBuffer(from: maskCrop, gray: true)
        let features = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: imageInput),
            "mask": MLFeatureValue(pixelBuffer: maskInput)
        ])
        let prediction = try model.prediction(from: features)
        guard let output = prediction.featureValue(for: "output")?.imageBufferValue else {
            throw Failure.outputMissing
        }

        let filled = CIImage(cvPixelBuffer: output).transformed(
            by: CGAffineTransform(scaleX: crop.width / CGFloat(side), y: crop.height / CGFloat(side)))
        let original = CIImage(cgImage: imageCrop)
        let blur = CIFilter(name: "CIGaussianBlur")!
        blur.setValue(CIImage(cgImage: maskCrop).clampedToExtent(), forKey: kCIInputImageKey)
        blur.setValue(2.0, forKey: kCIInputRadiusKey)
        let softMask = (blur.outputImage ?? CIImage(cgImage: maskCrop)).cropped(to: original.extent)
        let blend = CIFilter(name: "CIBlendWithMask")!
        blend.setValue(filled.cropped(to: original.extent), forKey: kCIInputImageKey)
        blend.setValue(original, forKey: kCIInputBackgroundImageKey)
        blend.setValue(softMask, forKey: kCIInputMaskImageKey)
        guard let patch = blend.outputImage.flatMap({ ciContext.createCGImage($0, from: original.extent) }) else {
            throw Failure.outputMissing
        }
        return Patch(image: patch,
                     x: Double(crop.minX / frame.width), y: Double(crop.minY / frame.height),
                     width: Double(crop.width / frame.width), height: Double(crop.height / frame.height))
    }

    private static func maskBounds(_ mask: CGImage) -> CGRect? {
        guard let data = mask.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let bpp = max(1, mask.bitsPerPixel / 8), rowBytes = mask.bytesPerRow
        var minX = mask.width, minY = mask.height, maxX = -1, maxY = -1
        for y in 0..<mask.height {
            let row = bytes.advanced(by: y * rowBytes)
            for x in 0..<mask.width where row[x * bpp] > 8 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY),
                      width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
    }

    private static func cropRect(maskBounds: CGRect, imageSize: CGSize) -> CGRect {
        let margin = max(maskBounds.width, maskBounds.height) * 0.6 + 32
        var side = max(maskBounds.width, maskBounds.height) + margin * 2
        side = max(side, CGFloat(LaMaInpainting.side))
        side = min(side, min(imageSize.width, imageSize.height))
        var x = maskBounds.midX - side / 2, y = maskBounds.midY - side / 2
        x = min(max(0, x), imageSize.width - side)
        y = min(max(0, y), imageSize.height - side)
        return CGRect(x: floor(x), y: floor(y), width: floor(side), height: floor(side))
    }

    private static func pixelBuffer(from image: CGImage, gray: Bool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let format = gray ? kCVPixelFormatType_OneComponent8 : kCVPixelFormatType_32BGRA
        guard CVPixelBufferCreate(nil, side, side, format, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw Failure.invalidImage }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let colorSpace = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = gray ? CGImageAlphaInfo.none.rawValue :
            (CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: colorSpace, bitmapInfo: bitmapInfo) else { throw Failure.invalidImage }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return buffer
    }
}
