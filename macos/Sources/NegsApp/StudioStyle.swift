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

    // Share the Omarchy graphite and amber tokens with the editor rather than
    // letting the Library drift back to its older blue palette.
    static let window = Theme.bg
    static let sidebar = Theme.film
    static let panel = Theme.panel
    static let plot = Theme.film
    static let subtle = Theme.line.opacity(0.35)
    static let outline = Theme.line.opacity(0.9)
    static let accent = Theme.accent
    static let positive = Color(red: 0.42, green: 0.68, blue: 0.38)
    static let negative = Theme.warn
    static let warning = Theme.warn
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
