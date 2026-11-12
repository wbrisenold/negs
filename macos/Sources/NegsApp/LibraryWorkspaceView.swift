import AppKit
import SwiftUI

struct LibraryWorkspaceView: View {
    let model: EditorModel
    @Bindable private var library: PhotoLibrary
    @AppStorage("negs.library.thumbnailSize") private var thumbnailSize = 176.0
    @AppStorage("negs.library.showInspector") private var showInspector = false
    @State private var showingAlbumSheet = false
    @State private var showingSmartSheet = false
    @State private var showingProjectSheet = false
    @State private var showingProjectPhotoPicker = false
    @State private var showingFilterOptions = false
    @State private var showingTopPickOptions = false
    @State private var albumName = ""
    @State private var smartName = ""
    @State private var projectName = ""
    @State private var smartFilter: LibraryFilter = .picked
    @FocusState private var libraryGridFocused: Bool
    private var cullFilters: Set<CullFilterChip> { library.cullFilters }

    private var selected: LibraryPhoto? { library.selectedPhoto }
    private var hasLocationScope: Bool { library.selectedFolderID != nil || library.selectedProjectID != nil }
    private func displayedPhotos(from visiblePhotos: [LibraryPhoto]) -> [LibraryPhoto] {
        library.filteredPhotos(from: visiblePhotos)
    }
    private var topPickLabel: String {
        let analyzed = library.visiblePhotos.filter { $0.cull != nil && !($0.cull?.failed ?? true) }.count
        let selected = library.topPickURLs(in: library.visiblePhotos).count
        guard analyzed > 0 else { return "Top Picks · Not analyzed" }
        let quota = library.topPickUnit == .percent ? " · \(library.topPickValue)%" : ""
        return "Top \(selected) of \(analyzed)\(quota)"
    }
    private var addableCullFilters: [CullFilterChip] {
        CullFilterChip.allCases.filter { $0 != .topPicks }
    }
    private func filterTitle(_ filter: CullFilterChip) -> String {
        filter == .topPicks ? topPickLabel : filter.title
    }

    init(model: EditorModel) {
        self.model = model
        self._library = Bindable(wrappedValue: model.photoLibrary)
    }

