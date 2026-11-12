import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Adjustment: Identifiable {
    case slider(String, String, ClosedRange<Double>, Double)
    case toggle(String, String)
    case choice(String, String, [String])
    /// One lane (index) of an engine array that stays null until edited, so
    /// the film's grain preset from the catalog applies. B&W films have one
    /// emulsion: they show the lane under `bw`, or hide it when that is nil.
    case stockSlider(String, String, Int, ClosedRange<Double>, Double, bw: String?)
    /// A button that solves for parameters: title, help.
    case balancePrint(String, String)

    var id: String {
        switch self {
        case .slider(_, let path, _, _), .toggle(_, let path), .choice(_, let path, _): return path
        case .stockSlider(_, let path, let index, _, _, _): return "\(path).\(index)"
        case .balancePrint(let title, _): return title
        }
    }
}

enum InspectorSection: String, CaseIterable {
    case camera = "Camera", film = "Film", print = "Print", scan = "Scan & Color"
}

/// Prepare the photograph, develop the film, then finish the scan.
enum InspectorTab: String, CaseIterable {
    case prep = "Prep", adjust = "Adjust", lab = "Lab", output = "Output"
    // Read the previous release's saved tab and migrate it to the combined
    // adjustment workspace instead of dropping the user's editor location.
    case tone = "Tone", color = "Color", detail = "Detail"

    static var allCases: [InspectorTab] { [.prep, .adjust, .lab, .output] }

    var title: String {
        switch self {
        case .prep: "Input"
        case .adjust, .tone, .color, .detail: "Adjust"
        case .lab: "Film"
        case .output: "Output"
        }
    }

}

/// Keeps the adjustment inspector focused: show one kind of edit at a time.
private enum AdjustmentWorkspace: String, CaseIterable {
    case tone, color, detail
}

let prepToneControls: [Adjustment] = [
    .slider("Highlights", "prep.highlights", -180...100, 1),
    .slider("Shadows", "prep.shadows", -100...100, 1),
    .slider("Contrast", "prep.contrast", -100...100, 1),
    .slider("Lift", "prep.lift", -100...100, 1),
    .slider("Gain", "prep.gain", -100...100, 1)
]
let prepColorControls: [Adjustment] = [
    .slider("Color Boost", "prep.color_boost", -100...100, 1),
    .slider("Saturation", "prep.saturation", -100...100, 1)
]
let prepDetailControls: [Adjustment] = [
    .slider("Midtone Detail", "prep.midtone_detail", -100...100, 1)
]

struct AdjustmentGroup: Identifiable {
    let title: String
    let symbol: String
    let section: InspectorSection
    /// Switches the whole effect on and off from the group's header.
    var enable: String?
    /// How many of the leading controls the Lab shows without Show all
    /// controls; a group with none shows only then (or once it's changed).
    var basic = 0
    let controls: [Adjustment]
    var id: String { title }
}

