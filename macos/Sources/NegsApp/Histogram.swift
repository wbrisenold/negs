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
        ImageScopes.of(surface, crop: crop, maxSamples: maxSamples).histogram
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
    /// A small precomputed raster keeps drawing independent of photo size.
    let rgba: [UInt8]
    let sampleCount: Int

    init(width: Int = 1, red: [UInt32] = Array(repeating: 0, count: 256),
         green: [UInt32] = Array(repeating: 0, count: 256), blue: [UInt32] = Array(repeating: 0, count: 256)) {
        self.width = width; self.red = red; self.green = green; self.blue = blue
        sampleCount = Int(red.reduce(0, +))
        let peak = max(red.max() ?? 0, green.max() ?? 0, blue.max() ?? 0)
        let normalizer = log1p(Double(peak))
        var pixels = [UInt8](repeating: 0, count: width * 256 * 4)
        if peak > 0 {
            func intensity(_ count: UInt32) -> UInt8 {
                count == 0 ? 0 : UInt8((255 * (0.18 + 0.82 * log1p(Double(count)) / normalizer)).rounded())
            }
            for level in 0..<256 {
                for x in 0..<width {
                    let bin = level * width + x, pixel = ((255 - level) * width + x) * 4
                    pixels[pixel] = intensity(red[bin]); pixels[pixel + 1] = intensity(green[bin]); pixels[pixel + 2] = intensity(blue[bin])
                    pixels[pixel + 3] = max(pixels[pixel], pixels[pixel + 1], pixels[pixel + 2])
                }
            }
        }
        rgba = pixels
    }

    var image: CGImage? {
        guard sampleCount > 0, let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: 256, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
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

    static func of(_ surface: IOSurface, crop: CropSettings, rotation: Int = 0, maxSamples: Int = 1 << 20) -> ImageScopes {
        let size = CGSize(width: surface.width, height: surface.height)
        let area = crop.pixels(in: size)
        guard area.width >= 1, area.height >= 1, maxSamples > 0 else { return ImageScopes() }
        let width = Int(area.width), height = Int(area.height)
        // This also bounds very thin panoramas: a single common pixel stride
        // can exceed the budget when one of the dimensions is much shorter.
        let columns = min(width, maxSamples, max(1, Int((Double(maxSamples) * Double(width) / Double(height)).squareRoot())))
        let rows = min(height, max(1, maxSamples / columns))
        let turn = (rotation % 4 + 4) % 4
        let shownColumns = turn % 2 == 0 ? columns : rows
        let waveWidth = min(256, shownColumns)
        var red = [UInt32](repeating: 0, count: waveWidth * 256)
        var green = red, blue = red
        var histogram = Histogram()
        let vectorSize = 128
        var vectorBins = [UInt16](repeating: 0, count: vectorSize * vectorSize)
        var skinBins = vectorBins
        var skinAngles: Double = 0
        var skinSamples = 0
        var onTarget = 0, tooMagenta = 0, tooGreen = 0
        let sampleCount = columns * rows
        let faceBoxes: [CGRect] = autoreleasepool {
            let request = VNDetectFaceRectanglesRequest()
            do {
                try VNImageRequestHandler(ciImage: CIImage(ioSurface: surface), options: [:]).perform([request])
                return (request.results ?? []).map(\.boundingBox)
            } catch { return [] }
        }
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let rowBytes = surface.bytesPerRow
        // A straightened crop is in the turned frame: turn each sample back
        // to the photograph, as CropGeometry.turn(_:by: -angle, about:).
        let (sin, cos) = (Foundation.sin(-crop.angle * .pi / 180), Foundation.cos(-crop.angle * .pi / 180))
        let (cx, cy) = (size.width / 2, size.height / 2)
        for row in 0..<rows {
            for column in 0..<columns {
                let dx = area.minX + (Double(column) + 0.5) * area.width / Double(columns) - cx
                let dy = area.minY + (Double(row) + 0.5) * area.height / Double(rows) - cy
                let x = Int((cx + dx * cos - dy * sin).rounded(.down))
                let y = Int((cy + dx * sin + dy * cos).rounded(.down))
                guard x >= 0, x < surface.width, y >= 0, y < surface.height else { continue }
                let pixel = base + y * rowBytes + x * 4
                let (r, g, b) = (Int(pixel[2]), Int(pixel[1]), Int(pixel[0]))
                histogram.red[r] += 1; histogram.green[g] += 1; histogram.blue[b] += 1
                let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
                let luma = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
                let cb = (bf - luma) / (2 * (1 - 0.0722))
                let cr = (rf - luma) / (2 * (1 - 0.2126))
                let vx = min(vectorSize - 1, max(0, Int(((cb + 0.5) * Double(vectorSize - 1)).rounded())))
                let vy = min(vectorSize - 1, max(0, Int(((0.5 - cr) * Double(vectorSize - 1)).rounded())))
                vectorBins[vy * vectorSize + vx] = min(UInt16.max, vectorBins[vy * vectorSize + vx] &+ 1)
                // Skin estimate follows the studio vectorscope's hue analysis,
                // limited to a broad chroma envelope. It is not a semantic mask.
                let point = CGPoint(x: Double(x) / Double(surface.width), y: 1 - Double(y) / Double(surface.height))
                let withinFace = faceBoxes.contains { $0.insetBy(dx: -0.025, dy: -0.025).contains(point) }
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
                    skinBins[vy * vectorSize + vx] = min(UInt16.max, skinBins[vy * vectorSize + vx] &+ 1)
                }
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
            waveform: Waveform(width: waveWidth, red: red, green: green, blue: blue),
            vectorscope: Vectorscope(size: vectorSize, bins: vectorBins, skinBins: skinBins), skinAnalysis: analysis)
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
        .background(Color(white: 0.075), in: RoundedRectangle(cornerRadius: 6))
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
                    Text("\(level)").font(.system(size: 9, design: .monospaced)).foregroundStyle(Color.white.opacity(0.6))
                    if level != 0 { Spacer(minLength: 0) }
                }
            }
            .frame(width: 22)
            Canvas { context, size in
                scopeGrid(context: &context, size: size)
                if let image = waveform?.image {
                    context.draw(Image(decorative: image, scale: 1), in: CGRect(origin: .zero, size: size))
                }
            }
        }
        .padding(6)
        .background(Color(white: 0.075), in: RoundedRectangle(cornerRadius: 6))
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
    context.stroke(grid, with: .color(.white.opacity(0.09)), lineWidth: 0.5)
}

