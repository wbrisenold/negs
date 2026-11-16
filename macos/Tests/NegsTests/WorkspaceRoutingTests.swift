import AppKit
import XCTest
@testable import NegsApp

@MainActor final class WorkspaceRoutingTests: XCTestCase {
    func testSelectAllStartsWithTheFirstVisiblePhoto() {
        let photos = ["first", "second", "third"].map { URL(fileURLWithPath: "/photos/\($0).png") }
        var selection = LibrarySelection()
        selection.selectAll(photos)
        XCTAssertEqual(selection.current, photos.first)
        XCTAssertEqual(selection.selected, Set(photos))
        selection.deselectAll()
        XCTAssertEqual(selection.selected, [photos[0]])
    }

    func testLibraryDoesNotConsumeHiddenEditorKeys() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("negs-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 6, bitsPerPixel: 24))
        let photo = directory.appendingPathComponent("photo.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: photo)
        let model = EditorModel(sidecars: SidecarStore())
        defer { model.shutdown() }
        model.open(photo)
        XCTAssertNotNil(model.source)
        model.workspace = .library
        let controller = EditorWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        window.setFrameAutosaveName("")
        controller.editorFrame.split.splitView.autosaveName = nil
        let keys: [(String, UInt16)] = [("\\", 42), ("t", 17), ("\t", 48), ("\u{1b}", 53), ("\u{f703}", 124)]
        for (characters, code) in keys {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            XCTAssertFalse(controller.handleKey(event), "Library retains its own \(code) key behavior")
        }
        XCTAssertFalse(model.upsideDown)
        XCTAssertTrue(model.workspace == .library)
    }

    func testLibraryMenuDoesNotAdjustTheHiddenEditor() {
        _ = NSApplication.shared
        let model = EditorModel(sidecars: SidecarStore())
        defer { model.shutdown() }
        let menu = MainMenu(model: model, updates: UpdateController(), removeAppData: {})
        model.workspace = .library
        for selector in ["toggleFilmstrip", "toggleAdjustments", "togglePresets", "toggleAllControls", "resetAdjustments"] {
            let item = NSMenuItem(title: "", action: NSSelectorFromString(selector), keyEquivalent: "")
            XCTAssertFalse(menu.validateMenuItem(item), selector)
        }
    }
}
