import CoreGraphics
import Foundation
import ImageIO
import Security

enum BackgroundMaskRemovalProvider: String, CaseIterable, Identifiable {
    case openAI, localLaMa

    var id: String { rawValue }
    var title: String { self == .openAI ? "GPT Image" : "Local LaMa" }
}

/// Mask-guided object removal through the OpenAI Images edit API. The result
/// is stored as a patch; Rust composites it through the user's original mask.
enum OpenAIImageInpainting {
    static let model = "gpt-image-2.5-sunburst"
    private static let keychainAccount = "openai-image-api-key"
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 240
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    struct Patch {
        let image: CGImage
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    enum Failure: LocalizedError {
        case missingAPIKey, invalidImage, emptyMask, maskEncoding, api(String), invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: "Add an OpenAI API key in Settings › Upkeep to use GPT Image erase."
            case .invalidImage: "Could not prepare the selected photo area for GPT Image."
            case .emptyMask: "The selected mask is empty. Create or refine a mask first."
            case .maskEncoding: "Could not prepare the erase mask for GPT Image."
            case .api(let message): "OpenAI image erase failed: \(message)"
            case .invalidResponse: "OpenAI did not return a repaired image."
            }
        }
    }

    static var hasAPIKey: Bool { (try? apiKey()) != nil }

    static func apiKey() throws -> String? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw Failure.api("Could not read the saved API key from Keychain.")
        }
        return key
    }

    static func saveAPIKey(_ rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw Failure.missingAPIKey }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked]
        let status = SecItemUpdate(keychainQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = keychainQuery
            attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Failure.api("Could not save the API key to Keychain (\(addStatus)).") }
        } else if status != errSecSuccess {
            throw Failure.api("Could not update the API key in Keychain (\(status)).")
        }
    }

    static func deleteAPIKey() throws {
        let status = SecItemDelete(keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.api("Could not remove the API key from Keychain (\(status)).")
        }
    }

    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Bundle.main.bundleIdentifier ?? "Negs",
         kSecAttrAccount as String: keychainAccount]
    }

    static func inpaint(image: CGImage, mask: CGImage, apiKey: String) async throws -> Patch {
        guard image.width > 0, image.height > 0, image.width == mask.width, image.height == mask.height else {
            throw Failure.invalidImage
        }
        guard let bounds = maskBounds(mask) else { throw Failure.emptyMask }
        let crop = cropRect(maskBounds: bounds, imageSize: CGSize(width: image.width, height: image.height))
        guard let imageCrop = image.cropping(to: crop),
              let maskCrop = mask.cropping(to: crop),
              let imageData = pngData(imageCrop),
              let maskData = transparentSelectionPNG(maskCrop) else { throw Failure.maskEncoding }

        let boundary = "Negs-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/images/edits")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        appendField("model", value: model, boundary: boundary, to: &body)
        appendField("quality", value: "high", boundary: boundary, to: &body)
        appendField("size", value: "1024x1024", boundary: boundary, to: &body)
        appendField("output_format", value: "png", boundary: boundary, to: &body)
        appendFile("image[]", filename: "photo.png", mime: "image/png", data: imageData, boundary: boundary, to: &body)
        appendFile("mask", filename: "mask.png", mime: "image/png", data: maskData, boundary: boundary, to: &body)
        appendField("prompt", value: "Remove the object inside the transparent mask. Reconstruct the natural scene behind it using the surrounding visual context. Preserve everything outside the selected object, including the original composition, lighting, colors, and texture. Do not add objects or stylize the photograph.", boundary: boundary, to: &body)
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = parsed?["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "HTTP \(http.statusCode). Check the API key, organization access, and API billing."
            throw Failure.api(message)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]],
              let encoded = items.first?["b64_json"] as? String,
              let outputData = Data(base64Encoded: encoded),
              let source = CGImageSourceCreateWithData(outputData as CFData, nil),
              let output = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure.invalidResponse
        }
        return Patch(image: output,
                     x: Double(crop.minX) / Double(image.width),
                     y: Double(crop.minY) / Double(image.height),
                     width: Double(crop.width) / Double(image.width),
                     height: Double(crop.height) / Double(image.height))
    }

    private static func maskBounds(_ mask: CGImage) -> CGRect? {
        guard let provider = mask.dataProvider?.data, let bytes = CFDataGetBytePtr(provider) else { return nil }
        let bytesPerPixel = max(1, mask.bitsPerPixel / 8)
        var minX = mask.width, minY = mask.height, maxX = -1, maxY = -1
        for y in 0..<mask.height {
            let row = bytes.advanced(by: y * mask.bytesPerRow)
            for x in 0..<mask.width where row[x * bytesPerPixel] > 8 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func cropRect(maskBounds: CGRect, imageSize: CGSize) -> CGRect {
        let maximum = min(2048.0, min(imageSize.width, imageSize.height))
        let side = min(maximum, max(768.0, max(maskBounds.width, maskBounds.height) * 2.2))
        let x = min(max(maskBounds.midX - side / 2, 0), imageSize.width - side)
        let y = min(max(maskBounds.midY - side / 2, 0), imageSize.height - side)
        return CGRect(x: floor(x), y: floor(y), width: floor(side), height: floor(side))
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// OpenAI uses transparent pixels to indicate the region it should edit.
    private static func transparentSelectionPNG(_ mask: CGImage) -> Data? {
        var gray = [UInt8](repeating: 0, count: mask.width * mask.height)
        let rendered = gray.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: mask.width, height: mask.height,
                                          bitsPerComponent: 8, bytesPerRow: mask.width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(mask, in: CGRect(x: 0, y: 0, width: mask.width, height: mask.height))
            return true
        }
        guard rendered else { return nil }
        var rgba = [UInt8](repeating: 0, count: gray.count * 4)
        for index in gray.indices {
            let offset = index * 4
            rgba[offset] = 255; rgba[offset + 1] = 255; rgba[offset + 2] = 255
            rgba[offset + 3] = 255 - gray[index]
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: mask.width, height: mask.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: mask.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return pngData(image)
    }

    private static func appendField(_ name: String, value: String, boundary: String, to data: inout Data) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    private static func appendFile(_ name: String, filename: String, mime: String, data fileData: Data,
                                   boundary: String, to data: inout Data) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        data.append(fileData)
        data.append(Data("\r\n".utf8))
    }
}
