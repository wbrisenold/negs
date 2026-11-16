import Foundation
import CoreImage
import IOSurface
import SwiftUI
import Vision

/// The developed photograph's tones: 256 bins per channel of the cropped
/// photograph. The border is drawn on the canvas, never in the preview, so
/// it never counts.
struct Histogram: Equatable, Sendable {
    var red = [UInt32](repeating: 0, count: 256)
    var green = [UInt32](repeating: 0, count: 256)
    var blue = [UInt32](repeating: 0, count: 256)

    static func of(_ surface: IOSurface, crop: CropSettings, maxSamples: Int = 1 << 20) -> Histogram {
        ImageScopes.of(surface, crop: crop, maxSamples: maxSamples, mode: .histogram).histogram
    }

    /// The tallest bin, leaving out pure black and white so clipping doesn't
    /// flatten the rest; their spikes run off the top instead.
    var peak: UInt32 {
        let inner = [red, green, blue].map { $0[1..<255].max() ?? 0 }.max() ?? 0
        return inner > 0 ? inner : [red, green, blue].map { $0.max() ?? 0 }.max() ?? 0
    }
}

/// RGB signal level against horizontal position in the displayed crop.
/// Bins are row-major, with level 0 at row 0 and 255 at row 255.
struct Waveform: Equatable, Sendable {
    let width: Int
    let red: [UInt32]
    let green: [UInt32]
    let blue: [UInt32]
    /// Three side-by-side channel rasters keep the RGB parade drawing
    /// independent of photo size and prevent overlaid channels washing white.
    let rgba: [UInt8]
    let sampleCount: Int

    init(width: Int = 1, red: [UInt32] = Array(repeating: 0, count: 256),
         green: [UInt32] = Array(repeating: 0, count: 256), blue: [UInt32] = Array(repeating: 0, count: 256)) {
        self.width = width; self.red = red; self.green = green; self.blue = blue
        sampleCount = Int(red.reduce(0, +))
        let peak = max(red.max() ?? 0, green.max() ?? 0, blue.max() ?? 0)
        let normalizer = log1p(Double(peak))
        let paradeWidth = width * 3
        var pixels = [UInt8](repeating: 0, count: paradeWidth * 256 * 4)
        if peak > 0 {
            func intensity(_ count: UInt32) -> UInt8 {
                // A waveform is a density trace. The old 16–100% floor made
                // every occupied bin look equally loud, turning fine detail
                // into a noisy block on high-resolution previews.
                count == 0 ? 0 : UInt8((168 * (0.035 + 0.965 * log1p(Double(count)) / normalizer)).rounded())
            }
            // Keep the channel list out of the per-bin loop: constructing it
            // for all 65,536 bins creates needless arrays on Intel.
            for (channel, counts) in [red, green, blue].enumerated() {
                for level in 0..<256 {
                    for x in 0..<width {
                        let source = level * width + x
                        let row = (255 - level) * paradeWidth
                        let value = intensity(counts[source])
                        let pixel = (row + channel * width + x) * 4
                        pixels[pixel + channel] = value
                        pixels[pixel + 3] = value
                    }
                }
            }
        }
        rgba = pixels
    }