    var body: some View {
        let visiblePhotos = library.visiblePhotos
        let topPickURLs: Set<URL> = visiblePhotos.contains(where: { $0.cull != nil })
            ? library.topPickURLs(in: visiblePhotos) : []
        return HSplitView {
            sidebar.frame(minWidth: 172, idealWidth: 196, maxWidth: 228)
                .padding(StudioStyle.Space.paneInset)
                .studioWorkspacePane(surface: StudioStyle.sidebar)
            content(visiblePhotos: visiblePhotos, topPickURLs: topPickURLs)
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, StudioStyle.Space.paneInset)
            if showInspector {
                inspector(topPickURLs: topPickURLs)
                    .frame(minWidth: 270, idealWidth: 310, maxWidth: 350)
                    .padding(StudioStyle.Space.paneInset)
                    .studioWorkspacePane(surface: StudioStyle.sidebar)
            }
        }
        .background(StudioStyle.window)
        .preferredColorScheme(.dark)
        .task { await library.load() }
        .sheet(isPresented: $showingAlbumSheet) { albumSheet }
        .sheet(isPresented: $showingSmartSheet) { smartCollectionSheet }
        .sheet(isPresented: $showingProjectSheet) { projectSheet }
        .sheet(isPresented: $showingProjectPhotoPicker) {
            if let projectID = library.selectedProjectID {
                ProjectPhotoPicker(library: library, projectID: projectID, addSourceFolder: importFolders)
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudioStyle.Space.section) {
                sidebarSection("LIBRARY") {
                    ForEach(LibraryFilter.allCases.filter { $0 != .missing || hasLocationScope }) { filter in
                        NavigationRow(title: filter.title, symbol: filter.symbol,
                                      count: library.count(for: filter), selected: library.selectedAlbumID == nil
                                        && library.selectedFolderID == nil && library.selectedSmartCollectionID == nil
                                        && library.selectedProjectID == nil
                                        && library.filter == filter) {
                            library.filter = filter
                            if filter != .missing {
                                library.selectedFolderID = nil
                                library.selectedAlbumID = nil
                                library.selectedSmartCollectionID = nil
                                library.selectedProjectID = nil
                            }
                        }
                    }
                }
                sidebarSection("PROJECTS", actionTitle: "New Project…", action: {
                    projectName = ""
                    showingProjectSheet = true
                }) {
                    ForEach(library.projects) { project in
                        NavigationRow(title: project.name, symbol: "briefcase",
                                      count: library.count(for: project), selected: library.selectedProjectID == project.id) {
                            library.selectedProjectID = project.id
                            library.selectedFolderID = nil
                            library.selectedAlbumID = nil
                            library.selectedSmartCollectionID = nil
                            library.filter = .all
                        }
                        .help("Curated photo set. Add selected images from any source folder.")
                        .contextMenu {
                            Button("Delete Project", systemImage: "trash", role: .destructive) {
                                library.deleteProject(project.id)
                            }
                        }
                    }
                }
                if library.selectedProjectID == nil {
                sidebarSection("SOURCE FOLDERS", actionTitle: "Add Folder…", action: importFolders) {
                    ForEach(library.folders) { folder in
                        HStack(spacing: 2) {
                            NavigationRow(title: folder.name, symbol: "folder", count: library.photos.filter { $0.folderID == folder.id }.count,
                                          selected: library.selectedFolderID == folder.id) {
                                library.filter = .all
                                library.selectedFolderID = folder.id
                                library.selectedAlbumID = nil
                                library.selectedSmartCollectionID = nil
                                library.selectedProjectID = nil
                            }
                            .help("Source folder on disk. Photos stay organized at this location.")
                            .contextMenu {
                                Button("Refresh Folder", systemImage: "arrow.clockwise") { Task { await library.refresh() } }
                                Button("Remove from Library", systemImage: "minus.circle", role: .destructive) { library.removeFolder(folder.id) }
                            }
                        }
                    }
                }
                }
                sidebarSection("ALBUMS") {
                    ForEach(library.albums) { album in
                        NavigationRow(title: album.name, symbol: "rectangle.stack", count: library.photos.filter { $0.albumIDs.contains(album.id) }.count,
                                      selected: library.selectedAlbumID == album.id) {
                            library.filter = .all
                            library.selectedAlbumID = album.id
                            library.selectedFolderID = nil
                            library.selectedSmartCollectionID = nil
                            library.selectedProjectID = nil
                        }
                        .contextMenu {
                                Button(role: .destructive) { library.deleteAlbum(album.id) } label: {
                                    Label("Delete Album", systemImage: "trash")
                                }
                        }
                    }
                    Button { albumName = ""; showingAlbumSheet = true } label: {
                        Label("New Album…", systemImage: "plus")
                            .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).foregroundStyle(.tint)
                }
                sidebarSection("SMART COLLECTIONS") {
                    ForEach(library.smartCollections) { collection in
                        NavigationRow(title: collection.name, symbol: collection.filter.symbol,
                                      count: library.photos.filter { $0.matches(collection.filter) }.count,
                                      selected: library.selectedSmartCollectionID == collection.id) {
                            library.selectedSmartCollectionID = collection.id
                            library.selectedFolderID = nil
                            library.selectedAlbumID = nil
                            library.selectedProjectID = nil
                        }
                        .contextMenu {
                            Button(role: .destructive) { library.deleteSmartCollection(collection.id) } label: {
                                Label("Delete Smart Collection", systemImage: "trash")
                            }
                        }
                    }
                    Button { smartName = ""; showingSmartSheet = true } label: {
                        Label("Save Smart Collection…", systemImage: "plus")
                            .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 14)
        }
        .background(StudioStyle.sidebar)
    }

    private func content(visiblePhotos: [LibraryPhoto], topPickURLs: Set<URL>) -> some View {
        let displayedPhotos = displayedPhotos(from: visiblePhotos)
        let editablePhotos = displayedPhotos.filter { !$0.missing }
        let offlineCount = displayedPhotos.count - editablePhotos.count
        let projectIsEmpty = library.selectedProjectID.flatMap { id in library.projects.first { $0.id == id } }
            .map { $0.photoPaths.isEmpty } ?? false
        return VStack(spacing: 0) {
            HStack(spacing: StudioStyle.Space.compact) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentScopeLabel).font(.system(size: 10, weight: .semibold)).tracking(1.0).foregroundStyle(.secondary)
                    HStack(spacing: 7) {
                        Text(currentTitle).font(.system(size: 20, weight: .semibold)).lineLimit(1)
                        Text("\(displayedPhotos.count) photos").font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 18)
                TextField("Search Library", text: $library.searchText)
                    .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 170)
                Menu {
                    ForEach(LibrarySort.allCases) { sort in
                        Button {
                            library.sort = sort
                        } label: {
                            if library.sort == sort { Label(sort.title, systemImage: "checkmark") }
                            else { Text(sort.title) }
                        }
                    }
                } label: {
                    Label(library.sort.title, systemImage: "arrow.up.arrow.down")
                        .font(.callout)
                }
                .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                .help("Sort photos")
                Menu {
                    Button("Add Source Folder…", systemImage: "folder.badge.plus", action: importFolders)
                    Button("Refresh Folders", systemImage: "arrow.clockwise") { Task { await library.refresh() } }
                    Divider()
                    Button("Import Project…", systemImage: "square.and.arrow.down", action: openProjectPanel)
                    if let projectID = library.selectedProjectID {
                        Button("Export Project…", systemImage: "square.and.arrow.up") {
                            exportProjectPanel(projectID)
                        }
                    }
                    Divider()
                    Slider(value: $thumbnailSize, in: 120...256) { Text("Thumbnail Size") }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                .help("Library actions and thumbnail size")
                Button { showInspector.toggle() } label: {
                    Label("Details", systemImage: "sidebar.right")
                        .foregroundStyle(showInspector ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help(showInspector ? "Hide photo details" : "Show photo details")
                Spacer(minLength: 4)
            }
            .controlSize(.small)
            .padding(.horizontal, StudioStyle.Space.section).padding(.vertical, 11)
            Divider()
            HStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                Button {
                    Task { await library.analyzeCull(replacingExisting: library.photos.allSatisfy { $0.cull != nil }) }
                } label: {
                    if library.analyzingCull { ProgressView().controlSize(.small) }
                    else { Label(library.photos.contains(where: { $0.cull != nil }) ? "Re-analyze" : "AI Cull", systemImage: "sparkles") }
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(library.analyzingCull || !library.photos.contains(where: { !$0.missing }))
                .help(library.analyzingCull ? "Analyzing photo \(library.cullProgress) of \(library.cullTotal)" : "Analyze photos locally with Apple Vision")
                if library.analyzingCull {
                    ProgressView(value: Double(library.cullProgress), total: Double(max(library.cullTotal, 1)))
                        .frame(width: 64).help("AI culling progress")
                }
                if !cullFilters.isEmpty { Rectangle().fill(StudioStyle.outline).frame(width: 1, height: 20).padding(.horizontal, 2) }
                Button { showingFilterOptions = true } label: {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.bordered).controlSize(.small).fixedSize()
                .disabled(cullFilters.count >= addableCullFilters.count)
                .popover(isPresented: $showingFilterOptions, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: StudioStyle.Space.tight) {
                        Text("FILTER PHOTOS")
                            .font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.bottom, 2)
                        Text("All selected filters must match.")
                            .font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 8)
                        ForEach(addableCullFilters.filter { !cullFilters.contains($0) }, id: \.self) { filter in
                            Button {
                                library.cullFilters.insert(filter)
                                showingFilterOptions = false
                            } label: {
                                Label(filterTitle(filter), systemImage: filter.symbol)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 6)
                        }
                        if !cullFilters.isEmpty {
                            Divider().padding(.vertical, 3)
                            Button("Clear Filters", systemImage: "xmark.circle") {
                                library.cullFilters.removeAll()
                                showingFilterOptions = false
                            }
                            .buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 6)
                        }
                    }
                    .padding(10).frame(width: 210)
                }
                ForEach(CullFilterChip.allCases.filter { cullFilters.contains($0) }, id: \.self) { filter in
                    HStack(spacing: 4) {
                        Text(filterTitle(filter))
                        Button { library.cullFilters.remove(filter) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.plain).help("Remove \(filterTitle(filter)) filter")
                    }
                    .font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 4)
                    .background(StudioStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(StudioStyle.accent.opacity(0.19), lineWidth: 0.7))
                }
                Button {
                    showingTopPickOptions = true
                } label: {
                    Label(cullFilters.contains(.topPicks) ? "Showing \(topPickLabel)" : topPickLabel,
                          systemImage: cullFilters.contains(.topPicks) ? "rosette" : "slider.horizontal.3")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .popover(isPresented: $showingTopPickOptions, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("TOP PICKS").font(.caption.weight(.semibold)).tracking(0.5)
                        Picker("Choose by", selection: $library.topPickUnit) {
                            Text("Photos").tag(TopPickUnit.images)
                            Text("Percent").tag(TopPickUnit.percent)
                        }
                        .pickerStyle(.segmented)
                        HStack {
                            Text("Quick sets").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Menu("Presets") {
                                Button("Top 4 photos") {
                                    library.topPickUnit = .images; library.topPickValue = 4
                                }
                                Button("Top 25 photos") {
                                    library.topPickUnit = .images; library.topPickValue = 25
                                }
                                Button("Top 23%") {
                                    library.topPickUnit = .percent; library.topPickValue = 23
                                }
                            }
                            .menuStyle(.borderlessButton).fixedSize()
                        }
                        HStack {
                            Text(library.topPickUnit == .images ? "Keep the highest-scoring photos" : "Keep the highest-scoring share")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            TextField("Value", value: $library.topPickValue, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 60).multilineTextAlignment(.trailing)
                            Stepper("Adjust top-pick value", value: $library.topPickValue,
                                    in: 1...(library.topPickUnit == .percent ? 100 : 10000))
                                .labelsHidden().fixedSize()
                            Text(library.topPickUnit == .percent ? "%" : "images")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        Text("Ranks analyzed photos in the current Library view, then keeps this number or percentage. Folder, project, search and category scope all apply.")
                            .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                        Button {
                            if cullFilters.contains(.topPicks) { library.cullFilters.remove(.topPicks) }
                            else { library.cullFilters.insert(.topPicks) }
                            showingTopPickOptions = false
                        } label: {
                            Label(cullFilters.contains(.topPicks) ? "Hide Top Picks" : "Show Top Picks",
                                  systemImage: cullFilters.contains(.topPicks) ? "eye.slash" : "rosette")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    .padding(14).frame(width: 320)
                }
                if library.analyzingCull {
                    Text("Analyzing \(library.cullProgress) / \(library.cullTotal)")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                    }
                }
                .scrollIndicators(.hidden)
                Spacer(minLength: 4)
                if offlineCount > 0 {
                    Text("\(editablePhotos.count) ready · \(offlineCount) offline")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                Button {
                    editFiltered(editablePhotos)
                } label: {
                    Label("Edit \(editablePhotos.count)", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(editablePhotos.isEmpty)
                Button {
                    exportFiltered(editablePhotos)
                } label: {
                    Label("Export \(editablePhotos.count)", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(editablePhotos.isEmpty)
                if library.selectedProjectID != nil {
                    Button("Add Photos…", systemImage: "plus", action: { showingProjectPhotoPicker = true })
                        .buttonStyle(.bordered).controlSize(.small)
                    if let projectID = library.selectedProjectID {
                        Button("Remove from Project", systemImage: "minus.circle") {
                            library.remove(editablePhotos, from: projectID)
                        }
                        .buttonStyle(.borderless).controlSize(.small)
                        .disabled(editablePhotos.isEmpty)
                    }
                } else if !library.projects.isEmpty {
                    Menu {
                        ForEach(library.projects.filter { $0.id != library.selectedProjectID }) { project in
                            Button(project.name, systemImage: "briefcase") {
                                library.add(editablePhotos, to: project.id)
                            }
                        }
                    } label: {
                        Label("Add to Project", systemImage: "briefcase")
                    }
                    .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                    .help("Add the filtered photos to a project")
                    .disabled(editablePhotos.isEmpty)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, StudioStyle.Space.section).padding(.vertical, StudioStyle.Space.compact)
            Divider()
            if offlineCount > 0 {
                Label("\(offlineCount) photos in this view are offline. Check the source folder and refresh.", systemImage: "externaldrive.badge.exclamationmark")
                    .font(.callout).foregroundStyle(.orange).padding(10)
            }
            if !library.loaded || library.refreshing && library.photos.isEmpty {
                ProgressView("Loading Library…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if displayedPhotos.isEmpty {
                VStack(spacing: 12) {
                    if projectIsEmpty {
                        ContentUnavailableView("Project Ready", systemImage: "briefcase",
                                               description: Text("Add photographs from your imported source folders. The project keeps a curated set; originals stay where they are."))
                        Button("Add Photos…", systemImage: "plus", action: { showingProjectPhotoPicker = true })
                            .buttonStyle(.borderedProminent)
                    } else {
                        ContentUnavailableView("No Photos Match", systemImage: "photo.on.rectangle.angled",
                                               description: Text(library.folders.isEmpty
                                                ? "Add a source folder to index photographs in place. Negs leaves the originals on disk."
                                                : "Adjust the active filters or choose another Library, project, or source folder."))
                        if library.folders.isEmpty {
                            Button("Add Source Folder…", action: importFolders).buttonStyle(.borderedProminent)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    photoGrid(displayedPhotos, topPickURLs: topPickURLs).padding(18)
                }
                .focusable()
                .focused($libraryGridFocused)
                .onKeyPress(.leftArrow) { moveLibrarySelection(by: -1); return .handled }
                .onKeyPress(.rightArrow) { moveLibrarySelection(by: 1); return .handled }
                .onKeyPress(characters: CharacterSet(charactersIn: "pxuPXU012345")) { press in
                    guard libraryGridFocused, let photo = library.selectedPhoto, !photo.missing else { return .ignored }
                    switch press.characters.lowercased() {
                    case "p": library.setFlag(.picked)
                    case "x": library.setFlag(.rejected)
                    case "u": library.setFlag(.none)
                    case "0"..."5": if let rating = Int(press.characters) { library.setRating(rating) }
                    default: return .ignored
                    }
                    return .handled
                }
            }
        }
        .background(StudioStyle.window)
    }

    private func inspector(topPickURLs: Set<URL>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudioStyle.Space.standard) {
                Text("Selected Photo").font(.headline)
                if let photo = selected {
                    LibraryPreview(file: photo.file, size: 205)
                    Text(photo.file.name).font(.headline).textSelection(.enabled).lineLimit(3)
                    metadataRow("Folder", library.folders.first { $0.id == photo.folderID }?.name ?? "Unavailable")
                    metadataRow("Format", photo.file.url.pathExtension.uppercased())
                    metadataRow("File Size", photo.file.size.map(formatBytes) ?? "—")
                    metadataRow("Modified", photo.file.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    if photo.missing {
                        Label("Original is offline", systemImage: "externaldrive.badge.exclamationmark").foregroundStyle(.orange)
                    }
                    Divider()
                    Text("Rating").font(.subheadline.weight(.semibold))
                    HStack(spacing: 3) {
                        ForEach(1...5, id: \.self) { score in
                            Button { library.setRating(score) } label: {
                                Image(systemName: score <= photo.rating ? "star.fill" : "star")
                                    .foregroundStyle(score <= photo.rating ? .yellow : .secondary)
                            }.buttonStyle(.plain).help("Rate \(score) stars")
                        }
                        Button { library.setRating(0) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain).help("Clear rating")
                    }
                    Divider()
                    Text("Culling Analysis").font(.subheadline.weight(.semibold))
                    Text("AI-assisted, not AI-only: Vision models assess aesthetics and face quality; sharpness, exposure and framing are measured signals. The combined score is a ranking aid, not confidence or a personal preference model.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let cull = photo.cull {
                        if cull.failed {
                            Label("Analysis unavailable", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text("\(cull.score)").font(.title2.weight(.bold).monospacedDigit())
                                Text("/ 100").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(cull.hardReject ? "Reject" : topPickURLs.contains(photo.file.url) ? "Top of View" : "Review")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(cull.hardReject ? StudioStyle.negative : topPickURLs.contains(photo.file.url) ? StudioStyle.positive : .secondary)
                            }
                            metadataRow("Sharpness", "\(cull.sharpness) / 100")
                            if let faceSharpness = cull.faceSharpness {
                                metadataRow("Face Focus", "\(faceSharpness) / 100")
                            }
                            if let faceCaptureQuality = cull.faceCaptureQuality {
                                metadataRow("Face Quality", "\(faceCaptureQuality) / 100")
                            }
                            if let exposure = cull.exposure {
                                metadataRow("Exposure", "\(exposure) / 100")
                            }
                            if let faceExposure = cull.faceExposure {
                                metadataRow("Face Exposure", "\(faceExposure) / 100")
                            }
                            if let clipped = cull.clippedHighlightsPercent {
                                metadataRow("Clipped Highlights", String(format: "%.1f%%", clipped))
                            }
                            if let crushed = cull.crushedShadowsPercent {
                                metadataRow("Crushed Shadows", String(format: "%.1f%%", crushed))
                            }
                            metadataRow("Aesthetic AI", cull.aesthetics.map { "\($0) / 100" } ?? "Unavailable")
                            metadataRow("Composition", cull.composition.map { "\($0) / 100 · subject placement" } ?? "Unavailable")
                            metadataRow("Eyes", cull.eyesOpen.map { $0 ? "Open" : "Possibly closed" } ?? "Not applicable / unknown")
                            metadataRow("Faces", "\(cull.faceCount)")
                            ForEach(cull.reasons, id: \.self) { reason in
                                Label(reason, systemImage: "info.circle")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } else {
                        Text("Run AI Cull for focus, eyes, composition and aesthetic scores on this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Analyze Library", systemImage: "sparkles") {
                            Task { await library.analyzeCull() }
                        }.buttonStyle(.bordered)
                    }
                    Divider()
                    HStack(spacing: 8) {
                        Button {
                            library.setFlag(photo.flag == .picked ? .none : .picked)
                        } label: {
                            Label(photo.flag == .picked ? "Picked" : "Pick", systemImage: "flag.fill")
                        }
                        .buttonStyle(.bordered)
                        .tint(photo.flag == .picked ? .accentColor : .secondary)
                        Button {
                            library.setFlag(photo.flag == .rejected ? .none : .rejected)
                        } label: {
                            Label("Reject", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)
                        .tint(photo.flag == .rejected ? .red : .secondary)
                    }
                    Toggle("Client Pick", isOn: Binding(get: { photo.clientPicked }, set: { library.setClientPick($0) }))
                    Toggle("Queue for Export", isOn: Binding(get: { photo.selectedForExport }, set: { library.setExportQueued($0) }))
                    if !library.albums.isEmpty {
                        Menu("Add to Album", systemImage: "rectangle.stack.badge.plus") {
                            ForEach(library.albums) { album in
                                Button(album.name) { library.addSelectedPhoto(to: album.id) }
                            }
                        }
                    }
                    if !library.projects.isEmpty {
                        Menu("Project Membership", systemImage: "folder.badge.plus") {
                            ForEach(library.projects) { project in
                                let contains = project.photoPaths.contains(photo.file.url.standardizedFileURL.path)
                                Button {
                                    library.toggleSelectedPhoto(in: project.id)
                                } label: {
                                    Label(project.name, systemImage: contains ? "checkmark" : "plus")
                                }
                            }
                        }
                    }
                    Button("Edit Photo", systemImage: "slider.horizontal.3") { model.open(photo.file.url) }
                        .buttonStyle(.borderedProminent).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ContentUnavailableView("No Selection", systemImage: "photo")
                }
            }
            .padding(16)
        }
        .background(StudioStyle.sidebar)
    }

    private var albumSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Album").font(.headline)
            TextField("Album name", text: $albumName)
                .textFieldStyle(.roundedBorder).frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel") { showingAlbumSheet = false }
                Button("Create") {
                    library.createAlbum(named: albumName)
                    showingAlbumSheet = false
                }.keyboardShortcut(.defaultAction).disabled(albumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20)
    }

    private var smartCollectionSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Smart Collection").font(.headline)
            TextField("Collection name", text: $smartName).textFieldStyle(.roundedBorder).frame(width: 320)
            Picker("Rule", selection: $smartFilter) {
                ForEach(LibraryFilter.allCases.filter { $0 != .all }) { filter in Text(filter.title).tag(filter) }
            }
            HStack {
                Spacer()
                Button("Cancel") { showingSmartSheet = false }
                Button("Save") {
                    library.createSmartCollection(named: smartName, filter: smartFilter)
                    showingSmartSheet = false
                }.keyboardShortcut(.defaultAction).disabled(smartName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20)
    }

    private var projectSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Project").font(.headline)
            TextField("Project name", text: $projectName)
                .textFieldStyle(.roundedBorder).frame(width: 320)
            Text("A project is a work set of photos. Add images from any source folder; originals stay in their folders.")
                .font(.caption).foregroundStyle(.secondary).frame(width: 320, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel") { showingProjectSheet = false }
                Button("Create") {
                    library.createProject(named: projectName)
                    showingProjectSheet = false
                }.keyboardShortcut(.defaultAction).disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20)
    }

    private var currentTitle: String {
        if let project = library.projects.first(where: { $0.id == library.selectedProjectID }) { return project.name }
        if let album = library.albums.first(where: { $0.id == library.selectedAlbumID }) { return album.name }
        if let collection = library.smartCollections.first(where: { $0.id == library.selectedSmartCollectionID }) { return collection.name }
        if let folder = library.folders.first(where: { $0.id == library.selectedFolderID }) { return folder.name }
        return library.filter.title
    }

    private var currentScopeLabel: String {
        if library.selectedProjectID != nil { return "PROJECT · CURATED SET" }
        if library.selectedFolderID != nil { return "FOLDER · SOURCE LOCATION" }
        if library.selectedAlbumID != nil { return "ALBUM · MANUAL SELECTION" }
        if library.selectedSmartCollectionID != nil { return "SMART COLLECTION" }
        return "LIBRARY"
    }

    private func sidebarSection<Content: View>(_ title: String, actionTitle: String? = nil,
                                               action: (() -> Void)? = nil,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.caption2.weight(.semibold)).tracking(0.65).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 7)
            content()
        }
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.caption)
    }

    private func photoGrid(_ photos: [LibraryPhoto], topPickURLs: Set<URL>) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 9)], spacing: 11) {
            ForEach(photos) { photo in
                LibraryPhotoCard(photo: photo, selected: photo.file.url == library.selectedPhotoURL,
                                 isTopPick: topPickURLs.contains(photo.file.url) && photo.cull?.hardReject != true,
                                 size: CGFloat(thumbnailSize)) {
                    library.selectedPhotoURL = photo.file.url
                    libraryGridFocused = true
                } open: {
                    model.openLibraryPhoto(photo.file.url)
                } setFlag: { flag in
                    library.setFlag(flag, for: photo.file.url)
                } setRating: { rating in
                    library.setRating(rating, for: photo.file.url)
                }
            }
        }
    }

    private func moveLibrarySelection(by offset: Int) {
        let photos = displayedPhotos(from: library.visiblePhotos).filter { !$0.missing }
        guard !photos.isEmpty else { return }
        let current = photos.firstIndex { $0.file.url == library.selectedPhotoURL }
        let next = min(max((current ?? (offset > 0 ? -1 : photos.count)) + offset, 0), photos.count - 1)
        library.selectedPhotoURL = photos[next].file.url
    }

    private func editFiltered(_ editablePhotos: [LibraryPhoto]) {
        let urls = editablePhotos.map(\.file.url)
        guard !urls.isEmpty else { return }
        model.editLibrarySelection(urls)
    }

    private func exportFiltered(_ editablePhotos: [LibraryPhoto]) {
        editFiltered(editablePhotos)
        model.exportPanel()
    }

    @MainActor private func importFolders() {
        let panel = NSOpenPanel()
        panel.title = "Import Folders into Library"
        panel.prompt = "Import"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            Task { await library.importFolders(panel.urls) }
        }
    }

    @MainActor private func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Negs Project"
        panel.prompt = "Open"
        panel.allowedContentTypes = [.negsProject]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { try await library.importProject(from: url) }
                catch { Self.showProjectError(error) }
            }
        }
    }

    @MainActor private func exportProjectPanel(_ projectID: UUID) {
        guard let project = library.projects.first(where: { $0.id == projectID }) else { return }
        let panel = NSSavePanel()
        panel.title = "Export Negs Project"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.negsProject]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(project.name).negproject"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { try library.exportProject(projectID, to: url) }
                catch { Self.showProjectError(error) }
            }
        }
    }

    @MainActor private static func showProjectError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Project Couldn’t Be Opened or Exported"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

}

