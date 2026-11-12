import AppKit
import SwiftUI

/// Shared graphite surfaces and compact spacing for the Library and editor inspector.
enum StudioStyle {
    enum Space {
        static let tight: CGFloat = 3
        static let compact: CGFloat = 6
        static let standard: CGFloat = 9
        static let section: CGFloat = 12
        static let paneInset: CGFloat = 8
    }

    enum Radius {
        static let control: CGFloat = 4
        static let card: CGFloat = 5
        static let panel: CGFloat = 6
        static let pane: CGFloat = 12
    }

    enum Layout {
        static let editorPresetSidebarWidth: CGFloat = 280
    }

    enum Typography {
        static let section = Font.system(size: 10, weight: .semibold)
        static let sectionTracking: CGFloat = 0.65
        static let label = Font.system(size: 11)
        static let value = Font.system(size: 11, weight: .medium).monospacedDigit()
        static let caption = Font.system(size: 10)
    }

    // Resolve-inspired graphite surfaces: consistent across macOS appearances,
    // with blue reserved for selection and primary actions.
    static let window = Color(red: 0.105, green: 0.108, blue: 0.112)
    static let sidebar = Color(red: 0.082, green: 0.084, blue: 0.087)
    static let panel = Color(red: 0.145, green: 0.148, blue: 0.152)
    static let plot = Color(red: 0.045, green: 0.047, blue: 0.050)
    static let subtle = Color.white.opacity(0.035)
    static let outline = Color.white.opacity(0.085)
    static let accent = Color(red: 0.18, green: 0.52, blue: 0.95)
    static let positive = Color(red: 0.33, green: 0.72, blue: 0.46)
    static let negative = Color(red: 0.88, green: 0.34, blue: 0.34)
    static let warning = Color(red: 0.91, green: 0.63, blue: 0.24)
}

extension View {
    /// One inset surface treatment for the Library bins, photo inspector, and editor rail.
    func studioWorkspacePane(surface: Color = StudioStyle.panel) -> some View {
        let shape = RoundedRectangle(cornerRadius: StudioStyle.Radius.pane, style: .continuous)
        return background(surface, in: shape)
            .overlay(shape.strokeBorder(StudioStyle.outline, lineWidth: 0.8))
            .clipShape(shape)
    }
}