    var image: CGImage? {
        guard sampleCount > 0, let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width * 3, height: 256, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 3 * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Both scopes are derived from the same bounded grid and crop transform.
/// A single surface lock/pass avoids competing background scans on every edit.
struct ImageScopes: Equatable, Sendable {
    var histogram = Histogram()
    var waveform = Waveform()
    var vectorscope = Vectorscope()
    var skinAnalysis = SkinAnalysis()

    /// Transparent false-colour mask for clipped highlights (red) and
    /// crushed shadows (blue). Highlights include either clipped luma or an
    /// individually clipped RGB channel, so saturated colour clipping is
    /// visible even when the weighted luma remains below white. Generated
    /// only when the viewer overlay is on.
    static func clippingOverlay(_ surface: IOSurface, low: Double, high: Double) -> CGImage? {
        guard surface.width > 0, surface.height > 0, surface.bytesPerElement == 4,
              surface.planeCount <= 1, !Task.isCancelled else { return nil }
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let sourceWidth = surface.width, sourceHeight = surface.height
        let scale = min(1.0, sqrt(Double(1 << 22) / Double(sourceWidth * sourceHeight)))
        let width = max(1, Int((Double(sourceWidth) * scale).rounded()))
        let height = max(1, Int((Double(sourceHeight) * scale).rounded()))
        let source = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let rowBytes = surface.bytesPerRow
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            if Task.isCancelled { return nil }
            let sy = min(sourceHeight - 1, Int((Double(y) + 0.5) * Double(sourceHeight) / Double(height)))
            for x in 0..<width {
                let sx = min(sourceWidth - 1, Int((Double(x) + 0.5) * Double(sourceWidth) / Double(width)))
                let src = sy * rowBytes + sx * surface.bytesPerElement
                let r = source[src + 2], g = source[src + 1], b = source[src]
                let offset = (y * width + x) * 4
                let y = (0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)) / 255
                let channelClipped = Double(max(r, max(g, b))) / 255 >= high
                if y <= low {
                    rgba[offset] = 12; rgba[offset + 1] = 34; rgba[offset + 2] = 230; rgba[offset + 3] = 230
                } else if y >= high || channelClipped {
                    rgba[offset] = 230; rgba[offset + 1] = 18; rgba[offset + 2] = 12; rgba[offset + 3] = 230
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// False-colour exposure map for the developed display-referred frame.
    /// It is generated only while enabled and capped at one megapixel so it
    /// remains a lightweight diagnostic overlay rather than a develop stage.
    static func falseColorOverlay(_ surface: IOSurface) -> CGImage? {
        guard surface.width > 0, surface.height > 0, surface.bytesPerElement == 4,
              surface.planeCount <= 1, !Task.isCancelled else { return nil }
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let sourceWidth = surface.width, sourceHeight = surface.height
        let scale = min(1.0, sqrt(Double(1 << 20) / Double(sourceWidth * sourceHeight)))
        let width = max(1, Int((Double(sourceWidth) * scale).rounded()))
        let height = max(1, Int((Double(sourceHeight) * scale).rounded()))
        let source = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let rowBytes = surface.bytesPerRow, alpha = 224.0 / 255.0
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            if Task.isCancelled { return nil }
            let sy = min(sourceHeight - 1, Int((Double(y) + 0.5) * Double(sourceHeight) / Double(height)))
            for x in 0..<width {
                let sx = min(sourceWidth - 1, Int((Double(x) + 0.5) * Double(sourceWidth) / Double(width)))
                let src = sy * rowBytes + sx * surface.bytesPerElement
                // IOSurface preview pixels are BGRA; luma weights are RGB.
                let luma = (19 * Int(source[src]) + 183 * Int(source[src + 1]) + 54 * Int(source[src + 2])) >> 8
                let color: (UInt8, UInt8, UInt8)
                switch luma {
                case ..<13: color = (14, 8, 52)       // 0–5 IRE: near-black
                case ..<31: color = (34, 46, 190)     // 5–12 IRE: deep blue
                case ..<64: color = (0, 164, 222)     // 12–25 IRE: cyan
                case ..<112: color = (0, 178, 88)     // 25–44 IRE: green
                case ..<148: color = (225, 210, 0)    // 44–58 IRE: yellow
                case ..<179: color = (255, 132, 0)    // 58–70 IRE: orange
                case ..<217: color = (226, 32, 28)    // 70–85 IRE: red
                case ..<245: color = (213, 32, 196)   // 85–96 IRE: magenta
                default: color = (245, 245, 245)      // 96–100 IRE: highlight
                }
                let offset = (y * width + x) * 4
                rgba[offset] = UInt8((Double(color.0) * alpha).rounded())
                rgba[offset + 1] = UInt8((Double(color.1) * alpha).rounded())
                rgba[offset + 2] = UInt8((Double(color.2) * alpha).rounded())
                rgba[offset + 3] = 224
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func of(_ surface: IOSurface, crop: CropSettings, rotation: Int = 0, maxSamples: Int = 1 << 20,
                   mode: ScopeMode? = nil) -> ImageScopes {
        guard surface.width > 0, surface.height > 0, surface.bytesPerElement == 4,
              surface.planeCount <= 1, !Task.isCancelled else { return ImageScopes() }
        let size = CGSize(width: surface.width, height: surface.height)
        let area = crop.pixels(in: size)
        guard area.width >= 1, area.height >= 1, maxSamples > 0 else { return ImageScopes() }
        let wantsHistogram = mode == nil || mode == .histogram
        let wantsWaveform = mode == nil || mode == .waveform
        let wantsVectorscope = mode == nil || mode == .vectorscope || mode == .skin
        let wantsSkin = mode == nil || mode == .skin
        let width = Int(area.width), height = Int(area.height)
        // This also bounds very thin panoramas: a single common pixel stride
        // can exceed the budget when one of the dimensions is much shorter.
        let columns = min(width, maxSamples, max(1, Int((Double(maxSamples) * Double(width) / Double(height)).squareRoot())))
        let rows = min(height, max(1, maxSamples / columns))
        let turn = (rotation % 4 + 4) % 4
        let shownColumns = turn % 2 == 0 ? columns : rows
        let waveWidth = wantsWaveform ? min(256, shownColumns) : 1
        var red = [UInt32](repeating: 0, count: wantsWaveform ? waveWidth * 256 : 0)
        var green = red, blue = red
        var histogram = Histogram()
        let vectorSize = 128
        var vectorBins = [UInt16](repeating: 0, count: wantsVectorscope ? vectorSize * vectorSize : 0)
        var skinBins = [UInt16](repeating: 0, count: wantsSkin ? vectorSize * vectorSize : 0)
        var skinAngles: Double = 0
        var skinSamples = 0
        var onTarget = 0, tooMagenta = 0, tooGreen = 0
        let sampleCount = columns * rows
        if Task.isCancelled { return ImageScopes() }
        let faceBoxes: [CGRect] = wantsSkin ? autoreleasepool {
            let request = VNDetectFaceRectanglesRequest()
            do {
                try VNImageRequestHandler(ciImage: CIImage(ioSurface: surface), options: [:]).perform([request])
                return (request.results ?? []).map { $0.boundingBox.insetBy(dx: -0.025, dy: -0.025) }
            } catch { return [] }
        } : []
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let rowBytes = surface.bytesPerRow
        // A straightened crop is in the turned frame: turn each sample back
        // to the photograph, as CropGeometry.turn(_:by: -angle, about:).
        let (sin, cos) = (Foundation.sin(-crop.angle * .pi / 180), Foundation.cos(-crop.angle * .pi / 180))
        let (cx, cy) = (size.width / 2, size.height / 2)
        for row in 0..<rows {
            if Task.isCancelled { return ImageScopes() }
            for column in 0..<columns {
                let dx = area.minX + (Double(column) + 0.5) * area.width / Double(columns) - cx
                let dy = area.minY + (Double(row) + 0.5) * area.height / Double(rows) - cy
                let x = Int((cx + dx * cos - dy * sin).rounded(.down))
                let y = Int((cy + dx * sin + dy * cos).rounded(.down))
                guard x >= 0, x < surface.width, y >= 0, y < surface.height else { continue }
                let pixel = base + y * rowBytes + x * 4
                let (r, g, b) = (Int(pixel[2]), Int(pixel[1]), Int(pixel[0]))
                if wantsHistogram {
                    histogram.red[r] += 1; histogram.green[g] += 1; histogram.blue[b] += 1
                }
                var vx = 0, vy = 0, cr = 0.0, cb = 0.0, rf = 0.0, gf = 0.0, bf = 0.0, luma = 0.0
                if wantsVectorscope {
                    (rf, gf, bf) = (Double(r) / 255, Double(g) / 255, Double(b) / 255)
                    luma = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
                    cb = (bf - luma) / (2 * (1 - 0.0722))
                    cr = (rf - luma) / (2 * (1 - 0.2126))
                    vx = min(vectorSize - 1, max(0, Int(((cb + 0.5) * Double(vectorSize - 1)).rounded())))
                    vy = min(vectorSize - 1, max(0, Int(((0.5 - cr) * Double(vectorSize - 1)).rounded())))
                    let bin = vy * vectorSize + vx
                    if vectorBins[bin] < UInt16.max { vectorBins[bin] += 1 }
                }
                // Skin estimate follows the studio vectorscope's hue analysis,
                // limited to a broad chroma envelope. It is not a semantic mask.
                if wantsSkin {
                    let point = CGPoint(x: Double(x) / Double(surface.width), y: 1 - Double(y) / Double(surface.height))
                    let withinFace = faceBoxes.contains { $0.contains(point) }
                    let looksLikeSkin = withinFace && luma > 0.08 && cr > 0.025 && cr < 0.28 && cb > -0.18 && cb < 0.12
                        && rf > gf && gf > bf * 0.72
                    if looksLikeSkin {
                        skinSamples += 1
                        let angle = atan2(cr, cb) * 180 / .pi
                        let delta = wrappedDegrees(angle - 123)
                        skinAngles += delta
                        if abs(delta) <= 12 { onTarget += 1 }
                        else if delta < 0 { tooMagenta += 1 }
                        else { tooGreen += 1 }
                        let bin = vy * vectorSize + vx
                        if skinBins[bin] < UInt16.max { skinBins[bin] += 1 }
                    }
                }
                guard wantsWaveform else { continue }
                let shownColumn: Int
                switch turn {
                case 1: shownColumn = rows - 1 - row
                case 2: shownColumn = columns - 1 - column
                case 3: shownColumn = row
                default: shownColumn = column
                }
                let waveX = shownColumn * waveWidth / shownColumns
                red[r * waveWidth + waveX] += 1; green[g * waveWidth + waveX] += 1; blue[b * waveWidth + waveX] += 1
            }
        }
        let analysis = SkinAnalysis(sampledPixels: sampleCount, candidatePixels: skinSamples,
            meanDeviationDegrees: skinSamples > 0 ? skinAngles / Double(skinSamples) : nil,
            withinTolerancePercent: skinSamples > 0 ? 100 * Double(onTarget) / Double(skinSamples) : 0,
            tooMagentaPercent: skinSamples > 0 ? 100 * Double(tooMagenta) / Double(skinSamples) : 0,
            tooGreenPercent: skinSamples > 0 ? 100 * Double(tooGreen) / Double(skinSamples) : 0)
        return ImageScopes(histogram: histogram,
            waveform: wantsWaveform ? Waveform(width: waveWidth, red: red, green: green, blue: blue) : Waveform(),
            vectorscope: wantsVectorscope ? Vectorscope(size: vectorSize, bins: vectorBins, skinBins: skinBins) : Vectorscope(),
            skinAnalysis: wantsSkin ? analysis : SkinAnalysis())
    }
}

private func wrappedDegrees(_ angle: Double) -> Double {
    var value = angle
    while value > 180 { value -= 360 }
    while value < -180 { value += 360 }
    return value
}

struct SkinAnalysis: Equatable, Sendable {
    var sampledPixels = 0
    var candidatePixels = 0
    var meanDeviationDegrees: Double?
    var withinTolerancePercent = 0.0
    var tooMagentaPercent = 0.0
    var tooGreenPercent = 0.0
    var candidatePercent: Double { sampledPixels > 0 ? 100 * Double(candidatePixels) / Double(sampledPixels) : 0 }
    var coveragePercent: Double { min(100, candidatePercent / 6 * 100) }
    var status: String {
        guard let meanDeviationDegrees, coveragePercent > 4 else { return "No reliable skin sample" }
        if meanDeviationDegrees < -12 { return "Too magenta" }
        if meanDeviationDegrees > 12 { return "Too green" }
        return "Near skin-tone line"
    }
}

struct Vectorscope: Equatable, Sendable {
    let size: Int
    let bins: [UInt16]
    let skinBins: [UInt16]

    init(size: Int = 128, bins: [UInt16] = [], skinBins: [UInt16] = []) {
        self.size = size
        self.bins = bins
        self.skinBins = skinBins
    }

    var sampleCount: Int { bins.reduce(0) { $0 + Int($1) } }
    var skinSampleCount: Int { skinBins.reduce(0) { $0 + Int($1) } }
}

/// Filled channels and fine outlines echo Sawmill's histogram.
struct HistogramView: View {
    let histogram: Histogram?

    var body: some View {
        Canvas { context, size in
            scopeGrid(context: &context, size: size)
            guard let histogram, histogram.peak > 0 else { return }
            let peak = Double(histogram.peak)
            context.blendMode = .plusLighter
            for (bins, color) in [(histogram.red, Color(red: 1, green: 0.42, blue: 0.42)),
                                  (histogram.green, Color(red: 0.42, green: 0.8, blue: 0.47)),
                                  (histogram.blue, Color(red: 0.3, green: 0.59, blue: 1))] {
                var line = Path()
                for (index, count) in bins.enumerated() {
                    let point = CGPoint(x: size.width * CGFloat(index) / CGFloat(bins.count - 1),
                                        y: size.height * (1 - min(Double(count) / peak, 1)))
                    if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                var fill = line
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                context.fill(fill, with: .color(color.opacity(0.4)))
                context.stroke(line, with: .color(color.opacity(0.9)), lineWidth: 1)
            }
        }
        .padding(.horizontal, 4).padding(.top, 6)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 3))
        .accessibilityElement()
        .accessibilityLabel("Histogram")
        .accessibilityValue(histogram == nil ? "No developed photograph" : "Red, green, and blue tones of the developed photograph")
    }
}

struct WaveformView: View {
    let waveform: Waveform?

    var body: some View {
        HStack(spacing: 4) {
            VStack {
                ForEach([100, 75, 50, 25, 0], id: \.self) { level in
                    Text("\(level)").font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.dim)
                    if level != 0 { Spacer(minLength: 0) }
                }
            }
            .frame(width: 22)
            Canvas { context, size in
                let labelHeight: CGFloat = 13
                let plot = CGRect(x: 0, y: labelHeight, width: size.width,
                                  height: max(0, size.height - labelHeight))
                if let image = waveform?.image {
                    context.draw(Image(decorative: image, scale: 1), in: plot)
                    for (index, label) in ["R", "G", "B"].enumerated() {
                        let tint: Color = [Color(red: 1, green: 0.36, blue: 0.34),
                                           Color(red: 0.38, green: 0.9, blue: 0.48),
                                           Color(red: 0.34, green: 0.62, blue: 1)][index]
                        let center = size.width * (CGFloat(index) + 0.5) / 3
                        context.draw(Text(label).font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(tint.opacity(0.86)), at: CGPoint(x: center, y: 7))
                    }
                }
                // Draw the graticule over the density image so the levels
                // remain readable at a glance without overpowering the trace.
                var grid = Path()
                for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                    let y = plot.minY + plot.height * fraction
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 0.6)
                var separators = Path()
                for fraction in [1.0 / 3, 2.0 / 3] {
                    separators.move(to: CGPoint(x: size.width * fraction, y: plot.minY))
                    separators.addLine(to: CGPoint(x: size.width * fraction, y: plot.maxY))
                }
                context.stroke(separators, with: .color(.white.opacity(0.16)), lineWidth: 0.7)
            }
        }
        .padding(6)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 3))
        .accessibilityElement()
        .accessibilityLabel("RGB waveform")
        .accessibilityValue(waveform == nil ? "No developed photograph" : "Red, green, and blue signal levels from zero to one hundred percent across the developed photograph")
    }
}

private func scopeGrid(context: inout GraphicsContext, size: CGSize) {
    var grid = Path()
    for fraction in [0.25, 0.5, 0.75] {
        grid.move(to: CGPoint(x: 0, y: size.height * fraction))
        grid.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
    }
    context.stroke(grid, with: .color(Theme.line), lineWidth: 0.5)
}

enum ScopeMode: String, CaseIterable, Sendable {
    case histogram = "Histogram", waveform = "Waveform", vectorscope = "Vectorscope", skin = "Skin Analysis"

