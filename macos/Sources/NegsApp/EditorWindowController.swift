import AppKit
import Observation
import SwiftUI

/// End field editing even when the clicked view doesn't take keyboard focus.
@MainActor final class EditorWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
           let editor = firstResponder as? NSTextView, editor.isFieldEditor,
           let field = editor.delegate as? NSTextField,
           !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
            // Commit before dispatch so the clicked control sees the typed value.
            makeFirstResponder(nil)
        }
        super.sendEvent(event)
    }
}

/// The editing window: a unified toolbar over the canvas and a trailing
/// inspector column. The window, toolbar, and columns are AppKit; the canvas
/// and inspector contents are SwiftUI. They follow the model through
/// Observation, like the views.
@MainActor final class EditorWindowController: NSWindowController, NSToolbarDelegate, NSMenuDelegate, NSMenuItemValidation, NSPopoverDelegate {
    private let model: EditorModel
    private let inspector: NSSplitViewItem
    private let panel: NSHostingController<InspectorPanel>
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private lazy var cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelCrop))
    private lazy var doneButton = NSButton(title: "Done", target: self, action: #selector(applyCrop))
    private var collapsing: NSKeyValueObservation?
    private var appearing: NSObjectProtocol?
    private var resigning: NSObjectProtocol?
    private var becomingKey: NSObjectProtocol?
    private var keyMonitor: Any?
    /// The narrowest canvas, and the narrowest the content can be with the
    /// inspector shown beside it. The split view can't keep both columns at
    /// their minimums in a narrower window, so the window enforces the sum.
    private let canvasMinimum: CGFloat
    private let presetCanvasMinimum: CGFloat
    private let columnsMinimum: CGFloat
    private static let minimumHeight: CGFloat = 560
    /// The key held to show the original, so its release is found even if
    /// a modifier (⌥⇧ on some layouts) was let go first.
    private var originalKey: UInt16?
    /// The mode the toolbar's items are laid out for.
    private var toolbarMode = LibraryMode.photo
    private var toolbarIsLibrary: Bool?
    /// The batch export popover, and what the Export item shows now.
    private var batchPopover: NSPopover?
    private var exportIcon = ""
    private lazy var sizeSlider: NSSlider = {
        let slider = NSSlider(value: GridMetrics.defaultSize, minValue: GridMetrics.sizes.lowerBound, maxValue: GridMetrics.sizes.upperBound,
                              target: self, action: #selector(resizeGrid(_:)))
        slider.controlSize = .small
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        return slider
    }()

    init(model: EditorModel) {
        self.model = model
        // The split view sizes both columns, so SwiftUI never measures their
        // contents for the window's size limits.
        let canvas = NSHostingController(rootView: WorkspaceView(model: model))
        canvas.sizingOptions = []
        // The adjustments take about a third of the time to the first frame,
        // so the column starts empty and fills in once the window is on screen.
        panel = NSHostingController(rootView: InspectorPanel(model: model, built: false))
        panel.sizingOptions = []
        panel.view.frame.size = NSSize(width: 340, height: 860)
        let canvasItem = NSSplitViewItem(viewController: canvas)
        canvasItem.minimumThickness = 680
        inspector = NSSplitViewItem(inspectorWithViewController: panel)
        inspector.minimumThickness = 300
        inspector.maximumThickness = 440
        inspector.isCollapsed = !model.inspectorVisible || (model.inspectorPane == .presets && !model.cropping)
        let split = NSSplitViewController()
        split.addSplitViewItem(canvasItem)
        split.addSplitViewItem(inspector)
        split.splitView.autosaveName = "editor"
        canvasMinimum = canvasItem.minimumThickness
        presetCanvasMinimum = canvasItem.minimumThickness + StudioStyle.Layout.editorPresetSidebarWidth
        columnsMinimum = canvasItem.minimumThickness + inspector.minimumThickness + split.splitView.dividerThickness

        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.title = "Negs"
        window.toolbarStyle = .unified
        window.isRestorable = false
        // Place the window before adding its content, so the first layout is at the final size.
        if !window.setFrameUsingName("editor") { window.center() }
        // A saved frame from before the minimum, or from a smaller screen,
        // grows to it.
        let initialMinimum = model.workspace == .library ? 980
            : model.inspectorPane == .presets && model.inspectorVisible && !model.cropping ? presetCanvasMinimum
            : inspector.isCollapsed ? canvasMinimum : columnsMinimum
        Self.fitMinimum(of: window, width: initialMinimum)
        split.view.frame = NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size)
        window.contentViewController = split
        window.setFrameAutosaveName("editor")
        super.init(window: window)
        shouldCascadeWindows = false

        let toolbar = NSToolbar(identifier: "editor")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.sizeMode = .small
        toolbar.centeredItemIdentifiers = model.mode == .grid ? [.gridSize] : [.zoom, .edit]
        window.toolbar = toolbar
        model.undoManager = window.undoManager
        // Dragging the inspector closed hides the adjustments, like the toolbar button.
        collapsing = inspector.observe(\.isCollapsed) { [weak self] item, _ in
            MainActor.assumeIsolated {
                guard let self, self.model.workspace == .editor else { return }
                // A hidden inspector lets the window narrow to the canvas alone.
                if let window = self.window {
                    let width = item.isCollapsed
                        ? (self.model.inspectorPane == .presets && self.model.inspectorVisible && !self.model.cropping
                            ? self.presetCanvasMinimum : self.canvasMinimum)
                        : self.columnsMinimum
                    Self.fitMinimum(of: window, width: width)
                }
                // The grid collapses it without hiding the adjustments.
                // The presets page uses a separate leading browser; collapsing
                // the trailing column is part of that layout, not a hide action.
                if self.model.inspectorPane == .presets && !self.model.cropping { return }
                guard self.model.mode == .photo, self.model.inspectorVisible == item.isCollapsed else { return }
                self.model.inspectorVisible = !item.isCollapsed
            }
        }
        appearing = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowChangedOcclusion() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.holdOriginal(event) == true || self?.escapeToGrid(event) == true } ? nil : event
        }
        resigning = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.originalKey != nil else { return }
                self.originalKey = nil; self.model.holdOriginal(false)
            }
        }
        // File events on network shares get lost, so the folder is listed
        // again whenever the window comes back.
        becomingKey = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.library.refreshNow() }
        }
        observe()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Prevent window closure during data removal from restoring preferences.
    func prepareForAppDataRemoval() {
        window?.setFrameAutosaveName("")
        (window?.contentViewController as? NSSplitViewController)?.splitView.autosaveName = nil
        window?.orderOut(nil)
    }

    // MARK: State

    private func windowChangedOcclusion() {
        guard let window, window.occlusionState.contains(.visible), let appearing else { return }
        NotificationCenter.default.removeObserver(appearing)
        self.appearing = nil
        panel.rootView = InspectorPanel(model: model)
    }

    /// Holding \ shows the original, as in Lightroom, unless text is being
    /// typed. True if the event was handled.
    private func holdOriginal(_ event: NSEvent) -> Bool {
        if event.type == .keyUp {
            guard event.keyCode == originalKey else { return false }
            originalKey = nil; model.holdOriginal(false)
            return true
        }
        guard event.window === window, model.mode == .photo, event.characters == "\\",
              event.modifierFlags.isDisjoint(with: [.command, .control]),
              !(window?.firstResponder is NSText) else { return false }
        if !event.isARepeat { originalKey = event.keyCode; model.holdOriginal(true) }
        return true
    }

    /// Esc shows the grid, as in Lightroom, unless text is being typed or a
    /// crop drawn (whose Cancel takes it). The canvas's hosting view claims
    /// Escape before the menu would see it, so it's caught here.
    private func escapeToGrid(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53, event.window === window,
              event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]),
              model.mode == .photo, model.source != nil, !model.cropping, MainMenu.takesRatingKeys(window) else { return false }
        model.showGrid()
        return true
    }

    /// Applies the model now rather than on the next observation pass, which
    /// at launch runs only after the window is on screen.
    func refresh() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            update()
        }
    }

    private func observe() {
        withObservationTracking { update() } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func update() {
        guard let window else { return }
        let inLibrary = model.workspace == .library
        let editing = !inLibrary
        let photo = editing && model.source != nil && model.mode == .photo
        let grid = editing && model.mode == .grid
        if inLibrary {
            window.title = "Negs"
            window.subtitle = "Library"
        } else if grid, let folder = model.library.directory ?? model.source?.deletingLastPathComponent() {
            window.title = folder.lastPathComponent
            let shown = model.shownPhotos.count, selected = model.ratingTargets.count
            window.subtitle = selected > 1 ? "\(selected) of \(shown) selected" : shown == 1 ? "1 photograph" : "\(shown) photographs"
        } else {
            window.title = model.sourceItem.map { model.library.name(of: $0) } ?? "Negs"
            window.subtitle = !photo || !model.ready ? "" : model.value("io.scan_film").bool ? model.filmName : "\(model.filmName) → \(model.paperName)"
        }
        if let item = items[.library] { item.isEnabled = !model.cropping }
        if let item = items[.backToEdit] {
            item.isEnabled = model.photoLibrary.selectedPhotoURL != nil || model.source != nil
        }
        showItems(for: inLibrary ? .photo : model.mode)
        showCropActions(model.cropping)
        if let item = items[.mode] as? NSToolbarItemGroup {
            item.selectedIndex = grid ? 1 : 0
            item.isEnabled = photo && !model.cropping
            item.subitems.forEach { $0.isEnabled = photo && !model.cropping }
        }
        if sizeSlider.doubleValue != model.gridCellSize { sizeSlider.doubleValue = model.gridCellSize }
        if let item = items[.filmstrip] {
            item.toolTip = model.filmstripVisible ? "Hide film strip (⌥⌘F)" : "Show film strip (⌥⌘F)"
            let icon = symbol("rectangle.bottomthird.inset.filled", "Film Strip")
            item.image = model.filmstripVisible
                ? icon.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor])) : icon
            item.isEnabled = photo
        }
        if let item = items[.filter] {
            // Filled while a filter is on, so a half-empty strip is never a mystery.
            let on = model.photoLibrary.filter != .all || !model.photoLibrary.cullFilters.isEmpty
            item.image = symbol(on ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle", "Filter")
            item.toolTip = on ? "Filter: \(model.photoLibrary.filter.title) and AI culling" : "Filter the Library and Edit photo set"
            item.isEnabled = photo || grid
        }
        setEnabled(.zoom, photo && !model.cropping)
        if let edit = items[.edit] as? NSToolbarItemGroup {
            edit.isEnabled = photo
            edit.subitems[0].isEnabled = photo
            edit.subitems[1].isEnabled = model.image != nil
            let crop = edit.subitems[1]
            crop.toolTip = model.cropping ? "Apply the crop (⌘K)" : "Crop the photograph (⌘K)"
            // The accent color marks crop mode as on.
            crop.image = model.cropping
                ? symbol("crop", "Crop").withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor]))
                : symbol("crop", "Crop")
        }
        setEnabled(.export, model.batch != nil || model.canExport)
        updateExportItem()
        // The accent color marks the panel the inspector column shows.
        for (id, pane, name, label) in [(NSToolbarItem.Identifier.adjustments, InspectorPane.adjustments, "slider.horizontal.3", "Adjustments"),
                                        (.presets, .presets, "square.stack", "Presets")] {
            let icon = symbol(name, label)
            items[id]?.image = model.inspectorVisible && model.inspectorPane == pane
                ? icon.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor])) : icon
            items[id]?.isEnabled = editing
        }
        // A ratio field being edited keeps its own Return and Escape.
        if let session = model.cropSession {
            cancelButton.keyEquivalent = session.typing ? "" : "\u{1b}"
            doneButton.keyEquivalent = session.typing ? "" : "\r"
        }
        let presetBrowserShown = photo && !model.cropping && model.inspectorVisible && model.inspectorPane == .presets
        let inspectorShown = photo && model.inspectorVisible && !presetBrowserShown
        let workspaceMinimum = inspectorShown ? columnsMinimum : presetBrowserShown ? presetCanvasMinimum : canvasMinimum
        Self.fitMinimum(of: window, width: workspaceMinimum)
        if inspector.isCollapsed != !inspectorShown {
            // Make room before the inspector slides in, so neither column is
            // squeezed below its minimum.
            inspector.animator().isCollapsed = !inspectorShown
        }
    }

    /// Sets the window's minimum content size and grows the window to it when
    /// it's smaller, keeping the top-left corner in place and the window on
    /// its screen. Full screen already fills the screen.
    private static func fitMinimum(of window: NSWindow, width: CGFloat) {
        let minimum = NSSize(width: width, height: minimumHeight)
        window.contentMinSize = minimum
        guard !window.styleMask.contains(.fullScreen) else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        guard content.width < minimum.width || content.height < minimum.height else { return }
        let height = max(content.height, minimum.height)
        var frame = window.frameRect(forContentRect: NSRect(x: content.minX, y: content.maxY - height,
                                                            width: max(content.width, minimum.width), height: height))
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            // Slide left or down rather than off the screen's edge.
            frame.origin.x = max(min(frame.origin.x, visible.maxX - frame.width), visible.minX)
            frame.origin.y = max(min(frame.origin.y, visible.maxY - frame.height), visible.minY)
        }
        window.setFrame(frame, display: window.isVisible)
    }

    private func setEnabled(_ id: NSToolbarItem.Identifier, _ enabled: Bool) {
        guard let item = items[id] else { return }
        item.isEnabled = enabled
        (item as? NSToolbarItemGroup)?.subitems.forEach { $0.isEnabled = enabled }
    }

    /// The Library gets a short, labeled toolbar. Editor tools appear only
    /// when editing, so disabled photo controls do not crowd Library.
    private func showItems(for mode: LibraryMode) {
        let inLibrary = model.workspace == .library
        guard (mode != toolbarMode || toolbarIsLibrary != inLibrary), let toolbar = window?.toolbar else { return }
        toolbarMode = mode
        toolbarIsLibrary = inLibrary
        toolbar.displayMode = .iconAndLabel
        toolbar.centeredItemIdentifiers = inLibrary ? [] : mode == .grid ? [.gridSize] : [.zoom, .edit]
        let ids = inLibrary ? [.backToEdit, .open] : Self.itemIdentifiers(for: mode)
        while !toolbar.items.isEmpty { toolbar.removeItem(at: 0) }
        for (index, id) in ids.enumerated() { toolbar.insertItem(withItemIdentifier: id, at: index) }
    }

    static func itemIdentifiers(for mode: LibraryMode) -> [NSToolbarItem.Identifier] {
        switch mode {
        case .photo: [.library, .open, .mode, .filter, .filmstrip, .flexibleSpace, .zoom, .edit, .flexibleSpace, .inspectorTrackingSeparator,
                      .flexibleSpace, .export, .presets, .adjustments]
        case .grid: [.library, .open, .mode, .filter, .flexibleSpace, .gridSize, .flexibleSpace, .export]
        }
    }

    /// While cropping, Cancel and Done take the place of Export.
    private func showCropActions(_ cropping: Bool) {
        guard let toolbar = window?.toolbar else { return }
        let ids = toolbar.items.map(\.itemIdentifier)
        if cropping, let i = ids.firstIndex(of: .export) {
            toolbar.removeItem(at: i)
            toolbar.insertItem(withItemIdentifier: .doneCrop, at: i)
            toolbar.insertItem(withItemIdentifier: .cancelCrop, at: i)
        } else if !cropping, let i = ids.firstIndex(of: .cancelCrop) {
            toolbar.removeItem(at: i + 1)
            toolbar.removeItem(at: i)
            toolbar.insertItem(withItemIdentifier: .export, at: i)
        }
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.itemIdentifiers(for: .photo) }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.backToEdit, .gridSize, .cancelCrop, .doneCrop]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item: NSToolbarItem
        switch id {
        case .backToEdit:
            item = button(id, "Back to Edit", "slider.horizontal.3", "Edit the selected photo or return to the previous edit", #selector(showEditor))
            item.isNavigational = true
        case .library:
            item = button(id, "Library", "square.grid.2x2", "Browse the photo Library", #selector(showLibrary))
            item.isNavigational = true
        case .open:
            item = button(id, "Open", "folder", "Open photograph (⌘O)", #selector(openPhotograph))
            item.isNavigational = true
        case .mode:
            // A segmented switch shows which mode the window is in.
            let group = NSToolbarItemGroup(itemIdentifier: id, images: [symbol("photo", "Photo"), symbol("square.grid.2x2", "Grid")],
                                           selectionMode: .selectOne, labels: ["Photo", "Grid"], target: self, action: #selector(switchMode(_:)))
            group.label = "View"
            group.subitems[0].toolTip = "Edit the photograph (E)"
            group.subitems[1].toolTip = "Show all photographs in the folder (G)"
            group.selectedIndex = model.mode == .grid ? 1 : 0
            group.controlRepresentation = .expanded
            item = group
        case .gridSize:
            item = NSToolbarItem(itemIdentifier: id)
            sizeSlider.doubleValue = model.gridCellSize
            item.view = sizeSlider; item.label = "Size"; item.toolTip = "Thumbnail size (⌘+, ⌘−)"
        case .filmstrip:
            item = button(id, "Film Strip", "rectangle.bottomthird.inset.filled", "Show or hide film strip (⌥⌘F)", #selector(toggleFilmstrip))
        case .filter:
            let menuItem = NSMenuToolbarItem(itemIdentifier: id)
            menuItem.label = "Filter"
            menuItem.image = symbol("line.3.horizontal.decrease.circle", "Filter")
            menuItem.showsIndicator = false
            // Filled in when it opens, from the filter as it is then.
            let menu = NSMenu(title: "Filter")
            menu.delegate = self
            menuItem.menu = menu
            item = menuItem
        case .zoom:
            let group = NSToolbarItemGroup(itemIdentifier: id)
            group.subitems = [button(.init("fit"), "Fit", "arrow.down.right.and.arrow.up.left", "Fit photograph (⌘0)", #selector(fit)),
                              button(.init("actualSize"), "Actual Size", "1.magnifyingglass", "Actual size (⌘1)", #selector(actualSize))]
            group.label = "Zoom"
            item = group
        case .edit:
            // Grouped items share one capsule, without the dividers of a segmented group.
            let group = NSToolbarItemGroup(itemIdentifier: id)
            group.subitems = [button(.init("rotate"), "Rotate", "rotate.right", "Rotate clockwise (⌘R)", #selector(rotateClockwise)),
                              button(.init("crop"), "Crop", "crop", "Crop the photograph (⌘K)", #selector(toggleCrop))]
            group.label = "Edit"
            item = group
        case .export:
            item = button(id, "Export", "square.and.arrow.down", "Export photograph (⇧⌘E)", #selector(export))
        case .presets:
            item = button(id, "Presets", "square.stack", "Show or hide presets (⌥⌘P)", #selector(togglePresets))
        case .adjustments:
            item = button(id, "Adjustments", "slider.horizontal.3", "Show or hide adjustments (⌥⌘I)", #selector(toggleAdjustments))
        case .cancelCrop:
            item = NSToolbarItem(itemIdentifier: id)
            item.view = cancelButton; item.label = "Cancel"; item.toolTip = "Discard the crop (Esc)"
        case .doneCrop:
            item = NSToolbarItem(itemIdentifier: id)
            item.view = doneButton; item.label = "Done"; item.toolTip = "Apply the crop (Return)"
            // The confirming action is filled with the accent color. The style
            // needs the macOS 26 SDK, which release CI's Xcode 16 lacks.
            #if compiler(>=6.2)
            if #available(macOS 26, *) { item.style = .prominent } else { doneButton.bezelColor = .controlAccentColor }
            #else
            doneButton.bezelColor = .controlAccentColor
            #endif
        default:
            return nil
        }
        // Enabled from the model's state in update(), not by validation.
        item.autovalidates = false
        (item as? NSToolbarItemGroup)?.subitems.forEach { $0.autovalidates = false }
        items[id] = item
        return item
    }

    private func button(_ id: NSToolbarItem.Identifier, _ label: String, _ symbolName: String, _ help: String, _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.image = symbol(symbolName, label)
        item.toolTip = help
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }

    private func symbol(_ name: String, _ description: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
    }

    // MARK: Filter

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, on: Bool, tag: Int = 0) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self; item.tag = tag; item.state = on ? .on : .off
        }
        // A pull-down toolbar menu takes its first item as the button's title
        // and doesn't list it.
        menu.addItem(withTitle: "Filter", action: nil, keyEquivalent: "")
        menu.addItem(.sectionHeader(title: "Library"))
        for (index, filter) in LibraryFilter.allCases.enumerated() {
            add(filter.title, #selector(photoLibraryFilter(_:)), on: model.photoLibrary.filter == filter, tag: index)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "AI Culling · All Must Match"))
        for (index, filter) in CullFilterChip.allCases.enumerated() {
            let title = filter == .topPicks
                ? "Top \(model.photoLibrary.topPickValue)\(model.photoLibrary.topPickUnit == .percent ? "%" : "") / Scene"
                : filter.title
            add(title, #selector(toggleCullFilter(_:)), on: model.photoLibrary.cullFilters.contains(filter), tag: index)
        }
        menu.addItem(.separator())
        let active = model.photoLibrary.filter != .all || model.photoLibrary.selectedSmartCollectionID != nil
            || !model.photoLibrary.cullFilters.isEmpty
        let clear = menu.addItem(withTitle: "Clear Filters", action: active ? #selector(clearFilters) : nil, keyEquivalent: "l")
        clear.keyEquivalentModifierMask = [.command, .option]; clear.target = self
    }

    @objc private func photoLibraryFilter(_ item: NSMenuItem) {
        guard LibraryFilter.allCases.indices.contains(item.tag) else { return }
        model.chooseLibraryFilter(LibraryFilter.allCases[item.tag])
    }
    @objc private func toggleCullFilter(_ item: NSMenuItem) {
        guard CullFilterChip.allCases.indices.contains(item.tag) else { return }
        model.toggleCullFilter(CullFilterChip.allCases[item.tag])
    }
    @objc private func clearFilters() { model.clearLibraryFilters() }

    // MARK: Actions

    @objc private func showLibrary() { model.workspace = .library }
    @objc private func showEditor() {
        if let url = model.photoLibrary.selectedPhotoURL { model.open(url) }
        else if model.source != nil { model.workspace = .editor }
    }
    @objc private func openPhotograph() { model.openPanel() }
    @objc private func switchMode(_ sender: NSToolbarItemGroup) { sender.selectedIndex == 1 ? model.showGrid() : model.editCurrent() }
    @objc private func resizeGrid(_ sender: NSSlider) { model.gridCellSize = sender.doubleValue.rounded() }
    @objc private func fit() { model.zoom(fit: true) }
    @objc private func actualSize() { model.zoom(fit: false) }
    @objc private func rotateClockwise() { model.rotate() }
    @objc private func toggleCrop() { model.cropping ? model.endCrop(apply: true) : model.beginCrop() }
    @objc private func cancelCrop() { model.endCrop(apply: false) }
    @objc private func applyCrop() { model.endCrop(apply: true) }
    @objc private func export() {
        if let run = model.batch { return toggleBatchPopover(run) }
        model.exportPanel()
    }

    /// A batch replaces the icon with its ring; one that ended with failures
    /// shows a warning until its popover has been seen.
    private func updateExportItem() {
        guard let item = items[.export] else { return }
        let icon: String, help: String
        if let run = model.batch, run.running {
            icon = "ring \(run.finished)/\(run.total)"
            help = "\(run.title). Click for details."
        } else if let run = model.batch, !run.failures.isEmpty {
            icon = "failed"
            help = "\(run.title), \(run.failures.count) failed. Click for details."
        } else {
            icon = "export"
            help = model.exportTitle == "Export Photograph…" ? "Export photograph (⇧⌘E)" : "Export the selected photographs (⇧⌘E)"
        }
        item.toolTip = help
        guard icon != exportIcon else { return }
        exportIcon = icon
        if let run = model.batch, run.running { item.image = BatchRing.image(run.fraction) }
        else if icon == "failed" { item.image = symbol("exclamationmark.triangle", "Export finished with failures") }
        else { item.image = symbol("square.and.arrow.down", "Export") }
    }

    private func toggleBatchPopover(_ run: BatchRun) {
        if let batchPopover, batchPopover.isShown { return batchPopover.performClose(nil) }
        guard let item = items[.export] else { return }
        let content = NSHostingController(rootView: BatchProgressView(run: run, retry: { [weak self] in self?.model.retryBatch() },
                                                                      showInFinder: { [weak self] in self?.model.showBatchInFinder() }))
        content.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        popover.delegate = self
        batchPopover = popover
        model.batchPopoverShown = true
        popover.show(relativeTo: item)
    }

    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === batchPopover else { return }
        batchPopover = nil
        model.batchPopoverShown = false
        model.clearBatch()
    }
    @objc private func toggleFilmstrip() { model.filmstripVisible.toggle() }
    @objc private func toggleAdjustments() { model.togglePane(.adjustments) }
    @objc private func togglePresets() { model.togglePane(.presets) }

    // MARK: Selection

    // Edit › Select All and Deselect All reach here through the responder
    // chain only when no text field takes them first.
    override func selectAll(_ sender: Any?) { model.selectAll() }
    @objc func deselectAll(_ sender: Any?) { model.deselectAll() }

    /// The photographs are selected where they're shown: the grid, or the strip.
    private var selecting: Bool {
        model.source != nil && !model.cropping && (model.mode == .grid || model.filmstripVisible)
    }

    // MARK: Edits

    // Edit › Copy and Paste (⌘C, ⌘V) copy and paste the photograph's edits,
    // like Photo › Copy Edits and Paste Edits (⇧⌘C, ⇧⌘V). They reach here,
    // the end of the responder chain, only when no text field or view takes
    // them first, so typed text keeps its own copy and paste.
    @objc func copy(_ sender: Any?) { model.copyEdits() }
    @objc func paste(_ sender: Any?) { model.pasteEdits() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(selectAll(_:)), #selector(deselectAll(_:)): selecting
        // Not while a sheet or another window has the keys, as for Photo › Copy Edits.
        case #selector(copy(_:)): model.canCopyEdits && MainMenu.takesRatingKeys(NSApp.keyWindow)
        case #selector(paste(_:)): model.canPasteEdits && MainMenu.takesRatingKeys(NSApp.keyWindow)
        default: true
        }
    }
}

extension NSToolbarItem.Identifier {
    static let filmstrip = Self("filmstrip"), filter = Self("filter"), mode = Self("mode"), gridSize = Self("gridSize")
    static let library = Self("library"), backToEdit = Self("backToEdit"), open = Self("open"), zoom = Self("zoom"), edit = Self("edit")
    static let export = Self("export"), adjustments = Self("adjustments"), presets = Self("presets"), cancelCrop = Self("cancelCrop"), doneCrop = Self("doneCrop")
}
