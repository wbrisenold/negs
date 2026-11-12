import AppKit
import Observation
import UniformTypeIdentifiers
import Vision

// Adapted from Whittle's BurstClusterEngine, Copyright (c) 2026 Surendran
// Balachandran, MIT licensed. Source: https://github.com/surendranb/whittle

extension UTType {
    static let negsProject = UTType(filenameExtension: "negproject", conformingTo: .json) ?? .json
}

/// Reused temporal and single-linkage grouping from Whittle's MIT-licensed
/// `ClusterEngine` (https://github.com/surendranb/whittle).
private struct BurstTimedItem: Equatable {
    let id: String
    let date: Date?
}

private enum BurstClusterEngine {
    static func temporalGroups(_ items: [BurstTimedItem], maxGap: TimeInterval) -> [[BurstTimedItem]] {
        let dated = items.filter { $0.date != nil }.sorted { $0.date! < $1.date! }
        guard let first = dated.first else { return [] }
        var groups: [[BurstTimedItem]] = []
        var current = [first]
        for item in dated.dropFirst() {
            if item.date!.timeIntervalSince(current.last!.date!) <= maxGap {
                current.append(item)
            } else {
                groups.append(current)
                current = [item]
            }
        }
        groups.append(current)
        return groups
    }

    static func visualSubclusters(
        _ ids: [String], threshold: Double,
        distance: (String, String) -> Double?
    ) -> [[String]] {
        var clusters: [[String]] = []
        for id in ids {
            if let index = clusters.indices.first(where: { index in
                clusters[index].contains { member in
                    guard let measured = distance(id, member) else { return false }
                    return measured <= threshold
                }
            }) {
                clusters[index].append(id)
            } else {
                clusters.append([id])
            }
        }
        return clusters
    }
}

enum LibraryFlag: String, CaseIterable, Codable, Identifiable, Sendable {
    case none, picked, rejected
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "Unflagged"
        case .picked: "Picked"
        case .rejected: "Rejected"
        }
    }
}

enum LibraryFilter: String, CaseIterable, Codable, Identifiable, Sendable {
    case all, picked, clientPicks, rejected, unrated, fiveStar, exportQueued, missing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All Photos"
        case .picked: "Picked"
        case .clientPicks: "Client Picks"
        case .rejected: "Rejected"
        case .unrated: "Unrated"
        case .fiveStar: "Five Stars"
        case .exportQueued: "Export Queue"
        case .missing: "Missing Files"
        }
    }
    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .picked: "flag.fill"
        case .clientPicks: "heart.fill"
        case .rejected: "xmark.circle"
        case .unrated: "star"
        case .fiveStar: "star.fill"
        case .exportQueued: "square.and.arrow.up"
        case .missing: "externaldrive.badge.exclamationmark"
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    case name, newest, oldest, cullScore, sharpness, aesthetics
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: "Name"
        case .newest: "Modified · Newest"
        case .oldest: "Modified · Oldest"
        case .cullScore: "Cull Score · Highest"
        case .sharpness: "Sharpness · Highest"
        case .aesthetics: "Aesthetics · Highest"
        }
    }
}

enum CullFilterChip: CaseIterable, Hashable, Sendable {
    case eyesOpen, sharp, exposure, aesthetics, composition, aiScore, topPicks, burstLeads, rejects
    var title: String {
        switch self {
        case .eyesOpen: "Eyes Open"
        case .sharp: "Sharpness 70+"
        case .exposure: "Exposure 70+"
        case .aesthetics: "Aesthetics 70+"
        case .composition: "Composition 70+"
        case .aiScore: "Cull Score 70+"
        case .topPicks: "Top Picks"
        case .burstLeads: "Burst Leads"
        case .rejects: "Rejects"
        }
    }
    var symbol: String {
        switch self {
        case .eyesOpen: "eye"
        case .sharp: "viewfinder"
        case .exposure: "sun.max"
        case .aesthetics: "sparkles"
        case .composition: "viewfinder.rectangular"
        case .aiScore: "sparkles"
        case .topPicks: "rosette"
        case .burstLeads: "square.stack.3d.up"
        case .rejects: "xmark.circle"
        }
    }
}

