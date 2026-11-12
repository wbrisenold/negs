import AppKit
import ImageIO
import Vision

/// A private, on-device culling pass. Vision supplies face/eye and aesthetic
/// inference; sharpness and subject placement remain explicitly labeled
/// image-analysis heuristics rather than opaque model claims. The blended score
/// is a ranking aid, not a calibrated probability or a model trained on a
/// photographer's personal keep/reject decisions.
enum CullAnalyzer {
    private struct ExposureMetrics {
        let score: Int
        let faceScore: Int?
        let clippedHighlightsPercent: Double
        let crushedShadowsPercent: Double
        let medianLuma: Int
    }

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
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([faceRequest, saliencyRequest])
        } catch {
            return nil
        }

        let faces = faceRequest.results ?? []
        let eyesOpen = eyeState(faces)
        let sharpness = sharpnessMetrics(image, faces: faces)
        let faceCaptureRequest = VNDetectFaceCaptureQualityRequest()
        faceCaptureRequest.inputFaceObservations = faces
        let faceCaptureQuality: Int? = {
            guard !faces.isEmpty else { return nil }
            do {
                try handler.perform([faceCaptureRequest])
                return representativeFaceValue(faceCaptureRequest.results ?? []) {
                    guard let quality = $0.faceCaptureQuality else { return nil }
                    return Int((Double(quality) * 100).rounded())
                }
            } catch { return nil }
        }()
        let composition = compositionScore(saliencyRequest.results?.first)
        let sceneFingerprint = sceneFingerprint(image)
        let aesthetic = aestheticScore(image)
        let utility = aesthetic?.utility ?? false
        let exposure = sharpness.exposure

        // Every available quality signal contributes independently. Missing
        // signals are omitted and the remaining weights are normalized.
        var components: [(Double, Double)] = [(Double(sharpness.frame), 0.12),
                                               (Double(exposure.score), 0.20)]
        if let faceSharpness = sharpness.face { components.append((Double(faceSharpness), 0.18)) }
        if let faceCaptureQuality { components.append((Double(faceCaptureQuality), 0.15)) }
        if let faceExposure = exposure.faceScore { components.append((Double(faceExposure), 0.10)) }
        if let aesthetic { components.append((Double(aesthetic.score), 0.15)) }
        if let composition { components.append((Double(composition), 0.05)) }
        if let eyesOpen { components.append((eyesOpen ? 100 : 0, 0.05)) }
        let weight = components.reduce(0) { $0 + $1.1 }
        var score = Int((components.reduce(0) { $0 + $1.0 * $1.1 } / max(weight, 0.001)).rounded())
        if eyesOpen == false { score = min(score, 48) }
        if sharpness.frame < 18 { score = min(score, 32) }
        if let faceSharpness = sharpness.face {
            // A sharp-looking background cannot compensate for an out-of-focus
            // primary face. These caps are explicit culling gates, not weights.
            if faceSharpness < 25 { score = min(score, 30) }
            else if faceSharpness < 40 { score = min(score, 48) }
            else if faceSharpness < 55 { score = min(score, 62) }
        }
        if exposure.score < 25 { score = min(score, 42) }
        else if exposure.score < 40 { score = min(score, 56) }
        if exposure.clippedHighlightsPercent >= 20 || exposure.crushedShadowsPercent >= 20 {
            score = min(score, 40)
        } else if exposure.clippedHighlightsPercent >= 8 || exposure.crushedShadowsPercent >= 12 {
            score = min(score, 56)
        }
        if let faceExposure = exposure.faceScore {
            if faceExposure < 24 { score = min(score, 38) }
            else if faceExposure < 40 { score = min(score, 54) }
        }
        if let faceCaptureQuality, faceCaptureQuality < 20 { score = min(score, 46) }
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
        if sharpness.frame < 30 { reasons.append("Low whole-frame edge detail suggests softness or motion blur") }
        else if sharpness.frame >= 70 { reasons.append("Strong whole-frame edge detail") }
        if let faceSharpness = sharpness.face {
            if faceSharpness < 25 { reasons.append("Primary face detail is very soft; this frame should not rank as a keeper") }
            else if faceSharpness < 40 { reasons.append("Primary face is soft; a strong background cannot compensate for missed focus") }
            else if faceSharpness < 55 { reasons.append("Primary face detail is borderline; review focus at full size") }
            else if faceSharpness >= 70 { reasons.append("Primary face has crisp edge detail") }
        }
        if let faceCaptureQuality {
            if faceCaptureQuality < 35 { reasons.append("Vision found low face capture quality; check focus, lighting and pose") }
            else if faceCaptureQuality >= 72 { reasons.append("Vision found a clear, well-captured face") }
        }
        if exposure.clippedHighlightsPercent >= 1 {
            reasons.append(String(format: "%.1f%% of pixels are at highlight clipping", exposure.clippedHighlightsPercent))
        }
        if exposure.crushedShadowsPercent >= 1 {
            reasons.append(String(format: "%.1f%% of pixels are crushed into black", exposure.crushedShadowsPercent))
        }
        if exposure.score < 45 {
            reasons.append("Overall tonal placement is far from the usable exposure range")
        }
        if let faceExposure = exposure.faceScore, faceExposure < 45 {
            reasons.append("Primary face exposure is low or clipped")
        }
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

        return CullAnalysis(score: score, sharpness: sharpness.frame, faceSharpness: sharpness.face,
                            faceCaptureQuality: faceCaptureQuality, faceExposure: exposure.faceScore,
                            exposure: exposure.score, clippedHighlightsPercent: exposure.clippedHighlightsPercent,
                            crushedShadowsPercent: exposure.crushedShadowsPercent,
                            sceneFingerprint: sceneFingerprint, captureDate: captureDate(source),
                            aesthetics: aesthetic?.score,
                            composition: composition, eyesOpen: eyesOpen, faceCount: faces.count,
                            utilityImage: utility, reasons: reasons)
    }

    /// Capture time from embedded image metadata (including RAW metadata).
    /// Used only for burst grouping; it does not replace file modification time
    /// shown in the Library.
    private static func captureDate(_ source: CGImageSource) -> Date? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let value = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }

    /// A compact secure archive of Vision's semantic image feature print.
    /// The 1024px analysis thumbnail keeps this entirely on-device.
    private static func sceneFingerprint(_ image: CGImage) -> Data? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        request.imageCropAndScaleOption = .scaleFit
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            guard let observation = request.results?.first else { return nil }
            return try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
        } catch { return nil }
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

    private static func representativeFaceValue(_ faces: [VNFaceObservation], value: (VNFaceObservation) -> Int?) -> Int? {
        guard let largest = faces.map({ $0.boundingBox.width * $0.boundingBox.height }).max(), largest > 0 else { return nil }
        // Ignore tiny background detections. Rank the largest visible faces and
        // take the lower quartile so one soft primary subject isn't hidden by
        // a sharper secondary face.
        let primary = faces.filter { $0.boundingBox.width * $0.boundingBox.height >= largest * 0.25 }
            .compactMap(value).sorted()
        guard !primary.isEmpty else { return nil }
        return primary[(primary.count - 1) / 4]
    }

    private static func sharpnessMetrics(_ image: CGImage, faces: [VNFaceObservation])
        -> (frame: Int, face: Int?, exposure: ExposureMetrics) {
        let width = image.width, height = image.height
        guard width > 2, height > 2 else {
            return (0, nil, ExposureMetrics(score: 0, faceScore: nil,
                                             clippedHighlightsPercent: 0, crushedShadowsPercent: 0, medianLuma: 0))
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else {
            return (0, nil, ExposureMetrics(score: 0, faceScore: nil,
                                             clippedHighlightsPercent: 0, crushedShadowsPercent: 0, medianLuma: 0))
        }
        var gray = [Float](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let offset = index * 4
            gray[index] = 0.2126 * Float(pixels[offset]) + 0.7152 * Float(pixels[offset + 1]) + 0.0722 * Float(pixels[offset + 2])
        }
        let exposure = exposureMetrics(gray, width: width, height: height, faces: faces)

        func score(_ rect: CGRect) -> Int? {
            let x0 = max(1, Int(floor(rect.minX))), x1 = min(width - 1, Int(ceil(rect.maxX)))
            let y0 = max(1, Int(floor(rect.minY))), y1 = min(height - 1, Int(ceil(rect.maxY)))
            guard x1 - x0 >= 5, y1 - y0 >= 5 else { return nil }
            var sum: Double = 0, sumSquared: Double = 0, count = 0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = y * width + x
                    let laplacian = Double(4 * gray[i] - gray[i - 1] - gray[i + 1] - gray[i - width] - gray[i + width])
                    sum += laplacian
                    sumSquared += laplacian * laplacian
                    count += 1
                }
            }
            guard count > 0 else { return nil }
            let variance = max(0, sumSquared / Double(count) - pow(sum / Double(count), 2))
            let deviation = sqrt(variance)
            return min(100, max(0, Int((100 * (1 - exp(-deviation / 42))).rounded())))
        }

        let frameScore = score(CGRect(x: 1, y: 1, width: width - 2, height: height - 2)) ?? 0
        let faceScore = representativeFaceValue(faces) { face in
            let box = face.boundingBox
            let padX = box.width * 0.12, padY = box.height * 0.12
            let expanded = box.insetBy(dx: -padX, dy: -padY).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            let pixelRect = CGRect(x: expanded.minX * CGFloat(width),
                                   y: (1 - expanded.maxY) * CGFloat(height),
                                   width: expanded.width * CGFloat(width),
                                   height: expanded.height * CGFloat(height))
            return score(pixelRect)
        }
        return (frameScore, faceScore, exposure)
    }

    private static func exposureMetrics(_ gray: [Float], width: Int, height: Int,
                                        faces: [VNFaceObservation]) -> ExposureMetrics {
        var histogram = [Int](repeating: 0, count: 256)
        for value in gray {
            histogram[min(255, max(0, Int(value.rounded())))] += 1
        }
        let total = max(1, gray.count)
        func percentile(_ bins: [Int], _ q: Double) -> Int {
            let target = Int(Double(bins.reduce(0, +) - 1) * q)
            var accumulated = 0
            for (value, count) in bins.enumerated() {
                accumulated += count
                if accumulated > target { return value }
            }
            return 255
        }
        let median = percentile(histogram, 0.5)
        let highlights = Double(histogram[254] + histogram[255]) / Double(total) * 100
        let shadows = Double(histogram[0] + histogram[1] + histogram[2]) / Double(total) * 100
        var score = 100.0
        score -= min(36, max(0, highlights - 0.25) * 3.5)
        score -= min(36, max(0, shadows - 0.25) * 3.0)
        if median < 45 { score -= min(20, Double(45 - median) * 0.4) }
        if median > 218 { score -= min(15, Double(median - 218) * 0.35) }

        let largest = faces.map { $0.boundingBox.width * $0.boundingBox.height }.max() ?? 0
        let faceScores = faces.filter {
            largest > 0 && $0.boundingBox.width * $0.boundingBox.height >= largest * 0.25
        }.compactMap { face -> Int? in
            let box = face.boundingBox.insetBy(dx: -face.boundingBox.width * 0.12,
                                               dy: -face.boundingBox.height * 0.12)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            let x0 = max(0, Int(box.minX * CGFloat(width))), x1 = min(width, Int(ceil(box.maxX * CGFloat(width))))
            let y0 = max(0, Int((1 - box.maxY) * CGFloat(height))), y1 = min(height, Int(ceil((1 - box.minY) * CGFloat(height))))
            guard x1 > x0, y1 > y0 else { return nil }
            var faceHistogram = [Int](repeating: 0, count: 256)
            for y in y0..<y1 {
                for x in x0..<x1 {
                    faceHistogram[min(255, max(0, Int(gray[y * width + x].rounded())))] += 1
                }
            }
            let faceMedian = percentile(faceHistogram, 0.5)
            let penalty = faceMedian < 42
                ? Double(42 - faceMedian) * 1.2
                : faceMedian < 68 ? Double(68 - faceMedian) * 0.35
                : faceMedian > 232 ? Double(faceMedian - 232) * 1.25
                : faceMedian > 210 ? Double(faceMedian - 210) * 0.25
                : 0
            return min(100, max(0, Int((100 - penalty).rounded())))
        }.sorted()
        let faceScore = faceScores.isEmpty ? nil : faceScores[(faceScores.count - 1) / 4]
        return ExposureMetrics(score: min(100, max(0, Int(score.rounded()))),
                               faceScore: faceScore,
                               clippedHighlightsPercent: highlights,
                               crushedShadowsPercent: shadows,
                               medianLuma: median)
    }
}
