import AppKit
import SwiftUI

struct LibraryWorkspaceView: View {
    let model: EditorModel
    @Bindable private var library: PhotoLibrary
    @AppStorage("negs.library.thumbnailSize") private var thumbnailSize = 176.0
    @AppStorage("negs.library.showInspector") private var showInspector = true
    @State private var showingAlbumSheet = false
    @State private var showingSmartSheet = false
    @State private var showingProjectSheet = false
    @State private var albumName = ""
    @State private var smartName = ""
    @State private var projectName = ""
    @State private var smartFilter: LibraryFilter = .picked
    @State private var cullFilters = Set<CullFilterChip>()

    private var selected: LibraryPhoto? { library.selectedPhoto }
    private var displayedPhotos: [LibraryPhoto] {
        library.visiblePhotos.filter { photo in
            cullFilters.allSatisfy { filter in
                switch filter {
                case .eyesOpen: photo.cull?.eyesOpen == true
                case .sharp: (photo.cull?.sharpness ?? -1) >= 70
                case .aiScore: (photo.cull?.score ?? -1) >= 70
                case .topPicks: library.topPickURLs.contains(photo.file.url)
                case .rejects: photo.cull?.hardReject == true
                }
            }
        }
    }

    init(model: EditorModel) {
        self.model = model
        self._library = Bindable(wrappedValue: model.photoLibrary)
    }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 184, idealWidth: 218, maxWidth: 270)
            content.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            if showInspector {
                inspector.frame(minWidth: 230, idealWidth: 270, maxWidth: 360)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await library.load() }
        .sheet(isPresented: $showingAlbumSheet) { albumSheet }
        .sheet(isPresented: $showingSmartSheet) { smartCollectionSheet }
        .sheet(isPresented: $showingProjectSheet) { projectSheet }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("NAVIGATOR").font(.caption.weight(.semibold)).tracking(0.7).foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit", systemImage: "slider.horizontal.3") { editSelected() }
                        .labelStyle(.iconOnly).disabled(selected == nil)
                        .help("Open selected photo in the editor")
                }
                if let selected {
                    LibraryPreview(file: selected.file, size: 150)
                    Text(selected.file.name).font(.caption).lineLimit(2).truncationMode(.middle)
                    Button("Open in Editor", systemImage: "slider.horizontal.3") { editSelected() }
                        .buttonStyle(.bordered).disabled(!selected.file.url.isFileURL)
                } else {
                    Label("Select a photo", systemImage: "photo")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 86)
                }

                Divider()
                sidebarSection("LIBRARY") {
                    ForEach(LibraryFilter.allCases) { filter in
                        NavigationRow(title: filter.title, symbol: filter.symbol,
                                      count: library.count(for: filter), selected: library.selectedAlbumID == nil
                                        && library.selectedFolderID == nil && library.selectedSmartCollectionID == nil
                                        && library.selectedProjectID == nil
                                        && library.filter == filter) {
                            library.filter = filter
                            library.selectedFolderID = nil
                            library.selectedAlbumID = nil
                            library.selectedSmartCollectionID = nil
                            library.selectedProjectID = nil
                        }
                    }
                }
                sidebarSection("PROJECTS") {
                    ForEach(library.projects) { project in
                        NavigationRow(title: project.name, symbol: "folder.badge.gearshape",
                                      count: library.count(for: project), selected: library.selectedProjectID == project.id) {
                            library.selectedProjectID = project.id
                            library.selectedFolderID = nil
                            library.selectedAlbumID = nil
                            library.selectedSmartCollectionID = nil
                            library.filter = .all
                        }
                        .contextMenu {
                            Button("Delete Project", systemImage: "trash", role: .destructive) {
                                library.deleteProject(project.id)
                            }
                        }
                    }
                    Button { projectName = ""; showingProjectSheet = true } label: {
                        Label("New Project…", systemImage: "plus")
                            .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).foregroundStyle(.tint)
                }
                sidebarSection("FOLDERS") {
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
                            .contextMenu {
                                Button("Refresh Folder", systemImage: "arrow.clockwise") { Task { await library.refresh() } }
                                Button("Remove from Library", systemImage: "minus.circle", role: .destructive) { library.removeFolder(folder.id) }
                            }
                        }
                    }
                    Button(action: importFolders) {
                        Label("Import Folder…", systemImage: "plus")
                            .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).foregroundStyle(.tint)
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
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.52))
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentTitle).font(.title2.weight(.semibold))
                    Text("\(displayedPhotos.count) photos")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 12)
                TextField("Search Library", text: $library.searchText)
                    .textFieldStyle(.roundedBorder).frame(width: 210)
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
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }.help("Sort photos")
                Button {
                    Task { await library.analyzeCull(replacingExisting: library.photos.allSatisfy { $0.cull != nil }) }
                } label: {
                    if library.analyzingCull { ProgressView().controlSize(.small) }
                    else { Label(library.photos.contains(where: { $0.cull != nil }) ? "Re-analyze" : "AI Cull", systemImage: "sparkles") }
                }
                .disabled(library.analyzingCull || !library.photos.contains(where: { !$0.missing }))
                .help(library.analyzingCull ? "Analyzing photo \(library.cullProgress) of \(library.cullTotal)" : "Analyze photos locally with Apple Vision")
                Button(action: { Task { await library.refresh() } }) {
                    if library.refreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }.help("Refresh imported folders")
                Menu("Project", systemImage: "folder.badge.gearshape") {
                    Button("Open Project…", systemImage: "folder", action: openProjectPanel)
                    if let projectID = library.selectedProjectID {
                        Button("Export Project…", systemImage: "square.and.arrow.up") {
                            exportProjectPanel(projectID)
                        }
                    }
                }
                Button(action: importFolders) { Label("Import", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                Slider(value: $thumbnailSize, in: 120...256)
                    .frame(width: 100).help("Thumbnail size")
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider()
            HStack(spacing: 8) {
                Menu {
                    ForEach(CullFilterChip.allCases.filter { !cullFilters.contains($0) }, id: \.self) { filter in
                        Button(filter.title, systemImage: filter.symbol) { cullFilters.insert(filter) }
                    }
                    if !cullFilters.isEmpty {
                        Divider()
                        Button("Clear Filters", systemImage: "xmark.circle") { cullFilters.removeAll() }
                    }
                } label: { Label("Add Filter", systemImage: "line.3.horizontal.decrease.circle") }
                    .disabled(cullFilters.count == CullFilterChip.allCases.count)
                ForEach(CullFilterChip.allCases.filter { cullFilters.contains($0) }, id: \.self) { filter in
                    HStack(spacing: 4) {
                        Text(filter.title)
                        Button { cullFilters.remove(filter) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.plain).help("Remove \(filter.title) filter")
                    }
                    .font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                Spacer(minLength: 0)
                if library.analyzingCull {
                    Text("Analyzing \(library.cullProgress) / \(library.cullTotal)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
            Divider()
            if let error = library.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).padding(10)
            }
            if !library.loaded || library.refreshing && library.photos.isEmpty {
                ProgressView("Loading Library…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if displayedPhotos.isEmpty {
                VStack(spacing: 12) {
                    ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle.angled",
                                           description: Text(library.folders.isEmpty
                                            ? "Import a folder to build your Library. Negs keeps the originals where they are."
                                            : "No photos match this Library view."))
                    Button("Import Folder…", action: importFolders).buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 14)], spacing: 18) {
                        ForEach(displayedPhotos) { photo in
                            LibraryPhotoCard(photo: photo, selected: photo.file.url == library.selectedPhotoURL,
                                             isTopPick: library.topPickURLs.contains(photo.file.url), size: CGFloat(thumbnailSize)) {
                                library.selectedPhotoURL = photo.file.url
                            } open: {
                                model.open(photo.file.url)
                            } setFlag: { flag in
                                library.setFlag(flag, for: photo.file.url)
                            } setRating: { rating in
                                library.setRating(rating, for: photo.file.url)
                            }
                        }
                    }
                    .padding(18)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("DETAILS").font(.caption.weight(.semibold)).tracking(0.7).foregroundStyle(.secondary)
                if let photo = selected {
                    LibraryPreview(file: photo.file, size: 230)
                    Text(photo.file.name).font(.headline).textSelection(.enabled).lineLimit(3)
                    metadataRow("Folder", library.folders.first { $0.id == photo.folderID }?.name ?? "Unavailable")
                    metadataRow("Format", photo.file.url.pathExtension.uppercased())
                    metadataRow("File Size", photo.file.size.map(formatBytes) ?? "—")
                    metadataRow("Modified", photo.file.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    if photo.missing {
                        Label("Original is offline", systemImage: "externaldrive.badge.exclamationmark").foregroundStyle(.orange)
                    }
                    Divider()
                    Text("RATING").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
                    Text("CULL").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if let cull = photo.cull {
                        if cull.failed {
                            Label("Analysis unavailable", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(cull.score)").font(.title2.weight(.bold).monospacedDigit())
                                Text("/ 100 · \(library.topPickURLs.contains(photo.file.url) ? "Top Pick" : cull.hardReject ? "Reject" : "Review")")
                                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            }
                            metadataRow("Sharpness", "\(cull.sharpness) / 100")
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
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.52))
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
            Text("Imported folders will be added to this project. You can also add selected photos from the inspector.")
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

    private func sidebarSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption2.weight(.semibold)).tracking(0.65).foregroundStyle(.secondary).padding(.horizontal, 7)
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

    private func editSelected() {
        if let photo = selected { model.open(photo.file.url) }
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
            .background(selected ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
    }
}

private enum CullFilterChip: CaseIterable, Hashable {
    case eyesOpen, sharp, aiScore, topPicks, rejects
    var title: String {
        switch self {
        case .eyesOpen: "Eyes Open"
        case .sharp: "Sharpness 70+"
        case .aiScore: "AI Score 70+"
        case .topPicks: "Top 25%"
        case .rejects: "Rejects"
        }
    }
    var symbol: String {
        switch self {
        case .eyesOpen: "eye"
        case .sharp: "viewfinder"
        case .aiScore: "sparkles"
        case .topPicks: "rosette"
        case .rejects: "xmark.circle"
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
        VStack(alignment: .leading, spacing: 6) {
            thumbnail
            Text(photo.file.name).font(.caption).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
            photoBadges
            if let cull = photo.cull {
                HStack(spacing: 4) {
                    Text(cull.failed ? "Cull unavailable" : "AI \(cull.score)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded)).monospacedDigit()
                    if isTopPick { Text("TOP PICK").font(.system(size: 8, weight: .bold)).tracking(0.3) }
                }
                .foregroundStyle(isTopPick ? Color.green : cull.hardReject ? Color.red : Color.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42), in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
    }

    private var thumbnail: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.045))
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
        .frame(height: size * 0.69)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
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