enum CullDecision: String, Codable, Sendable {
    case topPick, review, reject
    var title: String {
        switch self {
        case .topPick: "Top Pick"
        case .review: "Review"
        case .reject: "Reject"
        }
    }
}

enum TopPickUnit: String, CaseIterable, Identifiable {
    case images, percent
    var id: String { rawValue }
    var title: String { self == .images ? "images per scene" : "% per scene" }
}

/// Local Vision results plus transparent, deterministic technical signals.
/// A missing aesthetic score means this macOS version did not provide Apple's
/// on-device aesthetics request; it is never replaced with a guessed value.
struct CullAnalysis: Codable, Hashable, Sendable {
    var version: Int = 4
    var score: Int
    var sharpness: Int
    var faceSharpness: Int? = nil
    var faceCaptureQuality: Int? = nil
    var faceExposure: Int? = nil
    var exposure: Int? = nil
    var clippedHighlightsPercent: Double? = nil
    var crushedShadowsPercent: Double? = nil
    var sceneFingerprint: Data? = nil
    var captureDate: Date? = nil
    var aesthetics: Int?
    var composition: Int?
    var eyesOpen: Bool?
    var faceCount: Int
    var utilityImage: Bool
    var failed = false
    var reasons: [String]

    var hardReject: Bool {
        !failed && (eyesOpen == false || sharpness < 18 || (faceSharpness ?? 100) < 28
                    || (exposure ?? 100) < 18 || (faceExposure ?? 100) < 16 || score < 28 || utilityImage)
    }
}

struct LibraryPhoto: Codable, Hashable, Identifiable, Sendable {
    var file: PhotoFile
    var folderID: UUID
    var rating = 0
    var flag: LibraryFlag = .none
    var clientPicked = false
    var selectedForExport = false
    var missing = false
    var albumIDs = Set<UUID>()
    var cull: CullAnalysis?
    var id: URL { file.url }

    func matches(_ filter: LibraryFilter) -> Bool {
        switch filter {
        case .all: true
        case .picked: flag == .picked
        case .clientPicks: clientPicked
        case .rejected: flag == .rejected
        case .unrated: rating == 0
        case .fiveStar: rating == 5
        case .exportQueued: selectedForExport
        case .missing: missing
        }
    }
}

struct LibraryFolder: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var path: String
    var bookmark: Data?
    var name: String { URL(fileURLWithPath: path).lastPathComponent }

    func resolvedURL() -> URL {
        guard let bookmark else { return URL(fileURLWithPath: path) }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return URL(fileURLWithPath: path)
        }
        return url
    }
}

struct LibraryAlbum: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
}

struct SmartLibraryCollection: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var filter: LibraryFilter
}

struct LibraryProject: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var photoPaths = Set<String>()
}

private struct PhotoLibraryDocument: Codable, Sendable {
    var schema = 1
    var folders: [LibraryFolder] = []
    var photos: [LibraryPhoto] = []
    var albums: [LibraryAlbum] = []
    var smartCollections: [SmartLibraryCollection] = []
    var projects: [LibraryProject] = []
    var selectedProjectID: UUID?

    private enum CodingKeys: String, CodingKey {
        case schema, folders, photos, albums, smartCollections, projects, selectedProjectID
    }

    init() {}

    init(schema: Int = 1, folders: [LibraryFolder], photos: [LibraryPhoto], albums: [LibraryAlbum],
         smartCollections: [SmartLibraryCollection], projects: [LibraryProject] = [], selectedProjectID: UUID? = nil) {
        self.schema = schema
        self.folders = folders
        self.photos = photos
        self.albums = albums
        self.smartCollections = smartCollections
        self.projects = projects
        self.selectedProjectID = selectedProjectID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        folders = try container.decodeIfPresent([LibraryFolder].self, forKey: .folders) ?? []
        photos = try container.decodeIfPresent([LibraryPhoto].self, forKey: .photos) ?? []
        albums = try container.decodeIfPresent([LibraryAlbum].self, forKey: .albums) ?? []
        smartCollections = try container.decodeIfPresent([SmartLibraryCollection].self, forKey: .smartCollections) ?? []
        projects = try container.decodeIfPresent([LibraryProject].self, forKey: .projects) ?? []
        selectedProjectID = try container.decodeIfPresent(UUID.self, forKey: .selectedProjectID)
    }
}