let adjustmentGroups: [AdjustmentGroup] = [
    .init(title: "Lens Diffusion", symbol: "camera.filters", section: .camera, enable: "camera.diffusion_filter.active", basic: 2, controls: [
        .choice("Filter", "camera.diffusion_filter.filter_family", ["black_pro_mist", "glimmerglass", "pro_mist", "cinebloom"]),
        .slider("Strength", "camera.diffusion_filter.strength", 0...2, 0.01),
        .slider("Spatial scale", "camera.diffusion_filter.spatial_scale", 0.1...3, 0.01),
        .slider("Halo warmth", "camera.diffusion_filter.halo_warmth", -1.5...1.5, 0.01),
        .slider("Core intensity", "camera.diffusion_filter.core_intensity", 0...2, 0.01),
        .slider("Halo intensity", "camera.diffusion_filter.halo_intensity", 0...2, 0.01),
        .slider("Bloom intensity", "camera.diffusion_filter.bloom_intensity", 0...2, 0.01),
        .slider("Halo size", "camera.diffusion_filter.halo_size", 0.1...3, 0.01),
        .slider("Bloom size", "camera.diffusion_filter.bloom_size", 0.1...3, 0.01)
    ]),
    .init(title: "Film Curves", symbol: "chart.xyaxis.line", section: .film, enable: "film_render.density_curves_morph.active", basic: 1, controls: [
        .slider("Gamma", "film_render.density_curves_morph.gamma_factor", 0.5...2, 0.01),
        .slider("Fast gamma", "film_render.density_curves_morph.gamma_factor_fast", 0.5...2, 0.01),
        .slider("Slow gamma", "film_render.density_curves_morph.gamma_factor_slow", 0.5...2, 0.01),
        .slider("Red gamma", "film_render.density_curves_morph.gamma_factor_red", 0.5...2, 0.01),
        .slider("Green gamma", "film_render.density_curves_morph.gamma_factor_green", 0.5...2, 0.01),
        .slider("Blue gamma", "film_render.density_curves_morph.gamma_factor_blue", 0.5...2, 0.01),
        .slider("Developer exhaustion", "film_render.density_curves_morph.developer_exhaustion", 0...1, 0.01)
    ]),
    .init(title: "Grain", symbol: "circle.dotted", section: .film, enable: "film_render.grain.active", basic: 3, controls: [
        .stockSlider("Red granularity", "film_render.grain.rms_granularity", 0, 0...80, 0.1, bw: "Granularity"),
        .stockSlider("Green granularity", "film_render.grain.rms_granularity", 1, 0...80, 0.1, bw: nil),
        .stockSlider("Blue granularity", "film_render.grain.rms_granularity", 2, 0...80, 0.1, bw: nil),
        .stockSlider("Red uniformity", "film_render.grain.uniformity", 0, 0...1, 0.01, bw: "Uniformity"),
        .stockSlider("Green uniformity", "film_render.grain.uniformity", 1, 0...1, 0.01, bw: nil),
        .stockSlider("Blue uniformity", "film_render.grain.uniformity", 2, 0...1, 0.01, bw: nil),
        .stockSlider("Coarse grain size", "film_render.grain.particle_scale_sublayers", 0, 0.05...2, 0.01, bw: "Coarse grain size"),
        .stockSlider("Medium grain size", "film_render.grain.particle_scale_sublayers", 1, 0.05...2, 0.01, bw: "Medium grain size"),
        .stockSlider("Fine grain size", "film_render.grain.particle_scale_sublayers", 2, 0.05...2, 0.01, bw: "Fine grain size"),
        .slider("Dye clouds (µm)", "film_render.grain.blur_dye_clouds_um", 0...5, 0.01),
        .slider("Blur (px)", "film_render.grain.blur", 0...3, 0.01),
        .slider("Sharpen amount", "film_render.grain.mult_usm_amount", 0...3, 0.01),
        .slider("Sharpen radius (px)", "film_render.grain.mult_usm_sigma", 0...3, 0.01),
        .slider("Clump blur (µm)", "film_render.grain.micro_structure.0", 0...1, 0.01),
        .slider("Clump size (nm)", "film_render.grain.micro_structure.1", 0...100, 1)
    ]),
    .init(title: "Halation", symbol: "sun.haze", section: .film, enable: "film_render.halation.active", basic: 1, controls: [
        .slider("Amount", "film_render.halation.halation_amount", 0...3, 0.01),
        .slider("Spatial scale", "film_render.halation.halation_spatial_scale", 0.1...5, 0.01),
        .slider("Scatter amount", "film_render.halation.scatter_amount", 0...3, 0.01),
        .slider("Scatter scale", "film_render.halation.scatter_spatial_scale", 0.1...5, 0.01),
        .slider("Bounces", "film_render.halation.halation_n_bounces", 1...5, 1),
        .slider("Bounce decay", "film_render.halation.halation_bounce_decay", 0...1, 0.01)
    ]),
    .init(title: "DIR Couplers", symbol: "circle.hexagongrid", section: .film, enable: "film_render.dir_couplers.active", basic: 1, controls: [
        .slider("Amount", "film_render.dir_couplers.amount", 0...2, 0.01),
        .slider("Diffusion (µm)", "film_render.dir_couplers.diffusion_size_um", 0...100, 0.1),
        .slider("Tail (µm)", "film_render.dir_couplers.diffusion_tail_um", 0...400, 1),
        .slider("Tail weight", "film_render.dir_couplers.diffusion_tail_weight", 0...1, 0.01)
    ]),
    .init(title: "Film Base", symbol: "square.stack.3d.down.right", section: .film, enable: "film_render.base.active", basic: 1, controls: [
        .slider("Density", "film_render.base.scale", 0...2, 0.01),
        .slider("Tilt", "film_render.base.tilt", -1...1, 0.01),
        .slider("Cyan", "film_render.base.cyan", 0...2, 0.01),
        .slider("Magenta", "film_render.base.magenta", 0...2, 0.01),
        .slider("Yellow", "film_render.base.yellow", 0...2, 0.01)
    ]),
    .init(title: "Enlarger", symbol: "light.overhead.left", section: .print, basic: 4, controls: [
        .slider("Print exposure", "enlarger.print_exposure", 0.1...5, 0.01),
        .slider("Magenta shift", "enlarger.m_filter_shift", -50...50, 0.1),
        .slider("Yellow shift", "enlarger.y_filter_shift", -50...50, 0.1),
        .balancePrint("Balance Print", "Sets the magenta and yellow shifts so a mid-grey prints neutral with the current film, bases, paper and enlarger. Use it after changing the film base."),
        .toggle("Exposure compensation", "enlarger.print_exposure_compensation"),
        .slider("Preflash exposure", "enlarger.preflash_exposure", 0...0.5, 0.01),
        .slider("Preflash magenta", "enlarger.preflash_m_filter_shift", -50...50, 0.1),
        .slider("Preflash yellow", "enlarger.preflash_y_filter_shift", -50...50, 0.1)
    ]),
    .init(title: "Print Curves", symbol: "chart.xyaxis.line", section: .print, enable: "print_render.density_curves_morph.active", basic: 1, controls: [
        .slider("Gamma", "print_render.density_curves_morph.gamma_factor", 0.5...2, 0.01),
        .slider("Fast gamma", "print_render.density_curves_morph.gamma_factor_fast", 0.5...2, 0.01),
        .slider("Slow gamma", "print_render.density_curves_morph.gamma_factor_slow", 0.5...2, 0.01),
        .slider("Red gamma", "print_render.density_curves_morph.gamma_factor_red", 0.5...2, 0.01),
        .slider("Green gamma", "print_render.density_curves_morph.gamma_factor_green", 0.5...2, 0.01),
        .slider("Blue gamma", "print_render.density_curves_morph.gamma_factor_blue", 0.5...2, 0.01),
        .slider("Developer exhaustion", "print_render.density_curves_morph.developer_exhaustion", 0...1, 0.01)
    ]),
    .init(title: "Print Base", symbol: "square.stack.3d.down.right", section: .print, enable: "print_render.base.active", basic: 1, controls: [
        .slider("Density", "print_render.base.scale", 0...2, 0.01),
        .slider("Cyan", "print_render.base.cyan", 0...2, 0.01),
        .slider("Magenta", "print_render.base.magenta", 0...2, 0.01),
        .slider("Yellow", "print_render.base.yellow", 0...2, 0.01)
    ]),
    .init(title: "Glare", symbol: "light.max", section: .print, enable: "print_render.glare.active", basic: 1, controls: [
        .slider("Amount", "print_render.glare.percent", 0...0.2, 0.001),
        .slider("Roughness", "print_render.glare.roughness", 0...2, 0.01),
        .slider("Blur (px)", "print_render.glare.blur", 0...5, 0.01)
    ]),
    .init(title: "Scanner", symbol: "scanner", section: .scan, controls: [
        .slider("Lens blur (px)", "scanner.lens_blur", 0...5, 0.01),
        .slider("Unsharp radius (px)", "scanner.unsharp_mask.0", 0...3, 0.01),
        .slider("Unsharp amount", "scanner.unsharp_mask.1", 0...2, 0.01),
        .toggle("White correction", "scanner.white_correction"),
        .slider("White level", "scanner.white_level", 0.5...1, 0.01),
        .toggle("Black correction", "scanner.black_correction"),
        .slider("Black level", "scanner.black_level", 0...0.5, 0.01)
    ]),
    .init(title: "Color Management", symbol: "paintpalette", section: .scan, controls: [
        .choice("Output gamut", "io.output_gamut_compress.algorithm", ["off", "oklch", "oklrab", "cam16ucs", "aces_rgc"]),
        .choice("Input gamut", "io.input_gamut_compress.algorithm", ["off", "xy"]),
        .toggle("CAT16 adaptation", "settings.use_cat16"),
        .choice("Spectral upsampling", "settings.rgb_to_raw_method", ["hanatos2025", "arctic2026beta04", "mallett2019"])
    ])
]

struct AdjustmentControl: View {
    let model: EditorModel
    let adjustment: Adjustment

    var body: some View {
        switch adjustment {
        case .toggle(let title, let path):
            Toggle(title, isOn: model.toggle(path)).resettable(model, path).tooltip(ControlHelp.text(path))
        case .choice(let title, let path, let options):
            Picker(title, selection: model.choice(path)) {
                ForEach(options, id: \.self) { Text(optionTitle($0)).tag($0) }
            }.resettable(model, path).tooltip(ControlHelp.text(path))
        case .slider(let title, let path, let range, let step):
            SliderRow(model: model, title: title, path: path, range: range, step: step)
        case .stockSlider(let title, let path, let index, let range, let step, let bwTitle):
            if !model.filmIsBW || bwTitle != nil {
                LabeledSlider(title: model.filmIsBW ? bwTitle ?? title : title,
                              value: model.stockNumber(path, index, range: range, step: step), range: range, step: step,
                              defaultValue: model.stockDefault(path, index), modified: model.isStockModified(path, index),
                              reset: { model.resetStock(path, index) },
                              editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                              help: ControlHelp.text(path))
            }
        case .balancePrint(let title, let help):
            HStack {
                Spacer()
                Button(model.balancingPrint ? "Balancing…" : title) { model.balancePrint() }
                    .disabled(!model.canBalancePrint)
                    .help(help)
            }
        }
    }
}

struct SliderRow: View {
    let model: EditorModel
    let title: String
    let path: String
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        LabeledSlider(title: title, value: model.number(path, range: range, step: step), range: range, step: step,
                      defaultValue: model.defaultValue(path).double, modified: model.isModified(path),
                      reset: { model.resetValue(path) },
                      editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                      help: ControlHelp.text(path))
    }
}

/// The film frame as a stills format, which writes the frame's long edge in
/// mm; Custom shows the slider. A value no format has reads as Custom, so
/// presets and older edits need no setting of their own.
struct FilmFormatPicker: View {
    let model: EditorModel
    static let path = "camera.film_format_mm"
    static let range: ClosedRange<Double> = 4...120
    /// Long edges of the image area. 135 stays at the engine's 35 (not the
    /// gate's 36) so existing edits render as before; 6×4.5 and 6×6 share 56.
    static let formats: [(name: String, mm: Double)] = [
        ("110", 17), ("Half frame", 24), ("35 mm (135)", 35),
        ("6×4.5 / 6×6", 56), ("6×7", 70), ("6×9", 84), ("4×5", 120),
    ]
    static func format(mm: Double) -> String? { formats.first { abs($0.mm - mm) < 0.05 }?.name }
    private static let custom = "Custom"