enum ScopeMode: String, CaseIterable {
    case histogram = "Histogram", waveform = "Waveform", vectorscope = "Vectorscope", skin = "Skin Analysis"
}

struct ScopePanelView: View {
    let histogram: Histogram?
    let waveform: Waveform?
    let vectorscope: Vectorscope?
    let skinAnalysis: SkinAnalysis?
    @AppStorage("scopeMode") private var mode = ScopeMode.histogram
    /// Dragged with the handle below the scope; remembered.
    @AppStorage("scopeHeight") private var height = ScopePanelView.defaultHeight
    /// The height while the handle is dragged, saved to `height` when it's let go.
    @State private var dragHeight: Double?
    /// Starts at the smallest height, leaving the room to the controls.
    static let heights = 88.0...420.0, defaultHeight = heights.lowerBound

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Picker("Scope", selection: $mode) {
                    ForEach(ScopeMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
                .accessibilityLabel("Scope view")
                Spacer()
                Text("RGB").font(.caption2).foregroundStyle(.secondary)
            }
            Group {
                switch mode {
                case .histogram: HistogramView(histogram: histogram)
                case .waveform: WaveformView(waveform: waveform)
                case .vectorscope: VectorscopeView(vectorscope: vectorscope, skinOnly: false)
                case .skin: VectorscopeView(vectorscope: vectorscope, skinOnly: true, skinAnalysis: skinAnalysis)
                }
            }
            .frame(height: Self.clamped(dragHeight ?? height))
            .overlay {
                if histogram == nil {
                    Text("No developed photograph").font(.caption).foregroundStyle(Color.white.opacity(0.6))
                }
            }
            resizeHandle
        }
    }

    /// A grabber under the scope: drag to resize, double-click for the default height.
    private var resizeHandle: some View {
        Capsule().fill(.tertiary).frame(width: 32, height: 4)
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

private struct VectorscopeView: View {
    let vectorscope: Vectorscope?
    let skinOnly: Bool
    var skinAnalysis: SkinAnalysis? = nil

    var body: some View {
        VStack(spacing: 5) {
            Canvas { context, size in
                let side = min(size.width, size.height)
                let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
                let center = CGPoint(x: origin.x + side / 2, y: origin.y + side / 2)
                let radius = side * 0.43
                for fraction in [0.33, 0.66, 1.0] {
                    let rect = CGRect(x: center.x - radius * fraction, y: center.y - radius * fraction,
                                      width: radius * fraction * 2, height: radius * fraction * 2)
                    context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(fraction == 1 ? 0.24 : 0.10)), lineWidth: 0.6)
                }
                var cross = Path()
                cross.move(to: CGPoint(x: center.x - radius, y: center.y)); cross.addLine(to: CGPoint(x: center.x + radius, y: center.y))
                cross.move(to: CGPoint(x: center.x, y: center.y - radius)); cross.addLine(to: CGPoint(x: center.x, y: center.y + radius))
                context.stroke(cross, with: .color(.white.opacity(0.14)), lineWidth: 0.6)
                guard let vectorscope else { return }
                let counts = skinOnly ? vectorscope.skinBins : vectorscope.bins
                let peak = Double(max(1, counts.max() ?? 1))
                for y in 0..<vectorscope.size {
                    for x in 0..<vectorscope.size {
                        let count = counts[y * vectorscope.size + x]
                        guard count > 0 else { continue }
                        let nx = Double(x) / Double(vectorscope.size - 1) * 2 - 1
                        let ny = Double(y) / Double(vectorscope.size - 1) * 2 - 1
                        guard nx * nx + ny * ny <= 1.05 else { continue }
                        let point = CGPoint(x: center.x + nx * radius, y: center.y + ny * radius)
                        let rect = CGRect(x: point.x, y: point.y, width: 1.5, height: 1.5)
                        let strength = min(0.95, 0.25 + log1p(Double(count)) / log1p(peak) * 0.7)
                        context.fill(Path(ellipseIn: rect), with: .color(skinOnly ? .orange.opacity(strength) : .cyan.opacity(strength)))
                    }
                }
                if skinOnly {
                    let angle = 123 * Double.pi / 180
                    var reference = Path()
                    reference.move(to: center)
                    reference.addLine(to: CGPoint(x: center.x + cos(angle) * radius, y: center.y - sin(angle) * radius))
                    context.stroke(reference, with: .color(.yellow.opacity(0.9)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
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
        .padding(6).background(Color(white: 0.075), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement().accessibilityLabel(skinOnly ? "Skin tone vectorscope" : "Vectorscope")
        .accessibilityValue(skinOnly ? skinAnalysis?.status ?? "No developed photograph" : "Chroma distribution of the developed photograph")
    }
}