private enum PhotoLibraryLoadError: Error, Sendable {
    case message(String)
}

private struct LibraryProjectDocument: Codable, Sendable {
    var formatVersion = 1
    var project: LibraryProject
    var folders: [LibraryFolder]
    var photos: [LibraryPhoto]
}

/// Persistent photo references and Lightroom-style culling metadata. Originals
/// stay in their folders; the catalog stores bookmarks and sidecar metadata.
@MainActor @Observable final class PhotoLibrary {
    private(set) var folders: [LibraryFolder] = []
    private(set) var photos: [LibraryPhoto] = [] {
        didSet { sceneGroupsCache = nil; topPicksCache = nil; burstLeadsCache = nil }
    }
    private(set) var albums: [LibraryAlbum] = []
    private(set) var smartCollections: [SmartLibraryCollection] = []
    private(set) var projects: [LibraryProject] = []
    var filter: LibraryFilter = .all
    /// Shared culling filters stay active as the user moves between Library and Edit.
    var cullFilters = Set<CullFilterChip>()
    var sort: LibrarySort = .name
    var searchText = ""
    var selectedFolderID: UUID?
    var selectedAlbumID: UUID?
    var selectedSmartCollectionID: UUID?
    var selectedProjectID: UUID?
    var selectedPhotoURL: URL?
    var topPickUnit: TopPickUnit = TopPickUnit(rawValue: UserDefaults.standard.string(forKey: "negs.library.topPickUnit") ?? "images") ?? .images {
        didSet {
            let maximum = topPickUnit == .percent ? 100 : 10000
            if topPickValue > maximum { topPickValue = maximum }
            UserDefaults.standard.set(topPickUnit.rawValue, forKey: "negs.library.topPickUnit")
        }
    }
    var topPickValue: Int = max(1, UserDefaults.standard.object(forKey: "negs.library.topPickValue") as? Int ?? 4) {
        didSet {
            let bounded = min(max(topPickValue, 1), topPickUnit == .percent ? 100 : 10000)
            if bounded != topPickValue { topPickValue = bounded; return }
            UserDefaults.standard.set(topPickValue, forKey: "negs.library.topPickValue")
        }
    }
    private(set) var loaded = false
    private(set) var refreshing = false
    private(set) var analyzingCull = false
    private(set) var cullProgress = 0
    private(set) var cullTotal = 0
    private(set) var error: String?
    @ObservationIgnored private var scopedFolders: [UUID: URL] = [:]
    @ObservationIgnored private var loadStarted = false
    @ObservationIgnored private var sceneGroupsCache: (scope: Set<URL>, groups: [[LibraryPhoto]])?
    @ObservationIgnored private var topPicksCache: (unit: TopPickUnit, value: Int, scope: Set<URL>, urls: Set<URL>)?
    @ObservationIgnored private var burstLeadsCache: (scope: Set<URL>, urls: Set<URL>)?

    private static let sceneDistanceThreshold = 0.45

    init() {
        let maximum = topPickUnit == .percent ? 100 : 10000
        topPickValue = min(max(topPickValue, 1), maximum)
    }

    private static var storeURL: URL {
        AppDataLocations.supportDirectory.appendingPathComponent("photo-library.json")
    }