    var body: some View {
        let mm = model.value(Self.path).double
        let custom = model.customFilmFormat || Self.format(mm: mm) == nil
        Picker("Film format", selection: Binding(get: { custom ? Self.custom : Self.format(mm: mm) ?? Self.custom }, set: { name in
            if let format = Self.formats.first(where: { $0.name == name }) {
                model.customFilmFormat = false
                model.set(Self.path, .number(format.mm))
            } else {
                model.customFilmFormat = true
            }
        })) {
            ForEach(Self.formats, id: \.name) { Text($0.name).tag($0.name) }
            Divider()
            Text("Custom…").tag(Self.custom)
        }
        .help(ControlHelp.text(Self.path) ?? "")
        if custom {
            SliderRow(model: model, title: "Long edge (mm)", path: Self.path, range: Self.range, step: 0.1)
        }
    }
}

/// A slider under its title and value. Clicking the value types one; off
/// its default, a button resets it.
struct LabeledSlider: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    /// Shown after the value, such as "%".
    var unit = ""
    let defaultValue: Double
    let modified: Bool
    let reset: () -> Void
    let editing: (Bool) -> Void
    /// The tooltip of the title and the slider.
    var help: String? = nil
    /// Optional slider-domain mapping; the value field and stored value retain
    /// their native units while a mapped track can place neutral at center.
    var trackValue: Binding<Double>? = nil
    var trackRange: ClosedRange<Double>? = nil
    var trackNeutral: Double? = nil

    @State private var typing = false
    private var decimals: Int { max(0, Int(-log10(step).rounded(.down))) }
    private var format: FloatingPointFormatStyle<Double> { .number.precision(.fractionLength(0...decimals)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                    .onTapGesture(count: 2) { reset() }
                    .tooltip(help)
                Spacer(minLength: 8)
                if modified {
                    Button { reset() } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).imageScale(.small)
                        .help("Reset to \(defaultValue.formatted(format))\(unit)")
                        .accessibilityLabel("Reset \(title)")
                }
                // A field only while typing, so the window never focuses one by default.
                if typing {
                    ValueField(title: title, value: value, decimals: decimals) { typing = false }
                        .frame(width: 64)
                } else {
                    Text("\(value.wrappedValue.formatted(format))\(unit)")
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(minWidth: 40, alignment: .trailing)
                        .contentShape(Rectangle())
                        .onTapGesture { typing = true }
                        .help("Click to type a value")
                }
            }
            ResettableSlider(title: title, value: trackValue ?? value, range: trackRange ?? range,
                             neutral: trackNeutral ?? defaultValue, editing: editing, reset: reset, toolTip: help)
        }
        .padding(.vertical, 1)
        .resettable(modified: modified, reset: reset)
        .accessibilityElement(children: .contain)
    }
}

/// A small slider that double-click or Option-click resets, as in Lightroom
/// and Capture One. AppKit, because NSSlider tracks the mouse itself and
/// SwiftUI's tap gestures on a Slider never fire. A double-click's first
/// click still moves the knob; the second resets.
struct ResettableSlider: NSViewRepresentable {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    /// The default: on macOS 26 the track fills from here to the knob, so a
    /// moved slider shows where it started.
    var neutral: Double? = nil
    let editing: (Bool) -> Void
    let reset: () -> Void
    /// AppKit's tooltip: SwiftUI's `.help` doesn't reach a hosted NSView.
    var toolTip: String? = nil

    func makeNSView(context: Context) -> NSSlider {
        let slider = Control()
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        let slider = slider as! Control
        slider.editing = editing
        slider.reset = reset
        slider.setAccessibilityLabel(title)
        if slider.toolTip != toolTip { slider.toolTip = toolTip }
        // SwiftUI applies its environment's control size after makeNSView.
        if slider.controlSize != .small { slider.controlSize = .small }
        if slider.minValue != range.lowerBound { slider.minValue = range.lowerBound }
        if slider.maxValue != range.upperBound { slider.maxValue = range.upperBound }
        // neutralValue needs the macOS 26 SDK, which release CI's Xcode 16
        // lacks; builds from it fill the track from the minimum, as before.
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            let neutral = min(max(neutral ?? range.lowerBound, range.lowerBound), range.upperBound)
            if slider.neutralValue != neutral { slider.neutralValue = neutral }
        }
        #endif
        slider.wanted = value.wrappedValue
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: ResettableSlider
        init(_ parent: ResettableSlider) { self.parent = parent }
        @objc func changed(_ slider: NSSlider) {
            parent.value.wrappedValue = slider.doubleValue
            // Read back the snapped value at once rather than waiting for
            // updateNSView, so the knob's target is current when a drag ends.
            (slider as! Control).wanted = parent.value.wrappedValue
        }
    }

    final class Control: NSSlider {
        var editing: (Bool) -> Void = { _ in }
        var reset: () -> Void = {}
        /// The model's value, snapped to the step, which the knob shows.
        var wanted = 0.0 {
            didSet { if !tracking { show() } }
        }
        private var tracking = false
        private var settling: Timer?

        private func show() {
            if doubleValue != wanted { doubleValue = wanted }
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 || event.modifierFlags.contains(.option) {
                reset()
                return
            }
            settling?.invalidate()
            // NSSlider tracks the drag inside mouseDown, so it returns when the mouse is released.
            tracking = true
            editing(true)
            super.mouseDown(with: event)
            tracking = false
            editing(false)
            show()
            // On macOS 26 the slider writes its last tracked value back about
            // 0.25 s after release, which undoes the step snap and a
            // double-click's reset. Keep showing the model's value until then.
            // A default-mode timer, so it never fires during a drag.
            let until = Date(timeIntervalSinceNow: 0.6)
            settling = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] timer in
                guard let self, Date() < until else { return timer.invalidate() }
                self.show()
            }
        }
    }
}

/// The number field shown while typing a slider's value. AppKit, because
/// SwiftUI's focus never reaches a field in the inspector column; the field
/// takes focus as it appears, which selects the value so typing replaces it.
private struct ValueField: NSViewRepresentable {
    let title: String
    @Binding var value: Double
    let decimals: Int
    let onEnd: () -> Void

    private var formatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = decimals
        formatter.isLenient = true
        return formatter
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusingTextField()
        field.controlSize = .small
        field.bezelStyle = .roundedBezel
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        field.alignment = .right
        field.setAccessibilityLabel(title)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil { field.stringValue = formatter.string(from: value as NSNumber) ?? "" }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ValueField
        private var cancelled = false
        init(_ parent: ValueField) { self.parent = parent }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            cancelled = true
            control.window?.makeFirstResponder(nil)
            return true
        }

        /// Return, Tab, clicking elsewhere and Escape all end here; only Escape discards the typing.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if !cancelled, let number = parent.formatter.number(from: field.stringValue) { parent.value = number.doubleValue }
            parent.onEnd()
        }
    }
}

/// Takes focus as it appears, selecting its text, in the inspector column
/// where SwiftUI focus doesn’t reach.
final class FocusingTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}

/// Image Size, in the Lab between the film and the camera: the photograph's
/// resolution before the film develops it. Reads only its own parameters,
/// the crop and the source's size, so other edits don't redraw it.
struct ImageSizeSection: View {
    let model: EditorModel
    @State private var fieldError: String?