private struct NavigationRow: View {
    let title: String
    let symbol: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 17)
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 3)
                Text("\(count)").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(selected ? StudioStyle.accent.opacity(0.15) : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(StudioStyle.accent.opacity(0.28), lineWidth: 0.7)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
    }
}

private struct ProjectPhotoPicker: View {
    @Bindable var library: PhotoLibrary
    let projectID: UUID
    let addSourceFolder: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sourceFolderID: UUID?
    @State private var searchText = ""
    @State private var selectedURLs = Set<URL>()

    private var project: LibraryProject? { library.projects.first { $0.id == projectID } }
    private var candidates: [LibraryPhoto] {
        guard let project else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.photos.filter { photo in
            !photo.missing
                && !project.photoPaths.contains(photo.file.url.standardizedFileURL.path)
                && (sourceFolderID == nil || photo.folderID == sourceFolderID)
                && (query.isEmpty || photo.file.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add Photos to Project").font(.title3.weight(.semibold))
                    Text(project?.name ?? "Project")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("All Source Folders") { sourceFolderID = nil }
                    Divider()
                    ForEach(library.folders) { folder in
                        Button(folder.name) { sourceFolderID = folder.id }
                    }
                } label: {
                    Label(library.folders.first { $0.id == sourceFolderID }?.name ?? "All Source Folders",
                          systemImage: "folder")
                }
                .menuStyle(.borderlessButton).fixedSize()
                TextField("Search filenames", text: $searchText)
                    .textFieldStyle(.roundedBorder).frame(width: 210)
            }
            .padding(18)
            Divider()
            HStack(spacing: 12) {
                Text("\(candidates.count) available")
                    .foregroundStyle(.secondary).monospacedDigit()
                Button("Select All") { selectedURLs.formUnion(candidates.map(\.file.url)) }
                    .buttonStyle(.borderless).disabled(candidates.isEmpty)
                Button("Clear") { selectedURLs.removeAll() }
                    .buttonStyle(.borderless).disabled(selectedURLs.isEmpty)
                Spacer()
                Text("\(selectedURLs.count) selected")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
            .padding(.horizontal, 18).padding(.vertical, 10)
            Divider()
            if candidates.isEmpty {
                VStack(spacing: 12) {
                    ContentUnavailableView("No Available Photos", systemImage: "photo.on.rectangle.angled",
                                           description: Text(library.folders.isEmpty
                                            ? "Add a source folder to the Library first."
                                            : "Every photo in this source is already in the project, or no photos match your search."))
                    if library.folders.isEmpty {
                        Button("Add Source Folder…", action: addSourceFolder)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 14) {
                        ForEach(candidates) { photo in
                            ProjectPhotoChoice(photo: photo, selected: selectedURLs.contains(photo.file.url)) {
                                if selectedURLs.contains(photo.file.url) {
                                    selectedURLs.remove(photo.file.url)
                                } else {
                                    selectedURLs.insert(photo.file.url)
                                }
                            }
                        }
                    }
                    .padding(18)
                }
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add \(selectedURLs.count) Photos") {
                    library.add(library.photos.filter { selectedURLs.contains($0.file.url) }, to: projectID)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedURLs.isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 720, minHeight: 540)
        .preferredColorScheme(.dark)
    }
}

private struct ProjectPhotoChoice: View {
    let photo: LibraryPhoto
    let selected: Bool
    let action: () -> Void
    @State private var image: CGImage?

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 8).fill(StudioStyle.plot)
                    if let image {
                        Image(decorative: image, scale: 2).resizable().scaledToFit().padding(5)
                    } else {
                        Image(systemName: "photo").foregroundStyle(.tertiary)
                    }
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3).symbolRenderingMode(.palette)
                        .foregroundStyle(selected ? StudioStyle.accent : .white.opacity(0.85), .black.opacity(0.55))
                        .padding(7)
                }
                .frame(height: 124)
                Text(photo.file.name).font(.caption).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.primary)
            }
            .padding(5)
            .background(selected ? StudioStyle.accent.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? StudioStyle.accent : StudioStyle.outline, lineWidth: selected ? 1.2 : 0.7))
        }
        .buttonStyle(.plain)
        .task(id: photo.file) {
            let result = await PhotoThumbnails.shared.image(for: photo.file)
            guard !Task.isCancelled else { return }
            image = result
        }
    }
}