    var symbol: String {
        switch self {
        case .histogram: "chart.bar.xaxis"
        case .waveform: "waveform.path"
        case .vectorscope: "circle.hexagongrid"
        case .skin: "person.crop.circle"
        }
    }

    var signalLabel: String {
        switch self {
        case .histogram, .waveform: "RGB"
        case .vectorscope: "Cb · Cr"
        case .skin: "FACE CHROMA"
        }
    }
}

struct ScopePanelView: View {
    let histogram: Histogram?
    let waveform: Waveform?
    let vectorscope: Vectorscope?
    let skinAnalysis: SkinAnalysis?
    var isUpdating = false
    var setScopeMode: (ScopeMode) -> Void = { _ in }
    var clippingEnabled = false
    var setClippingEnabled: (Bool) -> Void = { _ in }
    var falseColorEnabled = false
    var setFalseColorEnabled: (Bool) -> Void = { _ in }
    @AppStorage("scopeMode") private var mode = ScopeMode.histogram
    /// Dragged with the handle below the scope; remembered.
    @AppStorage("scopeHeight") private var height = ScopePanelView.defaultHeight
    /// The height while the handle is dragged, saved to `height` when it's let go.
    @State private var dragHeight: Double?
    /// Compact dock leaves room for adjustments; expanded is available for
    /// judging scope detail. The grabber still allows any intermediate size.
    static let heights = 88.0...420.0
    static let compactHeight = 120.0
    static let expandedHeight = 240.0
    static let defaultHeight = compactHeight