    var body: some View {
        let params: JSONValue = .object(["io": .object(["photo_long_side_px": model.value(ImageSize.targetPath)])])
        let mode = ImageSize.mode(of: params)
        let source = model.sourceSize
        let working = source == .zero ? CGSize.zero : ImageSize.working(source: source, params: params, crop: model.crop)
        let photograph = model.crop.size(of: working)
        Section {
            Picker("Size", selection: Binding(get: { mode }, set: { fieldError = nil; model.chooseImageSize($0) })) {
                Text("Original").tag(ImageSize.Mode.original)
                Text("Longest side").tag(ImageSize.Mode.longestSide)
            }
            .help("Original develops the photograph’s own pixels. Longest side enlarges or reduces it first, so the cropped photograph has that many pixels on its longest side.")
            if mode == .longestSide {
                LabeledContent("Longest side") {
                    HStack(spacing: 4) {
                        PixelField(title: "Longest side", value: ImageSize.target(of: params) ?? 0) { pixels in
                            fieldError = model.setLongestSide(pixels)
                            return fieldError == nil
                        }
                        .frame(width: 72)
                        Text("px").foregroundStyle(.secondary)
                    }
                }
                .help("The cropped photograph’s longest side, before any border. Exports can still be reduced in the save panel.")
                if let fieldError {
                    Text(fieldError).font(.caption).foregroundStyle(.red)
                }
            }
            LabeledContent("Photograph") {
                // Verbatim, so pixel counts read like the status bar's, without grouping.
                Text(verbatim: photograph == .zero ? "—" : "\(Int(photograph.width)) × \(Int(photograph.height)) · \(ImageSize.megapixels(photograph)) MP")
                    .monospacedDigit()
            }
            .help("The exported photograph, cropped, before rotation, the border, and any export size.")
            if ImageSize.exceedsLimit(working: working, source: source) {
                Label(ImageSize.limitMessage(working: working), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            } else if model.previewScale < 1, model.image != nil {
                Text("The preview shows \(EditorModel.percent(model.previewScale)) of these pixels. Exports develop all of them; inspect grain in an exported file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("Image Size") } footer: {
            Text("Resizes before film simulation, including halation and grain.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A whole number of pixels, committed on Return or when focus leaves. An
/// invalid value stays in the field until corrected; Escape restores the
/// current one. AppKit, like `ValueField`, so the inspector column can focus it.
private struct PixelField: NSViewRepresentable {
    let title: String
    let value: Int
    /// Applies a typed value; false keeps the typing for correction.
    let commit: (Int) -> Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.controlSize = .small
        field.bezelStyle = .roundedBezel
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        field.alignment = .right
        field.setAccessibilityLabel(title)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, !context.coordinator.rejected { field.stringValue = "\(value)" }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PixelField
        /// The field holds a value that wasn't applied.
        var rejected = false
        init(_ parent: PixelField) { self.parent = parent }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            rejected = false
            (control as? NSTextField)?.stringValue = "\(parent.value)"
            control.window?.makeFirstResponder(nil)
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
            guard text != "\(parent.value)" || rejected else { return }
            rejected = !parent.commit(Int(text) ?? -1)
        }
    }
}

extension View {
    /// A native tooltip, or none.
    @ViewBuilder func tooltip(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}

private extension View {
    func resettable(_ model: EditorModel, _ path: String) -> some View {
        resettable(modified: model.isModified(path)) { model.resetValue(path) }
    }
    func resettable(modified: Bool, reset: @escaping () -> Void) -> some View {
        contextMenu {
            Button("Reset to Default", action: reset).disabled(!modified)
        }
    }
}

struct AdjustmentInspector: View {
    let model: EditorModel
    @AppStorage("expandedAdjustments") private var expanded = "Enlarger"
    @AppStorage("inspectorTab") private var tab = InspectorTab.prep
    @AppStorage("adjustmentWorkspace") private var adjustmentWorkspace = AdjustmentWorkspace.tone.rawValue
    @AppStorage("inspectorScopesVisible") private var scopesVisible = true
    @AppStorage("scopeHeight") private var scopeHeight = ScopePanelView.defaultHeight
    @AppStorage("inspectorLayoutRevision") private var inspectorLayoutRevision = 0
    @State private var formSessionID = UUID()
    /// Off, the Lab shows the few controls most photographs need, plus any
    /// setting that is off its default.
    @AppStorage("labAllControls") private var allControls = false

    var body: some View {
        // Scopes stay in a compact dock; each tab owns the controls for that
        // stage of the photo workflow.
        VStack(spacing: 0) {
            HStack {
                Text("SCOPES").font(.caption2.weight(.semibold)).tracking(0.7).foregroundStyle(.secondary)
                Spacer()
                if scopesVisible {
                    Button(scopeHeight > 144 ? "Compact" : "Expand") {
                        scopeHeight = scopeHeight > 144 ? ScopePanelView.compactHeight : ScopePanelView.expandedHeight
                    }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    .help("Resize the scope dock for control space or detailed inspection")
                }
                Button(scopesVisible ? "Hide" : "Show") { scopesVisible.toggle() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, StudioStyle.Space.standard)
            .padding(.top, StudioStyle.Space.compact)
            if scopesVisible {
                ScopePanelView(histogram: model.histogram, waveform: model.waveform,
                               vectorscope: model.vectorscope, skinAnalysis: model.skinAnalysis,
                               clippingEnabled: model.clippingOverlayEnabled,
                               setClippingEnabled: { model.clippingOverlayEnabled = $0 },
                               falseColorEnabled: model.falseColorEnabled,
                               setFalseColorEnabled: { model.falseColorEnabled = $0 })
                    .padding(.horizontal, StudioStyle.Space.standard)
            }
            HStack(spacing: 3) {
                ForEach(InspectorTab.allCases, id: \.self) { item in
                    Button { tab = item } label: {
                        Text(item.title)
                            .font(.system(size: 10, weight: tab == item ? .semibold : .regular))
                            .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .foregroundStyle(tab == item ? Color.primary : Color.secondary)
                        .background(tab == item ? StudioStyle.panel : .clear,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show \(item.title.lowercased()) controls")
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                }
            }
            .padding(3)
            .background(StudioStyle.plot.opacity(0.8), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.horizontal, StudioStyle.Space.standard)
            .padding(.bottom, StudioStyle.Space.compact)
            Divider()
            Form {
                switch tab {
                case .prep: prep
                case .adjust, .tone, .color, .detail: adjust
                case .lab: lab
                case .output: output
                }
            }
            .formStyle(.grouped)
            // Each workflow tab has its own top-level position; do not keep
            // a stale scroll offset when moving from Input to Film/Output.
            .id("\(tab.rawValue)-\(formSessionID)")
            // Pinned below the sections, like the Reset Adjustments button in Photos.
            Button(action: model.reset) {
                Text("Reset Adjustments").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle).controlSize(.small)
            .help("Restore defaults on all tabs while keeping the film, paper, rotation, crop, border, and Image Size. You can undo this.")
            .padding(.horizontal, StudioStyle.Space.standard)
            .padding(.vertical, StudioStyle.Space.compact)
        }
        .disabled(!model.hasCatalog)
        .preferredColorScheme(.dark)
        .background(StudioStyle.window)
        .onAppear {
            switch tab {
            case .tone, .color, .detail: tab = .adjust
            default: break
            }
            // The previous layout persisted a large scope above all controls.
            // Start the new workflow compact once; users can resize it any time.
            guard inspectorLayoutRevision < 1 else { return }
            scopeHeight = min(scopeHeight, ScopePanelView.compactHeight)
            inspectorLayoutRevision = 1
        }
    }

    @ViewBuilder private var prep: some View {
        // Read the source's colour before balancing or changing exposure.
        if !model.isRaw {
            Section("Input") { inputColour }
        } else {
            Section("Input Transform") { referentInputTransform }
        }
        if !model.isRaw,
           model.value("io.input_interpretation.mode").string == "assume",
           model.value("io.input_interpretation.color_space").string == "ARRI LogC3 / AWG3" {
            Section("Input Transform") { referentInputTransform }
        }
        if model.isRaw {
            Section("White Balance") {
                Text("White balance applies before the film process.")
                    .font(.caption).foregroundStyle(.secondary)
                control(.choice("White balance", "io.raw_white_balance.mode", ["as_shot", "daylight", "tungsten", "custom"]))
                HStack(spacing: 8) {
                    Button("Auto WB", systemImage: "wand.and.stars") { model.autoWhiteBalance() }
                        .disabled(!model.isRaw || model.source == nil)
                        .help("Estimate RAW white balance with spectral color references (ITCWB). Uses a reduced sensor RAW decode; frames without enough varied color report why they could not be estimated.")
                    Button("WB to Skin", systemImage: "person.crop.circle.badge.checkmark") { model.whiteBalanceToSkin() }
                        .disabled(!model.isRaw || (model.skinAnalysis?.coveragePercent ?? 0) < 5)
                        .help("Make one conservative RAW tint adjustment from the skin vectorscope estimate.")
                }
                if model.value("io.raw_white_balance.mode").string == "custom" {
                    Picker("Adaptation", selection: Binding(
                        get: {
                            let method = model.value("io.raw_white_balance.method").string
                            return method.isEmpty ? "cat02" : method
                        },
                        set: { model.set("io.raw_white_balance.method", .string($0)) },
                    )) {
                        Text("CAT02").tag("cat02")
                        Text("XYZ Scaling").tag("xyz_scaling")
                    }
                    .pickerStyle(.menu)
                    .help("Choose chromatic adaptation. XYZ Scaling directly scales linear CIE XYZ channels from the source white to D65.")
                    WhiteBalanceTemperatureSlider(model: model)
                    WhiteBalanceTintSlider(model: model)
                }
                if let skin = model.skinAnalysis {
                    HStack {
                        Text("Skin scope").foregroundStyle(.secondary)
                        Spacer()
                        Text(skin.status)
                        if let deviation = skin.meanDeviationDegrees {
                            Text(String(format: "%+.1f°", deviation)).monospacedDigit()
                        }
                    }
                    .font(.caption2)
                }
            }
        }
    }

    @ViewBuilder private var referentInputTransform: some View {
        Toggle("Referent LogC3 → Rec.709", isOn: model.toggle("io.referent_logc3_enabled"))
            .help("Uses Referent's LogC3/AWG3 color mapping before the film look while preserving scene luminance. The LUT's Rec.709 tone curve is not stacked onto the film rendering.")
        if model.value("io.referent_logc3_enabled").bool {
            HStack {
                Text(URL(fileURLWithPath: model.value("io.referent_logc3_path").string).lastPathComponent)
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Button("Choose .cube…") { chooseReferentCube() }
            }
            .font(.caption)
            Text("Color mapping only. Scene exposure and tone remain with the film pipeline.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var adjust: some View {
        Section {
            Picker("Adjustment group", selection: $adjustmentWorkspace) {
                Text("Tone").tag(AdjustmentWorkspace.tone.rawValue)
                Text("Color").tag(AdjustmentWorkspace.color.rawValue)
                Text("Detail").tag(AdjustmentWorkspace.detail.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Adjustment group")
        }
        switch AdjustmentWorkspace(rawValue: adjustmentWorkspace) ?? .tone {
        case .tone:
            Section("Light") {
                Toggle(model.isRaw ? "Match camera brightness" : "Match original brightness",
                       isOn: Binding(get: { model.matchesBrightness }, set: model.setMatchesBrightness))
                    .help(model.isRaw
                          ? "Develops the RAW about as bright as the camera’s own preview, and keeps it there when you change film, paper or a preset. Exposure adds to it."
                          : "Develops the photograph about as bright as the file itself, and keeps it there when you change film, paper or a preset. Exposure adds to it.")
                LabeledSlider(title: "Exposure", value: model.exposureOffset, range: model.exposureOffsetRange, step: 0.05, unit: " EV",
                              defaultValue: 0, modified: model.exposureOffsetModified, reset: model.resetExposureOffset,
                              editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                              help: model.matchesBrightness
                                  ? "Brighter or darker than the match, in stops. It stays when the match changes with the film, paper or a preset."
                                  : "Brightens or darkens the scene before the film, in stops. Unlike Negative exposure, the print doesn’t make up for it.")
                if let note = model.brightnessMatchNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                if !model.brightnessMatchActive || model.isModified("camera.auto_exposure") || model.isModified("camera.auto_exposure_method") {
                    Toggle("Auto exposure", isOn: model.toggle("camera.auto_exposure"))
                        .help("Meters the photograph and exposes the film so the metered area lands on mid-grey, as a camera's meter does. Exposure adds to it.")
                    if model.value("camera.auto_exposure").bool {
                        control(.choice("Metering", "camera.auto_exposure_method", ["average", "median", "center_weighted", "partial", "matrix", "multi_zone", "highlight_weighted"]))
                    }
                }
                if model.isRaw {
                    control(.slider("Global Tone", "prep.global_tone", -100...100, 1))
                        .help("At zero the control is neutral. Positive values lift shadows and midtones; negative values lower the overall tone, including highlights, before the film process.")
                }
                ForEach(prepToneControls) { control($0) }
                Text("Expand")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                Toggle("Enable Expand", isOn: model.toggle("post.film_expand.enabled"))
                    .help("Remap the black and white output points before the film look.")
                Group {
                    LabeledSlider(title: "Black Point",
                                  value: Binding(get: { model.value("post.film_expand.blacks").double },
                                                 set: { model.set("post.film_expand.blacks", .number($0)) }),
                                  range: -20...30, step: 0.1, unit: "%", defaultValue: 0,
                                  modified: model.isModified("post.film_expand.blacks"),
                                  reset: { model.resetValue("post.film_expand.blacks") },
                                  editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                                  help: "Move right to raise the black point and deepen shadows. Move left to lower it and retain shadow detail.")
                    LabeledSlider(title: "White Point",
                                  value: Binding(get: { model.value("post.film_expand.whites").double },
                                                 set: { model.set("post.film_expand.whites", .number($0)) }),
                                  range: 30...120, step: 0.1, unit: "%", defaultValue: 100,
                                  modified: model.isModified("post.film_expand.whites"),
                                  reset: { model.resetValue("post.film_expand.whites") },
                                  editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                                  help: "Move right to raise the white point and hold back highlights. Move left to lower it and brighten highlights.")
                    Picker("Color Mode", selection: Binding(
                        get: { model.value("post.film_expand.mode").string.isEmpty ? "Luminance" : model.value("post.film_expand.mode").string },
                        set: { mode in
                            model.setInteractive("post.film_expand.mode", .string(mode), action: "Change Expand Mode")
                            model.setInteractive("post.film_expand.impact", .number(1), action: "Change Expand Mode")
                        }
                    )) {
                        Text("Luminance").tag("Luminance")
                        Text("RGB").tag("RGB")
                    }
                    .help("Apply the range remap to luminance while preserving hue, or to each RGB channel.")
                }
                .disabled(!model.value("post.film_expand.enabled").bool)
            }
        case .color:
            Section("Color Balance") {
                ForEach(prepColorControls) { control($0) }
            }
            Section("Color Separation") {
                Text("Applied after the film scan. This is an inferred approximation of published controls, not a reconstruction of the unavailable DCTL.")
                    .font(.caption).foregroundStyle(.secondary)
                control(.slider("Separation strength", "post.color_separation.strength", 0...100, 1))
            }
            Section("Hue Selection") {
                HStack {
                    ColorPicker("Hue color", selection: colorSeparationTargetHueColor, supportsOpacity: false)
                        .help("Choose the hue used by Color Separation.")
                    Button("Sample", systemImage: "eyedropper") {
                        NSColorSampler().show { sampledColor in
                            guard let sampledColor else { return }
                            colorSeparationTargetHueColor.wrappedValue = Color(nsColor: sampledColor)
                        }
                    }
                    .help("Sample a color from the photo or anywhere else on screen; only its hue is used.")
                }
                control(.slider("Hue angle", "post.color_separation.target_hue", 0...360, 1))
                control(.slider("Complementary hue", "post.color_separation.complementary_hue", 0...360, 1))
                control(.slider("High-saturation threshold", "post.color_separation.target_saturation", 0...100, 1))
            }
            Section("Mask & Method") {
                control(.slider("Luminance mask", "post.color_separation.luminance_mask", -100...100, 1))
                control(.slider("Neutral protection", "post.color_separation.neutral_protection", 0...100, 1))
                control(.slider("Method blend", "post.color_separation.method", 0...100, 1))
                Toggle("Color wash", isOn: model.toggle("post.color_separation.color_wash"))
                    .help("Blend the target hue band toward the selected hue instead of separating it from its complement.")
            }
        case .detail:
            Section("Detail") { ForEach(prepDetailControls) { control($0) } }
            if model.isRaw, model.lensCorrectionSupported {
                Section("Lens") {
                    control(.toggle("Lens corrections", EditorModel.lensCorrectionPath))
                        .help("Corrects distortion and vignetting with the data the camera recorded for its lens.")
                }
            }
        }
    }

    @ViewBuilder private var filmStock: some View {
        Section("Film & Paper") {
            // Preview grids, or the plain menus when Settings turns them off.
            if model.previews.enabled {
                StockFoldout(model: model, paper: false)
            } else {
                Picker("Film", selection: Binding(get: { model.film }, set: { model.chooseFilm(StockFoldout.stockID(tag: $0)) })) {
                    // The favourites first, starred; each stays in its group too. Their
                    // own tags leave the selection on the group's entry, so the closed
                    // menu shows the plain name.
                    Section {
                        ForEach(model.previews.favorites(in: model.films, paper: false)) { Label($0.name, systemImage: "star.fill").tag(StockFoldout.favoriteID($0.id)) }
                    }
                    ForEach(model.filmGroups) { group in
                        Section(group.title) { ForEach(group.stocks) { Text($0.name).tag($0.id) } }
                    }
                }
                .help(ControlHelp.film)
            }
            developmentTime(stock: model.films.first { $0.id == model.film }, path: "film_render.development_time", label: "Development",
                            help: "How long the film develops, from the times the stock was measured at. Longer gives more density and contrast.")
            if !model.value("io.scan_film").bool {
                Divider()
                if model.previews.enabled {
                    StockFoldout(model: model, paper: true)
                } else {
                    Picker("Paper", selection: Binding(get: { model.paper }, set: { model.choosePaper(StockFoldout.stockID(tag: $0)) })) {
                        Section {
                            ForEach(model.previews.favorites(in: model.papers, paper: true)) { Label($0.name, systemImage: "star.fill").tag(StockFoldout.favoriteID($0.id)) }
                        }
                        ForEach(model.paperGroups) { group in
                            Section(group.title) { ForEach(group.stocks) { Text($0.name).tag($0.id) } }
                        }
                    }
                    .help(ControlHelp.paper)
                }
                developmentTime(stock: model.papers.first { $0.id == model.paper }, path: "print_render.development_time", label: "Print development",
                                help: "How long the paper develops, from the times it was measured at. Longer gives deeper blacks and more contrast.")
            }
        }
    }

    @ViewBuilder private var lab: some View {
        let scanning = model.value("io.scan_film").bool
        let silverRetentionPath = "film_render.silver_retention"
        let silverRetentionHelp = "Keystone-style bleach bypass after the scan. 0 is bypass and 80 matches Keystone’s maximum: saturation falls, shadows multiply, and highlights screen."
        filmStock
        Section("Workflow") {
            Toggle("Advanced controls", isOn: $allControls)
                .help("Show every Film and Print control. Off, common controls and anything changed from its default remain visible.")
        }
        Section("Negative") {
            let path = "camera.exposure_compensation_ev"
            LabeledSlider(title: "Negative exposure", value: model.number(path, range: -5...5, step: 0.1),
                          range: -5...5, step: 0.1, unit: " EV",
                          defaultValue: model.defaultValue(path).double, modified: model.isModified(path),
                          reset: { model.resetValue(path) },
                          editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                          help: ControlHelp.text(path))
            FilmFormatPicker(model: model)
            if shows("camera.lens_blur_um") { control(.slider("Lens blur (µm)", "camera.lens_blur_um", 0...100, 0.1)) }
            groups(.camera)
        }
        Section("Film Effects") {
            LabeledSlider(
                title: "Silver Retention",
                value: Binding(
                    get: { model.value(silverRetentionPath).double * 80 },
                    set: { model.set(silverRetentionPath, .number($0 / 80)) }
                ),
                range: 0...80, step: 1,
                defaultValue: model.defaultValue(silverRetentionPath).double * 80,
                modified: model.isModified(silverRetentionPath),
                reset: { model.resetValue(silverRetentionPath) },
                editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                help: silverRetentionHelp
            )
            groups(.film)
        }
        Section {
            // Here rather than beside the stocks: few photographs want it.
            if allControls || scanning {
                Toggle("Scan film directly", isOn: model.toggle("io.scan_film"))
                    .help("Skip printing and scan the developed film, as for slides.")
            }
            groups(.print).disabled(scanning)
        } header: { Text("Print") } footer: {
            if scanning { Text("Printing and the paper are skipped while scanning film directly.").font(.caption).foregroundStyle(.secondary) }
        }
        let outputChanged = model.previewSpace != SaveSettings.colorSpaces[0] || model.isModified("io.output_cctf_encoding")
        if allControls || outputChanged || adjustmentGroups.contains(where: { $0.section == .scan && shows($0) }) {
            Section("Scan") {
                groups(.scan)
                if allControls || outputChanged {
                    disclosure("Output", symbol: "square.and.arrow.down.on.square") {
                        Picker("Colour space", selection: Binding(get: { model.previewSpace }, set: model.choosePreviewSpace)) {
                            ForEach(SaveSettings.colorSpaces, id: \.self) { Text($0).tag($0) }
                        }
                        .help("The preview develops in this colour space, so it shows the colours an export in it can hold. Save and Export use it next, and switch it when you pick another.")
                        Toggle("Encode with the colour space’s curve", isOn: model.toggle("io.output_cctf_encoding"))
                            .help("Off writes linear values, for further processing.")
                    }
                }
            }
        }
    }

    /// Whether the Lab shows a control that isn't one of the basics.
    private func shows(_ path: String) -> Bool { allControls || model.isModified(path) }
    private func isModified(_ adjustment: Adjustment) -> Bool {
        switch adjustment {
        case .slider(_, let path, _, _), .toggle(_, let path), .choice(_, let path, _): model.isModified(path)
        case .stockSlider(_, let path, let index, _, _, _): model.isStockModified(path, index)
        case .balancePrint: false
        }
    }
    /// Whether the Lab shows a group: it has basics, or something in it changed.
    private func shows(_ group: AdjustmentGroup) -> Bool {
        allControls || group.basic > 0 || group.enable.map(model.isModified) == true || group.controls.contains(where: isModified)
    }

    /// How a non-RAW photograph's values are read: automatically from its
    /// profile and tags, as an assumed colour space, or (Manual) by the input
    /// colour space and curve, as Negs 0.8 read every file.
    @ViewBuilder private var inputColour: some View {
        disclosure("Input Colour", symbol: "eyedropper") {
            Picker("Read as", selection: model.inputInterpretation) {
                Text("Automatic").tag("auto")
                Section("Assume") {
                    ForEach(["sRGB", "Display P3", "Adobe RGB (1998)", "ProPhoto RGB", "ITU-R BT.2020", "ARRI LogC3 / AWG3"], id: \.self) { Text($0).tag("assume:" + $0) }
                }
                Text("Manual").tag("manual")
            }
            .help("Automatic reads the embedded profile or tags; untagged files are read as sRGB. Assume overrides them. Manual uses the colour space and curve below, as Negs 0.8 did.")
            switch model.value("io.input_interpretation.mode").string {
            case "assume":
                if model.value("io.input_interpretation.color_space").string == "ARRI LogC3 / AWG3" {
                    Text("Decodes LogC3 EI 800 to scene-linear AWG3, then converts to linear sRGB before the film response.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Toggle("Linear values", isOn: model.toggle("io.input_interpretation.linear"))
                        .tooltip(ControlHelp.text("io.input_interpretation.linear"))
                }
            case "manual":
                control(.choice("Colour space", "io.input_color_space", ["sRGB", "Display P3", "Adobe RGB (1998)", "ProPhoto RGB", "ITU-R BT.2020", "ACES2065-1", "ACEScg"]))
                Toggle("Decode the curve", isOn: model.toggle("io.input_cctf_decoding"))
                    .tooltip(ControlHelp.text("io.input_cctf_decoding"))
            default: EmptyView()
            }
            let colour = model.inputColour
            if colour != .null {
                VStack(alignment: .leading, spacing: 2) {
                    Text(colour["summary"].string)
                    if colour["automatic"].string != colour["summary"].string { Text("Automatic: \(colour["automatic"].string)") }
                    if !colour["warning"].string.isEmpty { Text(colour["warning"].string).foregroundStyle(.orange) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The size and frame of the finished photograph. Tone and colour edits
    /// live in Prep, before the film, where nothing has clipped yet.
    @ViewBuilder private var output: some View {
        ImageSizeSection(model: model)
        Section("Levels") {
            control(.slider("White point", "post.whites", -100...100, 1))
                .help("Set the output white point. Lower it to retain bright detail; raise it to make highlights reach white sooner.")
            control(.slider("Black point", "post.blacks", -100...100, 1))
                .help("Set the output black point. Raise it to lift shadow detail; lower it to deepen blacks.")
        }
        Section("Border") {
            Toggle("Add border", isOn: model.border(\.enabled))
                .help("Frames the photograph in a mat or a film frame. The preview always shows it; Include in export decides whether files get it.")
            Group {
                let photo = model.photoSize == .zero ? nil : model.photoSize
                BorderStylePicker(selection: model.border(\.style), photo: photo, colors: (model.border.color, model.border.lineColor))
                if let photo, !BorderStyle.film35.fits(photo) {
                    Text("35mm needs a 3:2 or 3:4 photograph. This one is \(Self.ratio(photo)); crop it to 3:2 or 4:3 to use it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                borderControls
                Toggle("Extend to 3:4 for Instagram", isOn: model.border(\.instagram))
                    .help("Adds white above and below, or at the sides, so Instagram shows the whole photograph in a 3:4 portrait post.")
                Toggle("Include in export", isOn: model.border(\.export))
                    .help("Adds the border to exported photographs and saved previews.")
            }
            .disabled(!model.border.enabled)
        }
    }

    private func chooseReferentCube() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.set("io.referent_logc3_path", .string(url.path))
        }
    }

    /// The chosen style's width and colours. Solid and Keyline share the
    /// mat; the film frame's width adds black around it.
    @ViewBuilder private var borderControls: some View {
        switch model.border.style {
        case .solid, .keyline:
            let keyline = model.border.style == .keyline
            borderSlider("Width", \.width, 0...15, step: 0.1, help: "The mat’s width, in percent of the photograph’s long edge.")
            if keyline { borderSlider("Line width", \.line, 0.05...2, step: 0.05, help: "The line’s width, in percent of the photograph’s long edge.") }
            ColorPicker("Color", selection: model.borderColor(\.color), supportsOpacity: false)
                .help("The mat’s colour.")
            if keyline {
                ColorPicker("Line color", selection: model.borderColor(\.lineColor), supportsOpacity: false)
                    .help("The line’s colour.")
            }
        case .film:
            borderSlider("Width", \.filmWidth, 0...15, step: 0.1, help: "Adds black around the film frame, in percent of the photograph’s long edge.")
        case .film35:
            EmptyView()
        }
    }

    /// A border width in percent of the photograph's long edge.
    private func borderSlider(_ title: String, _ setting: WritableKeyPath<BorderSettings, Double>, _ range: ClosedRange<Double>, step: Double,
                              help: String) -> some View {
        let initial = BorderSettings()[keyPath: setting]
        return LabeledSlider(title: title, value: model.borderPercent(setting, range: range, step: step), range: range, step: step, unit: "%",
                             defaultValue: initial * 100, modified: abs(model.border[keyPath: setting] - initial) > 1e-9,
                             reset: { model.border(setting).wrappedValue = initial },
                             editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Change Border") },
                             help: help)
    }

    @ViewBuilder private func control(_ adjustment: Adjustment) -> some View {
        if case .slider(let title, let path, let range, let step) = adjustment, path == "prep.highlights" {
            let value = model.number(path, range: range, step: step)
            let trackValue = Binding<Double>(
                get: { value.wrappedValue < 0 ? value.wrappedValue / 180 : value.wrappedValue / 100 },
                set: { value.wrappedValue = $0 < 0 ? $0 * 180 : $0 * 100 }
            )
            LabeledSlider(title: title, value: value, range: range, step: step,
                          defaultValue: model.defaultValue(path).double, modified: model.isModified(path),
                          reset: { model.resetValue(path) },
                          editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                          help: ControlHelp.text(path), trackValue: trackValue, trackRange: -1...1, trackNeutral: 0)
        } else {
            AdjustmentControl(model: model, adjustment: adjustment)
        }
    }

    private var colorSeparationTargetHueColor: Binding<Color> {
        let path = "post.color_separation.target_hue"
        return Binding(
            get: {
                let hue = model.value(path).double.truncatingRemainder(dividingBy: 360)
                let angle = hue < 0 ? hue + 360 : hue
                let sector = angle / 60
                let chroma = 0.95 * 0.85
                let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
                let m = 0.95 - chroma
                let rgb: (Double, Double, Double) = switch sector {
                case 0..<1: (chroma, x, 0)
                case 1..<2: (x, chroma, 0)
                case 2..<3: (0, chroma, x)
                case 3..<4: (0, x, chroma)
                case 4..<5: (x, 0, chroma)
                default: (chroma, 0, x)
                }
                return Color(.sRGB, red: rgb.0 + m, green: rgb.1 + m, blue: rgb.2 + m, opacity: 1)
            },
            set: { color in
                setColorSeparationHue(from: NSColor(color))
            }
        )
    }

    private func setColorSeparationHue(from color: NSColor) {
        // The effect compares hue in output-encoded RGB. Convert the screen
        // sample to sRGB first, then use its displayed hue directly. Passing
        // it through linear RGB changes the hue angle (notably for orange).
        guard let rgb = color.usingColorSpace(.extendedSRGB) ?? color.usingColorSpace(.deviceRGB) else { return }
        let red = Double(rgb.redComponent)
        let green = Double(rgb.greenComponent)
        let blue = Double(rgb.blueComponent)
        let maximum = max(red, max(green, blue))
        let minimum = min(red, min(green, blue))
        let chroma = maximum - minimum
        guard chroma > 0.02, maximum > 0 else { return }
        let hue: Double
        if maximum == red {
            hue = 60 * ((green - blue) / chroma).truncatingRemainder(dividingBy: 6)
        } else if maximum == green {
            hue = 60 * ((blue - red) / chroma + 2)
        } else {
            hue = 60 * ((red - green) / chroma + 4)
        }
        model.setInteractive("post.color_separation.target_hue", .number(hue < 0 ? hue + 360 : hue),
                             action: "Change Color Separation Hue")
    }

    /// A photograph's aspect ratio as people name it, such as 16:9.
    static func ratio(_ size: CGSize) -> String {
        let ratio = max(size.width, size.height) / min(size.width, size.height)
        let named = [(1.0, "1:1"), (5.0 / 4, "5:4"), (7.0 / 5, "7:5"), (16.0 / 9, "16:9"), (2.0, "2:1"), (21.0 / 9, "21:9")]
        if let (_, name) = named.first(where: { abs(ratio / $0.0 - 1) <= 0.01 }) { return name }
        return String(format: "%.2f:1", Double(ratio))
    }

    @ViewBuilder private func groups(_ section: InspectorSection) -> some View {
        ForEach(adjustmentGroups.filter { $0.section == section && shows($0) }) { group in
            disclosure(group.title, symbol: group.symbol, enable: group.enable) {
                if group.title == "Print Curves" { ToneGraphView(model: model) }
                let shown = group.controls.enumerated().filter { allControls || $0.offset < group.basic || isModified($0.element) }.map(\.element)
                ForEach(shown) { control($0) }
                    .disabled(group.enable.map { !model.value($0).bool } ?? false)
            }
        }
    }

    private func disclosure<Content: View>(_ title: String, symbol: String, enable: String? = nil, @ViewBuilder content: @escaping () -> Content) -> some View {
        let isExpanded = Binding(
            get: { expanded.split(separator: ",").contains(Substring(title)) },
            set: { open in
                var titles = expanded.split(separator: ",").map(String.init).filter { $0 != title }
                if open { titles.append(title) }
                expanded = titles.joined(separator: ",")
            })
        return DisclosureGroup(isExpanded: isExpanded) {
            content()
        } label: {
            HStack {
                Label(title, systemImage: symbol)
                    .tooltip(ControlHelp.group(title))
                Spacer()
                if let enable {
                    Toggle(title, isOn: model.toggle(enable)).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        .help("Turns \(title) on or off, keeping its settings.")
                }
            }
            // As in Photos, clicking the title toggles the group, not only the chevron.
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { isExpanded.wrappedValue.toggle() } }
        }
    }

    @ViewBuilder private func developmentTime(stock: Stock?, path: String, label: String, help: String) -> some View {
        if let stock, stock.times.count > 1 {
            Picker(label, selection: Binding(get: { model.value(path).double }, set: { model.set(path, $0 == 0 ? .null : .number($0)) })) {
                Text("Profile default").tag(0.0)
                ForEach(stock.times, id: \.self) { Text("\($0.formatted()) min").tag($0) }
            }
            .help(help)
        }
    }
}

/// Temperature is displayed and edited in kelvin, while the track follows
/// Studio's reciprocal-temperature spacing so equal movement feels even.
private struct WhiteBalanceTemperatureSlider: View {
    let model: EditorModel
    private let path = "io.raw_white_balance.temperature"
    @State private var typing = false

    private var kelvin: Double { model.value(path).double }
    private var position: Binding<Double> {
        Binding(
            get: { -1_000_000 / max(1667, min(25000, self.kelvin)) },
            set: { self.model.set(self.path, .number(max(1667, min(25000, -1_000_000 / $0)))) },
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("Temperature").lineLimit(1)
                    .tooltip(ControlHelp.text(path))
                Spacer(minLength: 8)
                if model.isModified(path) {
                    Button { model.resetValue(path) } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).imageScale(.small)
                    .help("Reset temperature")
                }
                if typing {
                    ValueField(title: "Temperature (K)", value: kelvinBinding, decimals: 0) { typing = false }
                        .frame(width: 76)
                } else {
                    Text("\(Int(kelvin.rounded())) K")
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(minWidth: 58, alignment: .trailing)
                        .contentShape(Rectangle())
                        .onTapGesture { typing = true }
                        .help("Click to enter a precise temperature in kelvin")
                }
            }
            ResettableSlider(
                title: "Temperature",
                value: position,
                range: (-1_000_000 / 1667)...(-1_000_000 / 25000),
                neutral: -1_000_000 / model.defaultValue(path).double,
                editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                reset: { model.resetValue(path) },
                toolTip: ControlHelp.text(path),
            )
        }
        .padding(.vertical, 1)
    }

    private var kelvinBinding: Binding<Double> {
        Binding(get: { kelvin }, set: { model.set(path, .number(min(25000, max(1667, $0)))) })
    }
}

/// Tint is a multiplicative camera gain. A logarithmic track gives useful
/// precision around neutral while preserving the full supported correction range.
private struct WhiteBalanceTintSlider: View {
    let model: EditorModel
    private let path = "io.raw_white_balance.tint"
    private let range = 0.01...4.0
    @State private var typing = false

    private var tint: Double { min(range.upperBound, max(range.lowerBound, model.value(path).double)) }
    private var stopsRange: ClosedRange<Double> { log2(range.lowerBound)...log2(range.upperBound) }
    private var stops: Double { log2(tint) }
    private var stopsBinding: Binding<Double> {
        Binding(get: { stops }, set: { model.set(path, .number(pow(2, min(stopsRange.upperBound, max(stopsRange.lowerBound, $0))))) })
    }
    private var position: Binding<Double> {
        Binding(
            get: {
                let value = stops
                return value < 0 ? value / abs(stopsRange.lowerBound) : value / stopsRange.upperBound
            },
            set: { position in
                let bounded = min(1, max(-1, position))
                let value = bounded < 0 ? bounded * abs(stopsRange.lowerBound) : bounded * stopsRange.upperBound
                model.set(path, .number(pow(2, value)))
            },
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("Tint · Magenta / Green").lineLimit(1)
                    .tooltip("Move left to add magenta, right to add green. 0 stops is neutral.")
                Spacer(minLength: 8)
                if model.isModified(path) {
                    Button { model.resetValue(path) } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).imageScale(.small)
                    .help("Reset tint to neutral")
                }
                if typing {
                    ValueField(title: "Tint (stops)", value: stopsBinding, decimals: 2) { typing = false }
                        .frame(width: 64)
                } else {
                    Text(stops.formatted(.number.precision(.fractionLength(2)).sign(strategy: .always())) + (stops < 0 ? " M" : stops > 0 ? " G" : ""))
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(minWidth: 48, alignment: .trailing)
                        .contentShape(Rectangle())
                        .onTapGesture { typing = true }
                        .help("Click to enter tint in stops from neutral. Negative adds magenta; positive adds green.")
                }
            }
            ResettableSlider(
                title: "Tint",
                value: position,
                range: -1...1,
                neutral: 0,
                editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                reset: { model.resetValue(path) },
                toolTip: "Tint in stops from neutral. Left adds magenta; right adds green.",
            )
        }
        .padding(.vertical, 1)
        .resettable(modified: model.isModified(path), reset: { model.resetValue(path) })
        .accessibilityElement(children: .contain)
    }
}