private struct LibraryPhotoCard: View {
    let photo: LibraryPhoto
    let selected: Bool
    let isTopPick: Bool
    let size: CGFloat
    let select: () -> Void
    let open: () -> Void
    let setFlag: (LibraryFlag) -> Void
    let setRating: (Int) -> Void
    @State private var image: CGImage?
    @State private var hovered = false

    var body: some View {
        Button(action: select) { cardContent }
        .buttonStyle(.plain)
        .onTapGesture(count: 2, perform: open)
        .contextMenu {
            Button("Open in Editor", systemImage: "slider.horizontal.3", action: open)
            Divider()
            Button(photo.flag == .picked ? "Clear Pick" : "Pick", systemImage: "flag.fill") {
                setFlag(photo.flag == .picked ? .none : .picked)
            }
            Button(photo.flag == .rejected ? "Clear Reject" : "Reject", systemImage: "xmark.circle") {
                setFlag(photo.flag == .rejected ? .none : .rejected)
            }
            Menu("Rating") {
                ForEach(0...5, id: \.self) { score in
                    Button(score == 0 ? "Unrated" : "\(score) Stars") { setRating(score) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(photo.file.name)
        .accessibilityValue("\(photo.rating) stars, \(photo.flag.title)")
        .task(id: photo.file) {
            guard !photo.missing else { image = nil; return }
            let request = Task.detached(priority: .utility) { await PhotoThumbnails.shared.image(for: photo.file) }
            let result = await withTaskCancellationHandler { await request.value } onCancel: { request.cancel() }
            guard !Task.isCancelled else { return }
            image = result
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            thumbnail
            Text(photo.file.name).font(.caption).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
            photoBadges
            if let cull = photo.cull {
                HStack(spacing: 4) {
                    Text(cull.failed ? "Cull unavailable" : "Cull \(cull.score)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded)).monospacedDigit()
                    if isTopPick { Text("TOP PICK").font(.system(size: 8, weight: .bold)).tracking(0.3) }
                }
                .foregroundStyle(isTopPick ? StudioStyle.positive : cull.hardReject ? StudioStyle.negative : Color.secondary)
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? StudioStyle.panel.opacity(0.88) : hovered ? StudioStyle.panel.opacity(0.48) : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? StudioStyle.accent.opacity(0.95) : Color.white.opacity(hovered ? 0.10 : 0),
                              lineWidth: selected ? 1.2 : 0.7)
        }
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.easeOut(duration: 0.12), value: selected)
        .contentShape(Rectangle())
    }

    private var thumbnail: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioStyle.plot)
            if let image {
                Image(decorative: image, scale: 2).resizable().scaledToFit().padding(4)
            } else if photo.missing {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.title2).foregroundStyle(.orange)
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
            if photo.flag == .picked {
                Image(systemName: "flag.fill").foregroundStyle(.green).padding(7)
            } else if photo.flag == .rejected {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red).padding(7)
            }
        }
        // Match the grid zoom to the actual image area so portrait frames remain
        // legible at the user's chosen thumbnail size.
        .frame(height: size)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? StudioStyle.accent : Color.white.opacity(0.045), lineWidth: selected ? 1.2 : 0.6)
        }
    }

    private var photoBadges: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { score in
                Image(systemName: score <= photo.rating ? "star.fill" : "star")
                    .font(.system(size: 9)).foregroundStyle(score <= photo.rating ? Color.yellow : Color.secondary)
            }
            if photo.clientPicked {
                Image(systemName: "heart.fill").font(.system(size: 9)).foregroundStyle(.pink).padding(.leading, 4)
            }
            Spacer(minLength: 0)
            if photo.selectedForExport {
                Image(systemName: "square.and.arrow.up").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct LibraryPreview: View {
    let file: PhotoFile
    let size: CGFloat
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.045))
            if let image { Image(decorative: image, scale: 2).resizable().scaledToFit().padding(5) }
            else { Image(systemName: "photo").foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity).frame(height: size * 0.66)
        .task(id: file) {
            let request = Task.detached(priority: .utility) { await PhotoThumbnails.shared.image(for: file) }
            image = await request.value
        }
    }
}