    var body: some View {
        VStack(spacing: StudioStyle.Space.compact) {
            scopeToolbar
            Group {
                VStack(spacing: StudioStyle.Space.compact) {
                    if falseColorEnabled { FalseColorLegend().padding(.horizontal, 3) }
                    switch mode {
                    case .histogram: HistogramView(histogram: histogram)
                    case .waveform: WaveformView(waveform: waveform)
                    case .vectorscope: VectorscopeView(vectorscope: vectorscope, skinOnly: false)
                    case .skin: VectorscopeView(vectorscope: vectorscope, skinOnly: true, skinAnalysis: skinAnalysis)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Scope view")
            .frame(height: Self.clamped(dragHeight ?? height))
            .overlay {
                if histogram == nil {
                    Text("No developed photograph").font(Theme.text(13, italic: true)).foregroundStyle(Theme.dim)
                }
            }
            resizeHandle
        }
        .onAppear { setScopeMode(mode) }
        .onChange(of: mode) { _, value in setScopeMode(value) }
    }

    private var scopeToolbar: some View {
        HStack {
                Menu {
                    ForEach(ScopeMode.allCases, id: \.self) { option in
                        Button {
                            mode = option
                        } label: {
                            if mode == option { Label(option.rawValue, systemImage: "checkmark") }
                            else { Text(option.rawValue) }
                        }
                    }
                } label: {
                    Label(mode.rawValue, systemImage: mode.symbol).lineLimit(1).minimumScaleFactor(0.8)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
                .accessibilityLabel("Scope view")
                if isUpdating {
                    ProgressView().controlSize(.mini).help("Updating scope for the current preview")
                }
                Button {
                    setClippingEnabled(!clippingEnabled)
                } label: {
                    Label("Clip", systemImage: clippingEnabled ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                        .lineLimit(1).minimumScaleFactor(0.8)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(clippingEnabled ? Color.blue : Color.secondary)
                }
                .buttonStyle(.borderless)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Clipping indicators")
                .help("Toggle clipping colors on the photograph. Red marks clipped highlights; blue marks near-black or crushed shadows.")
                Button {
                    setFalseColorEnabled(!falseColorEnabled)
                } label: {
                    Label("False Color", systemImage: "camera.filters")
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(falseColorEnabled ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("False Color")
                .help("Show a false-colour exposure map over the developed photograph.")
                Spacer()
                Text(mode.signalLabel)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity)
    }

    /// A grabber under the scope: drag to resize, double-click for the default height.
    private var resizeHandle: some View {
        Capsule().fill(Theme.track).frame(width: 32, height: 3)
            .frame(maxWidth: .infinity, minHeight: 8)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            // Measured in the window: the handle moves with the height, so in its own
            // coordinates the translation shrank as the scope grew (half speed, jitter).
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    dragHeight = Self.clamped(height + drag.translation.height)
                }
                .onEnded { drag in
                    height = Self.clamped(height + drag.translation.height)
                    dragHeight = nil
                })
            .onTapGesture(count: 2) { height = Self.defaultHeight }
            .help("Drag to resize the scope")
            .accessibilityLabel("Scope height")
            .accessibilityValue("\(Int(height)) points")
            .accessibilityAdjustableAction { direction in
                height = Self.clamped(height + (direction == .increment ? 20 : -20))
            }
    }

    /// Whole points keep the grid lines and plot edges from shimmering mid-drag.
    private static func clamped(_ height: Double) -> Double {
        min(max(height.rounded(), heights.lowerBound), heights.upperBound)
    }
}

private struct FalseColorLegend: View {
    private let stops: [(String, Color)] = [
        ("0", Color(red: 0.05, green: 0.03, blue: 0.2)), ("10", Color(red: 0.13, green: 0.18, blue: 0.75)),
        ("25", Color(red: 0, green: 0.64, blue: 0.87)), ("44", Color(red: 0, green: 0.7, blue: 0.35)),
        ("58", Color(red: 0.88, green: 0.82, blue: 0)), ("70", Color(red: 1, green: 0.52, blue: 0)),
        ("85", Color(red: 0.88, green: 0.13, blue: 0.11)), ("96", Color(red: 0.84, green: 0.13, blue: 0.77)),
        ("100", Color(white: 0.96))
    ]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(stops.enumerated()), id: \.offset) { _, stop in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(stop.1).frame(height: 5)
                    Text(stop.0).font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Text("IRE").font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("False color exposure scale in IRE")
    }
}

private struct VectorscopeView: View {
    let vectorscope: Vectorscope?
    let skinOnly: Bool
    var skinAnalysis: SkinAnalysis? = nil

    var body: some View {
        VStack(spacing: StudioStyle.Space.compact) {
            Canvas { context, size in
                let side = min(size.width, size.height)
                let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
                let center = CGPoint(x: origin.x + side / 2, y: origin.y + side / 2)
                // Use more of the scope well so the actual signal is easy to
                // read at the compact inspector size.
                let radius = side * 0.435
                let plot = CGRect(x: center.x - radius, y: center.y - radius,
                                  width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: plot), with: .color(StudioStyle.plot))

                let targets: [(String, Double, Double)] = [
                    ("R", 103, 0), ("Y", 167, 1.0 / 6), ("G", 241, 2.0 / 6),
                    ("C", 283, 3.0 / 6), ("B", 347, 4.0 / 6), ("M", 61, 5.0 / 6)
                ]
                for fraction in [0.25, 0.5, 0.75, 1.0] {
                    let rect = CGRect(x: center.x - radius * fraction, y: center.y - radius * fraction,
                                      width: radius * fraction * 2, height: radius * fraction * 2)
                    let opacity = fraction == 1 ? 0.48 : fraction == 0.75 ? 0.34 : 0.14
                    context.stroke(Path(ellipseIn: rect), with: .color(.primary.opacity(opacity)),
                                   lineWidth: fraction == 1 ? 0.9 : 0.65)
                }
                var cross = Path()
                cross.move(to: CGPoint(x: center.x - radius, y: center.y)); cross.addLine(to: CGPoint(x: center.x + radius, y: center.y))
                cross.move(to: CGPoint(x: center.x, y: center.y - radius)); cross.addLine(to: CGPoint(x: center.x, y: center.y + radius))
                context.stroke(cross, with: .color(.primary.opacity(0.28)), lineWidth: 0.8)

                for (label, degrees, hue) in targets {
                    let angle = degrees * .pi / 180
                    let tint = Color(hue: hue, saturation: 0.78, brightness: 0.96)
                    var spoke = Path()
                    spoke.move(to: center)
                    spoke.addLine(to: CGPoint(x: center.x + cos(angle) * radius,
                                              y: center.y - sin(angle) * radius))
                    context.stroke(spoke, with: .color(tint.opacity(0.11)), lineWidth: 0.65)

                    // The small outlined squares mark the broadcast 75% hue targets.
                    let targetCenter = CGPoint(x: center.x + cos(angle) * radius * 0.75,
                                               y: center.y - sin(angle) * radius * 0.75)
                    let targetSize = max(7, side * 0.035)
                    let targetRect = CGRect(x: targetCenter.x - targetSize / 2,
                                            y: targetCenter.y - targetSize / 2,
                                            width: targetSize, height: targetSize)
                    context.stroke(Path(roundedRect: targetRect, cornerRadius: 1.5),
                                   with: .color(tint.opacity(0.62)), lineWidth: 0.8)
                    let labelCenter = CGPoint(x: center.x + cos(angle) * radius * 1.13,
                                              y: center.y - sin(angle) * radius * 1.13)
                    context.draw(Text(label).font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(tint.opacity(0.88)), at: labelCenter)
                }

                guard let vectorscope else { return }
                let counts = skinOnly ? vectorscope.skinBins : vectorscope.bins
                guard counts.count == vectorscope.size * vectorscope.size,
                      (skinOnly ? vectorscope.skinSampleCount : vectorscope.sampleCount) > 0 else {
                    context.draw(Text("No chroma samples")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary), at: center)
                    return
                }
                let peak = Double(max(1, counts.max() ?? 1))
                for y in 0..<vectorscope.size {
                    for x in 0..<vectorscope.size {
                        let count = counts[y * vectorscope.size + x]
                        guard count > 0 else { continue }
                        let nx = Double(x) / Double(vectorscope.size - 1) * 2 - 1
                        let ny = Double(y) / Double(vectorscope.size - 1) * 2 - 1
                        guard nx * nx + ny * ny <= 1.05 else { continue }
                        let point = CGPoint(x: center.x + nx * radius, y: center.y + ny * radius)
                        // Fine, softly weighted points preserve sparse chroma
                        // detail without filling the whole gamut cloud into a
                        // hard-edged, opaque blob.
                        let dot = max(1.35, side / CGFloat(vectorscope.size) * 0.92)
                        let rect = CGRect(x: point.x - dot / 2, y: point.y - dot / 2, width: dot, height: dot)
                        let density = log1p(Double(count)) / log1p(peak)
                        let strength = min(0.62, 0.055 + pow(density, 0.72) * 0.48)
                        let angle = atan2(-ny, nx) * 180 / .pi
                        let tint = skinOnly
                            ? Color(hue: 0.105, saturation: 0.82, brightness: 1)
                            : Color(hue: vectorscopeHue(for: angle), saturation: 0.9, brightness: 1)
                        context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(strength)))
                    }
                }
                if skinOnly {
                    let angle = 123 * Double.pi / 180
                    var reference = Path()
                    reference.move(to: center)
                    reference.addLine(to: CGPoint(x: center.x + cos(angle) * radius, y: center.y - sin(angle) * radius))
                    context.stroke(reference, with: .color(StudioStyle.warning.opacity(0.95)),
                                   style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                }
            }
            if skinOnly, let skinAnalysis {
                HStack(spacing: 6) {
                    Text(skinAnalysis.status).font(.caption2.weight(.semibold))
                    Spacer()
                    Text(skinAnalysis.meanDeviationDegrees.map { String(format: "%+.1f°", $0) } ?? "—")
                    Text(String(format: "%.0f%% coverage", skinAnalysis.coveragePercent))
                }
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                Text("Face-box chroma estimate against the skin-tone reference line")
                    .font(.system(size: 9)).foregroundStyle(.tertiary).padding(.horizontal, 8)
            }
        }
        .padding(StudioStyle.Space.compact)
        .background(StudioStyle.panel, in: RoundedRectangle(cornerRadius: StudioStyle.Radius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: StudioStyle.Radius.panel)
                .strokeBorder(StudioStyle.outline, lineWidth: 0.8)
        }
        .accessibilityElement().accessibilityLabel(skinOnly ? "Skin tone vectorscope" : "Vectorscope")
        .accessibilityValue(skinOnly ? skinAnalysis?.status ?? "No developed photograph" : "Chroma distribution of the developed photograph")
    }
}

/// Maps Rec.709 Cb/Cr hue angles to the familiar R/Y/G/C/B/M signal colors.
private func vectorscopeHue(for angle: Double) -> Double {
    let anchors: [(angle: Double, hue: Double)] = [
        (49, 5.0 / 6), (103, 0), (175, 1.0 / 6),
        (230, 2.0 / 6), (283, 3.0 / 6), (355, 4.0 / 6), (409, 5.0 / 6)
    ]
    var value = angle.truncatingRemainder(dividingBy: 360)
    if value < 49 { value += 360 }
    for pair in zip(anchors, anchors.dropFirst()) where value <= pair.1.angle {
        let (start, end) = pair
        var endHue = end.hue
        if endHue < start.hue { endHue += 1 }
        let fraction = (value - start.angle) / (end.angle - start.angle)
        return (start.hue + (endHue - start.hue) * fraction).truncatingRemainder(dividingBy: 1)
    }
    return 0
}