    /// The active folder/project/album/search scope before its Library category filter.
    var scopePhotos: [LibraryPhoto] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let projectPaths = projects.first { $0.id == selectedProjectID }?.photoPaths
        let result = photos.filter { photo in
            let folder = folders.first { $0.id == photo.folderID }
            let albumMatches = selectedAlbumID.map { photo.albumIDs.contains($0) } ?? true
            let folderMatches = selectedFolderID.map { $0 == photo.folderID } ?? true
            let textMatches = query.isEmpty || photo.file.name.lowercased().contains(query)
                || (folder?.name.lowercased().contains(query) ?? false)
            let projectMatches = projectPaths?.contains(photo.file.url.standardizedFileURL.path) ?? true
            return projectMatches && albumMatches && folderMatches && textMatches
        }
        switch sort {
        case .name:
            return result.sorted { $0.file.name.localizedStandardCompare($1.file.name) == .orderedAscending }
        case .newest:
            return result.sorted { ($0.file.modified ?? .distantPast) > ($1.file.modified ?? .distantPast) }
        case .oldest:
            return result.sorted { ($0.file.modified ?? .distantFuture) < ($1.file.modified ?? .distantFuture) }
        case .cullScore:
            return result.sorted { ($0.cull?.score ?? -1) > ($1.cull?.score ?? -1) }
        case .sharpness:
            return result.sorted { ($0.cull?.faceSharpness ?? $0.cull?.sharpness ?? -1) > ($1.cull?.faceSharpness ?? $1.cull?.sharpness ?? -1) }
        case .aesthetics:
            return result.sorted { ($0.cull?.aesthetics ?? -1) > ($1.cull?.aesthetics ?? -1) }
        }
    }

    var visiblePhotos: [LibraryPhoto] {
        let category = smartCollections.first { $0.id == selectedSmartCollectionID }?.filter ?? filter
        let locationScoped = selectedFolderID != nil || selectedProjectID != nil
        // Offline assets are actionable only from their owning source folder
        // or a project that contains them. Never surface them globally.
        guard category != .missing || locationScoped else { return [] }
        return scopePhotos.filter { $0.matches(category) && (locationScoped || !$0.missing) }
    }

    /// The same Library and AI filters, applied to a caller's current scope.
    func filteredPhotos(from visible: [LibraryPhoto]? = nil) -> [LibraryPhoto] {
        let candidates = visible ?? visiblePhotos
        let top = cullFilters.contains(.topPicks) ? Set(topPickURLs(in: candidates)) : []
        let burstLeads = cullFilters.contains(.burstLeads) ? burstLeadURLs(in: candidates) : []
        return candidates.filter { photo in
            cullFilters.allSatisfy { filter in
                switch filter {
                case .eyesOpen: photo.cull?.eyesOpen == true
                case .sharp: (photo.cull?.faceSharpness ?? photo.cull?.sharpness ?? -1) >= 70
                case .exposure: (photo.cull?.exposure ?? -1) >= 70
                case .aesthetics: (photo.cull?.aesthetics ?? -1) >= 70
                case .composition: (photo.cull?.composition ?? -1) >= 70
                case .aiScore: (photo.cull?.score ?? -1) >= 70
                case .topPicks: top.contains(photo.file.url)
                case .burstLeads: burstLeads.contains(photo.file.url)
                case .rejects: photo.cull?.hardReject == true
                }
            }
        }
    }

    /// Optional burst review powered by Whittle's MIT-licensed clustering
    /// implementation. Undated or unanalysed images are always preserved.
    private func burstLeadURLs(in candidates: [LibraryPhoto]) -> Set<URL> {
        let scope = Set(candidates.map(\.file.url))
        if let burstLeadsCache, burstLeadsCache.scope == scope { return burstLeadsCache.urls }
        let dated = candidates.compactMap { photo -> (LibraryPhoto, Date)? in
            guard let date = photo.cull?.captureDate,
                  photo.cull?.failed == false,
                  photo.cull?.sceneFingerprint != nil else { return nil }
            return (photo, date)
        }
        let groups = BurstClusterEngine.temporalGroups(
            dated.map { BurstTimedItem(id: $0.0.file.url.path, date: $0.1) }, maxGap: 10
        )
        let byPath = Dictionary(uniqueKeysWithValues: dated.map { ($0.0.file.url.path, $0.0) })
        var retained = Set(candidates.filter {
            $0.cull?.failed != false || $0.cull?.captureDate == nil || $0.cull?.sceneFingerprint == nil
        }.map(\.file.url))

        for group in groups {
            let paths = group.map(\.id)
            var fingerprints: [String: VNFeaturePrintObservation] = [:]
            for path in paths {
                guard let data = byPath[path]?.cull?.sceneFingerprint,
                      let print = try? NSKeyedUnarchiver.unarchivedObject(
                        ofClass: VNFeaturePrintObservation.self, from: data) else { continue }
                fingerprints[path] = print
            }
            let clusters = BurstClusterEngine.visualSubclusters(paths, threshold: 0.6) { first, second in
                guard let firstPrint = fingerprints[first], let secondPrint = fingerprints[second] else { return nil }
                return Self.sceneDistance(firstPrint, secondPrint)
            }
            for cluster in clusters {
                let ranked = cluster.compactMap { byPath[$0] }.sorted {
                    let a = $0.cull?.score ?? -1, b = $1.cull?.score ?? -1
                    return a == b ? $0.file.url.path < $1.file.url.path : a > b
                }
                if cluster.count > 1, let lead = ranked.first { retained.insert(lead.file.url) }
                else { ranked.forEach { retained.insert($0.file.url) } }
            }
        }
        burstLeadsCache = (scope, retained)
        return retained
    }

    var detectedScenes: [[LibraryPhoto]] {
        detectedScenes(in: visiblePhotos)
    }

    func detectedScenes(in visiblePhotos: [LibraryPhoto]) -> [[LibraryPhoto]] {
        let scope = Set(visiblePhotos.map(\.file.url))
        if let sceneGroupsCache, sceneGroupsCache.scope == scope { return sceneGroupsCache.groups }
        // Keep every successfully analyzed frame in the ranking. Hard rejects
        // still rank low, but a configured Top N must mean N frames when a
        // scene contains N analyzed photos. Rank only the current Library view,
        // so photos in another folder cannot consume this folder's top slots.
        let eligible = visiblePhotos.filter { $0.cull != nil && !($0.cull?.failed ?? true) }
            .sorted { $0.file.url.path < $1.file.url.path }
        var scenes: [[LibraryPhoto]] = []
        var exemplars: [VNFeaturePrintObservation] = []
        var legacyScene: [LibraryPhoto] = []
        for photo in eligible {
            guard let data = photo.cull?.sceneFingerprint,
                  let fingerprint = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data) else {
                legacyScene.append(photo)
                continue
            }
            let match = exemplars.indices.first { Self.sceneDistance(fingerprint, exemplars[$0]) <= Self.sceneDistanceThreshold }
            guard let match else {
                scenes.append([photo])
                exemplars.append(fingerprint)
                continue
            }
            scenes[match].append(photo)
        }
        if !legacyScene.isEmpty { scenes.append(legacyScene) }
        sceneGroupsCache = (scope, scenes)
        return scenes
    }

    /// Select the best configured number or share per scene, or across the whole view.
    var topPickURLs: Set<URL> {
        topPickURLs(in: visiblePhotos)
    }

    func topPickURLs(in visiblePhotos: [LibraryPhoto]) -> Set<URL> {
        let scope = Set(visiblePhotos.map(\.file.url))
        if let topPicksCache, topPicksCache.unit == topPickUnit,
           topPicksCache.value == topPickValue, topPicksCache.scope == scope {
            return topPicksCache.urls
        }
        let eligible = visiblePhotos.filter { $0.cull != nil && !($0.cull?.failed ?? true) }
        let ranked = eligible.sorted {
            let a = $0.cull?.score ?? -1, b = $1.cull?.score ?? -1
            return a == b ? $0.file.url.path < $1.file.url.path : a > b
        }
        let limit = topPickUnit == .images ? topPickValue : Int(ceil(Double(ranked.count) * Double(topPickValue) / 100))
        let picks = Set(ranked.prefix(limit).map(\.file.url))
        topPicksCache = (topPickUnit, topPickValue, scope, picks)
        return picks
    }

    private static func sceneDistance(_ first: VNFeaturePrintObservation, _ second: VNFeaturePrintObservation) -> Double {
        var distance: Float = .infinity
        guard (try? first.computeDistance(&distance, to: second)) != nil else { return .infinity }
        return Double(distance)
    }

    var selectedPhoto: LibraryPhoto? {
        guard let selectedPhotoURL else { return nil }
        return photos.first { $0.file.url == selectedPhotoURL }
    }

    func count(for filter: LibraryFilter) -> Int {
        let locationScoped = selectedFolderID != nil || selectedProjectID != nil
        if filter == .missing {
            guard locationScoped else { return 0 }
            return scopePhotos.reduce(0) { $0 + ($1.missing ? 1 : 0) }
        }
        return photos.reduce(0) { $0 + ($1.matches(filter) && !$1.missing ? 1 : 0) }
    }
    func count(for project: LibraryProject) -> Int { project.photoPaths.count }

    func load() async {
        guard !loadStarted else { return }
        loadStarted = true
        let url = Self.storeURL
        let result = await Task.detached(priority: .utility) { () -> Result<PhotoLibraryDocument, PhotoLibraryLoadError> in
            guard FileManager.default.fileExists(atPath: url.path) else { return .success(PhotoLibraryDocument()) }
            do {
                let data = try Data(contentsOf: url)
                let document = try JSONDecoder().decode(PhotoLibraryDocument.self, from: data)
                guard document.schema == 1 else { return .failure(.message("This Library catalog version isn’t supported.")) }
                return .success(document)
            } catch {
                return .failure(.message("Could not read the photo Library: \(error.localizedDescription)"))
            }
        }.value
        guard case .success(let document) = result else {
            if case .failure(.message(let message)) = result { error = message }
            loaded = true
            return
        }
        folders = document.folders
        photos = document.photos.map { photo in
            var photo = photo
            photo.rating = min(5, max(0, photo.rating))
            return photo
        }
        albums = document.albums
        smartCollections = document.smartCollections
        projects = document.projects
        selectedProjectID = document.selectedProjectID
        beginFolderAccess()
        await refresh()
        loaded = true
    }

    func importFolders(_ urls: [URL]) async {
        var selectedFolderIDs = Set<UUID>()
        for url in urls {
            if let existing = folders.first(where: { URL(fileURLWithPath: $0.path).standardizedFileURL == url.standardizedFileURL }) {
                selectedFolderIDs.insert(existing.id)
                continue
            }
            let bookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                                includingResourceValuesForKeys: nil, relativeTo: nil)
            let folder = LibraryFolder(id: UUID(), path: url.path, bookmark: bookmark)
            folders.append(folder)
            selectedFolderIDs.insert(folder.id)
            if url.startAccessingSecurityScopedResource() { scopedFolders[folder.id] = url }
        }
        guard !selectedFolderIDs.isEmpty else { return }
        selectedFolderID = nil
        selectedAlbumID = nil
        selectedSmartCollectionID = nil
        selectedProjectID = nil
        filter = .all
        await refresh()
    }

    func removeFolder(_ id: UUID) {
        if let url = scopedFolders.removeValue(forKey: id) { url.stopAccessingSecurityScopedResource() }
        folders.removeAll { $0.id == id }
        let removedPaths = Set(photos.filter { $0.folderID == id }.map { $0.file.url.standardizedFileURL.path })
        photos.removeAll { $0.folderID == id }
        for index in projects.indices { projects[index].photoPaths.subtract(removedPaths) }
        if selectedFolderID == id { selectedFolderID = nil }
        persist()
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let sources = folders.map { ($0.id, $0.resolvedURL()) }
        let scans = await Task.detached(priority: .utility) {
            sources.map { id, url -> (UUID, [PhotoFile]?) in
                do { return (id, try PhotoFolder.snapshot(in: url)) }
                catch { return (id, nil) }
            }
        }.value
        var byName = Dictionary(uniqueKeysWithValues: photos.map { ("\($0.folderID.uuidString):\($0.file.name)", $0) })
        for (folderID, files) in scans {
            guard let files else { continue }
            for key in Array(byName.keys) where key.hasPrefix("\(folderID.uuidString):") {
                if var old = byName[key] {
                    old.missing = true
                    byName[key] = old
                }
            }
            for file in files {
                let key = "\(folderID.uuidString):\(file.name)"
                if var old = byName[key] {
                    old.file = file
                    old.missing = false
                    byName[key] = old
                } else {
                    byName[key] = LibraryPhoto(file: file, folderID: folderID)
                }
            }
        }
        if scans.contains(where: { $0.1 != nil }) {
            photos = byName.values.sorted { $0.file.url.path < $1.file.url.path }
            error = scans.contains(where: { $0.1 == nil })
                ? "Some folders couldn’t be read. Check their access and refresh the Library."
                : nil
            persist()
        } else if !folders.isEmpty {
            error = "Some folders couldn’t be read. Check their access and refresh the Library."
        }
        if let selectedPhotoURL, !photos.contains(where: { $0.file.url == selectedPhotoURL }) {
            self.selectedPhotoURL = nil
        }
    }

    func analyzeCull(replacingExisting: Bool = false) async {
        guard !analyzingCull else { return }
        let candidates = photos.filter { !$0.missing && (replacingExisting || $0.cull == nil) }
        guard !candidates.isEmpty else { return }
        analyzingCull = true
        cullProgress = 0
        cullTotal = candidates.count
        defer { analyzingCull = false }

        for photo in candidates {
            if Task.isCancelled { break }
            let result = await Task.detached(priority: .utility) {
                CullAnalyzer.analyze(photo.file.url)
            }.value
            if let index = photos.firstIndex(where: { $0.file.url == photo.file.url }) {
                photos[index].cull = result ?? CullAnalysis(score: 0, sharpness: 0, aesthetics: nil,
                    composition: nil, eyesOpen: nil, faceCount: 0, utilityImage: false, failed: true,
                    reasons: ["Could not decode this image for culling; review it manually"])
            }
            cullProgress += 1
        }
        persist()
    }

    func setRating(_ rating: Int, for url: URL? = nil) {
        update(url) { $0.rating = min(5, max(0, rating)) }
    }
    func setFlag(_ flag: LibraryFlag, for url: URL? = nil) { update(url) { $0.flag = flag } }
    func setClientPick(_ value: Bool, for url: URL? = nil) { update(url) { $0.clientPicked = value } }
    func setExportQueued(_ value: Bool, for url: URL? = nil) { update(url) { $0.selectedForExport = value } }

    func createAlbum(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !albums.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { return }
        let album = LibraryAlbum(id: UUID(), name: name)
        albums.append(album)
        selectedAlbumID = album.id
        selectedFolderID = nil
        selectedSmartCollectionID = nil
        selectedProjectID = nil
        filter = .all
        persist()
    }

    func deleteAlbum(_ id: UUID) {
        albums.removeAll { $0.id == id }
        for index in photos.indices { photos[index].albumIDs.remove(id) }
        if selectedAlbumID == id { selectedAlbumID = nil }
        persist()
    }

    func addSelectedPhoto(to albumID: UUID) {
        guard let selectedPhotoURL,
              let index = photos.firstIndex(where: { $0.file.url == selectedPhotoURL }) else { return }
        photos[index].albumIDs.insert(albumID)
        persist()
    }

    func createSmartCollection(named name: String, filter: LibraryFilter) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let collection = SmartLibraryCollection(id: UUID(), name: name, filter: filter)
        smartCollections.append(collection)
        selectedSmartCollectionID = collection.id
        selectedFolderID = nil
        selectedAlbumID = nil
        selectedProjectID = nil
        persist()
    }

    func deleteSmartCollection(_ id: UUID) {
        smartCollections.removeAll { $0.id == id }
        if selectedSmartCollectionID == id { selectedSmartCollectionID = nil }
        persist()
    }

    func createProject(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !projects.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { return }
        let project = LibraryProject(id: UUID(), name: name)
        projects.append(project)
        selectedProjectID = project.id
        selectedFolderID = nil
        selectedAlbumID = nil
        selectedSmartCollectionID = nil
        filter = .all
        persist()
    }

    func deleteProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        if selectedProjectID == id { selectedProjectID = nil }
        persist()
    }

    func toggleSelectedPhoto(in projectID: UUID) {
        guard let selectedPhotoURL, let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let path = selectedPhotoURL.standardizedFileURL.path
        if projects[index].photoPaths.contains(path) {
            projects[index].photoPaths.remove(path)
        } else {
            projects[index].photoPaths.insert(path)
        }
        persist()
    }

    func add(_ photos: [LibraryPhoto], to projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].photoPaths.formUnion(photos.map { $0.file.url.standardizedFileURL.path })
        persist()
    }

    func remove(_ photos: [LibraryPhoto], from projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].photoPaths.subtract(photos.map { $0.file.url.standardizedFileURL.path })
        persist()
    }

    func exportProject(_ id: UUID, to url: URL) throws {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        let records = photos.filter { project.photoPaths.contains($0.file.url.standardizedFileURL.path) }
        let folderIDs = Set(records.map(\.folderID))
        let document = LibraryProjectDocument(project: project,
                                              folders: folders.filter { folderIDs.contains($0.id) },
                                              photos: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    func importProject(from url: URL) async throws {
        let document = try JSONDecoder().decode(LibraryProjectDocument.self, from: Data(contentsOf: url))
        guard document.formatVersion == 1, !document.project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EngineError(message: "This Negs project file isn’t supported.")
        }

        var project = document.project
        project.id = UUID()
        let baseName = project.name
        var suffix = 2
        while projects.contains(where: { $0.name.localizedCaseInsensitiveCompare(project.name) == .orderedSame }) {
            project.name = "\(baseName) \(suffix)"
            suffix += 1
        }

        var folderIDs: [UUID: UUID] = [:]
        for folder in document.folders {
            if let existing = folders.first(where: { URL(fileURLWithPath: $0.path).standardizedFileURL == URL(fileURLWithPath: folder.path).standardizedFileURL }) {
                folderIDs[folder.id] = existing.id
            } else {
                var imported = folder
                imported.id = UUID()
                folderIDs[folder.id] = imported.id
                folders.append(imported)
            }
        }
        for record in document.photos {
            if !photos.contains(where: { $0.file.url.standardizedFileURL == record.file.url.standardizedFileURL }) {
                var imported = record
                imported.folderID = folderIDs[record.folderID] ?? record.folderID
                imported.missing = true
                photos.append(imported)
            }
        }

        projects.append(project)
        selectedProjectID = project.id
        selectedFolderID = nil
        selectedAlbumID = nil
        selectedSmartCollectionID = nil
        filter = .all
        beginFolderAccess()
        persist()
        await refresh()
    }

    private func update(_ url: URL?, _ change: (inout LibraryPhoto) -> Void) {
        guard let url = url ?? selectedPhotoURL,
              let index = photos.firstIndex(where: { $0.file.url == url }) else { return }
        change(&photos[index])
        persist()
    }

    private func beginFolderAccess() {
        for folder in folders where scopedFolders[folder.id] == nil {
            let url = folder.resolvedURL()
            if url.startAccessingSecurityScopedResource() { scopedFolders[folder.id] = url }
        }
    }

    private func persist() {
        let document = PhotoLibraryDocument(folders: folders, photos: photos, albums: albums,
                                            smartCollections: smartCollections, projects: projects,
                                            selectedProjectID: selectedProjectID)
        do {
            let directory = Self.storeURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(document).write(to: Self.storeURL, options: .atomic)
        } catch {
            self.error = "Could not save the photo Library: \(error.localizedDescription)"
        }
    }
}
