import AppKit
import ImageIO
import Vision

/// A private, on-device culling pass. Vision supplies face/eye and aesthetic
/// inference; sharpness and subject placement remain explicitly labeled
/// image-analysis heuristics rather than opaque model claims.
enum CullAnalyzer {
    static func analyze(_ url: URL) -> CullAnalysis? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let raw = EditorModel.rawExtensions.contains(url.pathExtension.lowercased())
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if !raw { options[kCGImageSourceCreateThumbnailFromImageAlways] = true }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let faceRequest = VNDetectFaceLandmarksRequest()
        let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([faceRequest, saliencyRequest])
        } catch {
            return nil
        }

        let faces = faceRequest.results ?? []
        let eyesOpen = eyeState(faces)
        let sharpness = sharpnessScore(image)
        let composition = compositionScore(saliencyRequest.results?.first)
        let aesthetic = aestheticScore(image)
        let utility = aesthetic?.utility ?? false

        var components: [(Double, Double)] = [(Double(sharpness), 0.30)]
        if let aesthetic { components.append((Double(aesthetic.score), 0.50)) }
        if let composition { components.append((Double(composition), 0.15)) }
        if let eyesOpen { components.append((eyesOpen ? 100 : 0, 0.05)) }
        let weight = components.reduce(0) { $0 + $1.1 }
        var score = Int((components.reduce(0) { $0 + $1.0 * $1.1 } / max(weight, 0.001)).rounded())
        if eyesOpen == false { score = min(score, 48) }
        if sharpness < 18 { score = min(score, 32) }
        if utility { score = min(score, 40) }

        var reasons: [String] = []
        if let aesthetic {
            if aesthetic.score >= 72 { reasons.append("Vision aesthetic model found a strong image") }
            else if aesthetic.score < 42 { reasons.append("Vision aesthetic model rated the image low") }
            else { reasons.append("Vision aesthetic model rated the image as mid-range") }
            if aesthetic.utility { reasons.append("Vision marked this as a utility image, not a memorable frame") }
        } else {
            reasons.append("Aesthetic AI requires macOS 15 or later; score uses available local signals")
        }
        if sharpness < 30 { reasons.append("Low edge detail suggests a soft or motion-blurred frame") }
        else if sharpness >= 70 { reasons.append("Strong edge detail supports good subject focus") }
        if let composition {
            if composition >= 70 { reasons.append("Salient subject placement balances well with the frame") }
            else if composition < 40 { reasons.append("Salient subject sits close to an edge; check framing") }
        }
        if let eyesOpen {
            reasons.append(eyesOpen ? "Detected eyes appear open" : "Face landmarks suggest closed eyes")
        } else if faces.isEmpty {
            reasons.append("No face detected; eye state does not apply")
        } else {
            reasons.append("Could not confidently determine eye state")
        }

        return CullAnalysis(score: score, sharpness: sharpness, aesthetics: aesthetic?.score,
                            composition: composition, eyesOpen: eyesOpen, faceCount: faces.count,
                            utilityImage: utility, reasons: reasons)
    }

    private static func aestheticScore(_ image: CGImage) -> (score: Int, utility: Bool)? {
        guard #available(macOS 15.0, *) else { return nil }
        let request = VNCalculateImageAestheticsScoresRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            guard let result = request.results?.first else { return nil }
            return (Int((((Double(result.overallScore) + 1) / 2) * 100).rounded()), result.isUtility)
        } catch {
            return nil
        }
    }

    private static func eyeState(_ faces: [VNFaceObservation]) -> Bool? {
        guard !faces.isEmpty else { return nil }
        var observedEyes = 0
        var everyObservedEyeOpen = true
        for face in faces {
            guard let landmarks = face.landmarks else { continue }
            for eye in [landmarks.leftEye, landmarks.rightEye].compactMap({ $0 }) {
                let points = eye.normalizedPoints
                guard points.count >= 4 else { continue }
                let xs = points.map(\.x), ys = points.map(\.y)
                guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(), maxX > minX else { continue }
                observedEyes += 1
                if (maxY - minY) / (maxX - minX) < 0.13 { everyObservedEyeOpen = false }
            }
        }
        guard observedEyes > 0 else { return nil }
        return everyObservedEyeOpen
    }

    private static func compositionScore(_ observation: VNSaliencyImageObservation?) -> Int? {
        guard let object = observation?.salientObjects?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) else {
            return nil
        }
        let box = object.boundingBox
        let x = box.midX, y = box.midY
        let thirdsDistance = [hypot(x - 1.0 / 3, y - 1.0 / 3), hypot(x - 2.0 / 3, y - 1.0 / 3),
                              hypot(x - 1.0 / 3, y - 2.0 / 3), hypot(x - 2.0 / 3, y - 2.0 / 3)].min() ?? 0.5
        // This is a frame-placement heuristic, not a learned composition grade.
        return min(100, max(0, Int((100 - thirdsDistance * 150).rounded())))
    }

    private static func sharpnessScore(_ image: CGImage) -> Int {
        let width = image.width, height = image.height
        guard width > 2, height > 2 else { return 0 }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return 0 }
        var gray = [Float](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let offset = index * 4
            gray[index] = 0.2126 * Float(pixels[offset]) + 0.7152 * Float(pixels[offset + 1]) + 0.0722 * Float(pixels[offset + 2])
        }
        var sum: Double = 0, sumSquared: Double = 0, count = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let value = Double(abs(4 * gray[i] - gray[i - 1] - gray[i + 1] - gray[i - width] - gray[i + width]))
                sum += value
                sumSquared += value * value
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let deviation = sqrt(max(0, sumSquared / Double(count) - pow(sum / Double(count), 2)))
        return min(100, max(0, Int((100 * (1 - exp(-deviation / 42))).rounded())))
    }
}
