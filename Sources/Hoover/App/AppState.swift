import AppKit
import Combine
import Foundation
import HooverCore
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var columns: [TreeColumn] = []
    @Published var rootURL: URL?
    @Published var focusedNode: FileNode?
    @Published var preview: FileMetadata?
    @Published var selectedPath: Set<String> = []
    @Published var isSearchActive = false
    @Published var query = ""
    @Published var searchMatchCount = 0
    @Published var isIndexing = false
    @Published var errorMessage: String?
    @Published var hoverProgress = 0.0

    let settings: HooverSettings
    let actions: FileActions
    let tracker = FinderTracker()
    private let metadata = MetadataService()
    private let indexer = RootIndexer()
    private var hoverMachine = HoverStateMachine()
    private var indexRecords: [IndexRecord] = []
    private var normalColumns: [TreeColumn] = []
    private var normalFocusedNode: FileNode?
    private var normalSelectedPath: Set<String> = []
    private var indexingTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var innerHoverTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var enumerationTasks: [Int: Task<Void, Never>] = [:]
    private var watchers: [DirectoryWatcher] = []
    private var rootWatcher: RootWatcher?
    private var subscriptions = Set<AnyCancellable>()
    private var settingsRevision = 0
    private var sessionRevision = 0
    private var previewRevision = 0
    private var filterRevision = 0
    private var appActivationObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?
    private var dismissUntilPointerLeaves: String?
    private var lastFinderNode: String?
    private var lastInnerHover: String?
    private var lastIndexSearchTime = 0.0
    private var sourceWindowID: Int?
    private var fileAnchor: CGRect = .zero
    lazy var overlay = OverlayController(state: self)

    init(settings: HooverSettings) {
        self.settings = settings
        actions = FileActions(settings: settings)
        actions.onDismiss = { [weak self] in self?.dismiss() }
        actions.onChanged = { [weak self] _ in self?.refresh() }
        actions.onError = { [weak self] message in self?.errorMessage = message }
        tracker.onObservation = { [weak self] observation in self?.observeFinder(observation) }
        settings.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            self.objectWillChange.send()
            self.settingsRevision += 1
            let revision = self.settingsRevision
            Task { @MainActor [weak self] in
                // objectWillChange precedes the published value assignment.
                await Task.yield()
                guard let self, self.settingsRevision == revision else { return }
                self.settingsChanged()
            }
        }.store(in: &subscriptions)
    }

    func start() {
        tracker.start()
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != "com.apple.finder", app.processIdentifier != getpid() else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.actions.isOpening else { return }
                self.dismiss()
            }
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.settings.clickOutsideDismiss, self.overlay.isVisible,
                      !self.overlay.containsPointer else { return }
                self.dismiss()
            }
        }
    }

    func stop() {
        dismiss()
        tracker.stop()
        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        appActivationObserver = nil
        outsideClickMonitor = nil
    }

    private func settingsChanged() {
        hoverMachine.folderDelay = settings.folderDelay
        hoverMachine.fileDelay = settings.fileDelay
        if !settings.enabled || (rootURL != nil && !settings.folderEnabled)
            || (rootURL == nil && !settings.fileEnabled) {
            dismiss()
        } else if rootURL != nil {
            refresh()
        }
    }

    private func observeFinder(_ observation: FinderObservation) {
        guard settings.enabled else { hoverMachine.reset(); return }
        if actions.isOpening { hoverProgress = 0; return }
        if let source = sourceWindowID, let windows = observation.liveWindowIDs, !windows.contains(source) {
            dismiss()
            return
        }
        // Moving from Finder into Hoover must not count as leaving the item.
        if overlay.isVisible && overlay.containsPointer { hoverProgress = 0; return }
        if !observation.finderActive {
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if frontmost == getpid(), overlay.isVisible { return }
            dismiss()
            return
        }
        lastFinderNode = observation.node?.id
        if let blockedID = dismissUntilPointerLeaves {
            if observation.node?.id == blockedID { return }
            dismissUntilPointerLeaves = nil
        }
        if observation.blocked {
            hoverMachine.reset()
            hoverProgress = 0
            if rootURL == nil, overlay.isVisible { dismiss() }
            return
        }
        var node = observation.node
        if let value = node, settings.isExcluded(value.url)
            || (value.isDirectory && !settings.folderEnabled)
            || (!value.isDirectory && !settings.fileEnabled) { node = nil }
        hoverMachine.folderDelay = settings.folderDelay
        hoverMachine.fileDelay = settings.fileDelay
        let action = hoverMachine.update(node: node, timestamp: ProcessInfo.processInfo.systemUptime,
                                         blocked: observation.blocked)
        hoverProgress = settings.showCountdown ? hoverMachine.progress : 0
        switch action {
        case .none: break
        case .dismiss:
            // Folder sessions remain open while exploring the space to their right.
            if rootURL == nil {
                endSession()
                overlay.dismiss()
            }
        case .showFolder(let url):
            guard let bounds = observation.bounds else { return }
            activateFolder(url, anchor: bounds)
            sourceWindowID = observation.sourceWindowID
        case .showFile(let url):
            guard let bounds = observation.bounds,
                  let node = observation.node, node.url == url else { return }
            activateFile(node, anchor: bounds)
            sourceWindowID = observation.sourceWindowID
        }
        if rootURL == nil, overlay.isVisible, node == nil, !overlay.containsPointer { dismiss() }
    }

    private func activateFolder(_ url: URL, anchor: CGRect) {
        endSession()
        rootURL = url.standardizedFileURL
        selectedPath = [url.standardizedFileURL.path]
        overlay.showFolder(anchor: anchor)
        loadColumn(parent: url, level: 1)
        startIndex()
        let watcher = RootWatcher(url: url) { [weak self] in self?.refresh() }
        watcher.start()
        rootWatcher = watcher
    }

    private func activateFile(_ node: FileNode, anchor: CGRect) {
        endSession()
        focusedNode = node
        fileAnchor = anchor
        overlay.showFile(anchor: anchor)
        loadPreview(node)
    }

    func hover(_ node: FileNode, level: Int) {
        guard lastInnerHover != node.id else { return }
        lastInnerHover = node.id
        innerHoverTask?.cancel()
        focusedNode = node
        if !node.isDirectory {
            if settings.showPreviews { loadPreview(node) }
            return
        }
        previewTask?.cancel()
        preview = nil
        guard !isSearchActive || query.isEmpty else { return }
        let revision = sessionRevision
        let delay = settings.innerDelay
        innerHoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.1, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.sessionRevision == revision else { return }
            self.expand(node, level: level)
        }
    }

    func select(_ node: FileNode, level: Int) {
        innerHoverTask?.cancel()
        focusedNode = node
        if node.isDirectory {
            if !isSearchActive || query.isEmpty { expand(node, level: level) }
        } else {
            loadPreview(node)
            updateActivePath(node.url)
        }
    }

    func unhover(_ node: FileNode) {
        guard lastInnerHover == node.id else { return }
        innerHoverTask?.cancel()
        lastInnerHover = nil
    }

    func open(_ node: FileNode) { actions.open(node) }

    private func expand(_ node: FileNode, level: Int) {
        guard node.isDirectory, let root = rootURL,
              isWithinRoot(node.url, root: root), !settings.isExcluded(node.url) else { return }
        // Symlink directory targets are constrained to the immutable session root.
        if node.isSymbolicLink {
            guard settings.followSymlinks,
                  isWithinRoot(node.url.resolvingSymlinksInPath(), root: root.resolvingSymlinksInPath()) else {
                errorMessage = "Following symbolic links is disabled or this link leaves the root folder."
                return
            }
        }
        updateActivePath(node.url)
        columns.removeAll { $0.level > level }
        for (key, task) in enumerationTasks where key > level { task.cancel() }
        enumerationTasks = enumerationTasks.filter { $0.key <= level }
        loadColumn(parent: node.url, level: level + 1)
    }

    private func updateActivePath(_ url: URL) {
        guard let root = rootURL else { return }
        var path = url.standardizedFileURL
        var ids = Set<String>()
        while isWithinRoot(path, root: root) {
            ids.insert(path.path)
            if path.path == root.path { break }
            path.deleteLastPathComponent()
        }
        selectedPath = ids
    }

    private func loadColumn(parent: URL, level: Int) {
        let revision = sessionRevision
        let hidden = settings.includeHidden
        let excluded = settings.exclusionPredicate()
        enumerationTasks[level]?.cancel()
        // Present a loading column before filesystem work, with no synchronous enumeration on the UI thread.
        columns.removeAll { $0.level >= level }
        columns.append(TreeColumn(parentURL: parent, level: level, items: [], isLoading: true))
        if isSearchActive { normalColumns = columns }
        enumerationTasks[level] = Task { [weak self] in
            let result: Result<[FileNode], Error> = await Task.detached(priority: .userInitiated) {
                Result { try DirectoryReader.contents(of: parent, includeHidden: hidden).filter { !excluded($0.url) } }
            }.value
            guard !Task.isCancelled, let self, self.sessionRevision == revision else { return }
            var destination = self.isSearchActive ? self.normalColumns : self.columns
            guard let destinationIndex = destination.firstIndex(where: { $0.level == level && $0.parentURL == parent }) else { return }
            switch result {
            case .success(let nodes):
                destination[destinationIndex] =
                    TreeColumn(parentURL: parent, level: level, items: nodes)
            case .failure(let error):
                destination[destinationIndex] =
                    TreeColumn(parentURL: parent, level: level, items: [], error: error.localizedDescription)
            }
            if self.isSearchActive {
                self.normalColumns = destination
                if self.query.isEmpty { self.columns = destination }
            } else { self.columns = destination }
            self.installWatchers()
        }
    }

    func beginSearch() {
        guard rootURL != nil else { return }
        if !isSearchActive {
            normalColumns = columns
            normalFocusedNode = focusedNode
            normalSelectedPath = selectedPath
        }
        isSearchActive = true
        innerHoverTask?.cancel()
        overlay.focusSearch()
        // The keyboard monitor makes the panel key so the focused search field can accept text.
    }

    func updateQuery(_ value: String) {
        query = value
        applySearch()
    }

    private func applySearch() {
        filterTask?.cancel()
        filterRevision += 1
        guard isSearchActive, let root = rootURL else { return }
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            searchMatchCount = 0
            if !normalColumns.isEmpty { columns = normalColumns }
            return
        }
        let records = indexRecords
        let revision = sessionRevision
        let queryRevision = filterRevision
        let fuzzy = settings.fuzzySearch
        filterTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard !Task.isCancelled else { return }
            let (result, levels) = await Task.detached(priority: .userInitiated) {
                let result = TreeSearch.search(query: value, records: records, fuzzy: fuzzy)
                return (result, searchColumns(records: records, result: result, root: root))
            }.value
            guard !Task.isCancelled, let self, self.sessionRevision == revision,
                  self.filterRevision == queryRevision, self.isSearchActive else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                self.columns = levels
                self.searchMatchCount = result.matches.count
                self.selectedPath = result.visibleIDs
            }
        }
    }

    private func startIndex() {
        indexingTask?.cancel()
        guard let root = rootURL else { return }
        let revision = sessionRevision
        indexRecords = []
        isIndexing = true
        lastIndexSearchTime = 0
        let stream = indexer.stream(root: root, includeHidden: settings.includeHidden,
                                    includePackages: settings.includePackages,
                                    followSymlinks: settings.followSymlinks,
                                    maxDepth: settings.maximumIndexDepth > 0 ? settings.maximumIndexDepth : nil,
                                    excludedPaths: settings.exclusions,
                                    excludeExternalVolumes: settings.excludeExternalVolumes,
                                    excludeNetworkVolumes: settings.excludeNetworkVolumes)
        indexingTask = Task { [weak self] in
            for await batch in stream {
                guard !Task.isCancelled, let self, self.sessionRevision == revision else { break }
                self.indexRecords.append(contentsOf: batch)
                if self.isSearchActive, !self.query.isEmpty {
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - self.lastIndexSearchTime >= 0.12 {
                        self.lastIndexSearchTime = now
                        self.applySearch()
                    }
                }
            }
            guard !Task.isCancelled, let self, self.sessionRevision == revision else { return }
            self.isIndexing = false
            if self.isSearchActive { self.applySearch() }
        }
    }

    private func loadPreview(_ node: FileNode) {
        previewTask?.cancel()
        metadata.cancel()
        previewRevision += 1
        let revision = previewRevision
        preview = nil
        previewTask = Task { [weak self] in
            guard let self else { return }
            let basic = await self.metadata.basic(url: node.url)
            guard !Task.isCancelled, self.previewRevision == revision,
                  self.focusedNode?.id == node.id else { return }
            self.preview = basic
            let thumbnailTask = Task { @MainActor [weak self] () -> NSImage? in
                guard let self, self.settings.showThumbnail else { return nil }
                return await self.metadata.thumbnail(url: node.url)
            }
            var result = await self.metadata.load(url: node.url)
            guard !Task.isCancelled, self.previewRevision == revision,
                  self.focusedNode?.id == node.id else { return }
            self.preview = result
            if let thumbnail = await thumbnailTask.value {
                guard !Task.isCancelled, self.previewRevision == revision,
                      self.focusedNode?.id == node.id else { return }
                result.thumbnail = thumbnail
                self.preview = result
            }
        }
    }

    func saveNote(_ note: String) async {
        guard settings.showNotes, let node = focusedNode else { return }
        do {
            try await metadata.saveNote(note, url: node.url)
            if focusedNode?.id == node.id { loadPreview(node) }
        } catch { errorMessage = "Could not save note: \(error.localizedDescription)" }
    }

    func escape() {
        if isSearchActive {
            filterTask?.cancel()
            filterRevision += 1
            isSearchActive = false
            query = ""
            searchMatchCount = 0
            columns = normalColumns
            normalColumns = []
            focusedNode = normalFocusedNode
            selectedPath = normalSelectedPath
            normalFocusedNode = nil
            normalSelectedPath = []
        } else { dismiss() }
    }

    func refresh() {
        guard let root = rootURL else { return }
        guard FileManager.default.fileExists(atPath: root.path) else { dismiss(); return }
        refreshTask?.cancel()
        let revision = sessionRevision
        let hidden = settings.includeHidden
        let excluded = settings.exclusionPredicate()
        let source = isSearchActive ? normalColumns : columns
        refreshTask = Task { [weak self] in
            var updated: [TreeColumn] = []
            for column in source {
                guard FileManager.default.fileExists(atPath: column.parentURL.path) else { break }
                let result = await Task.detached(priority: .utility) {
                    Result { try DirectoryReader.contents(of: column.parentURL, includeHidden: hidden).filter { !excluded($0.url) } }
                }.value
                guard !Task.isCancelled, let self, self.sessionRevision == revision else { return }
                switch result {
                case .success(let nodes):
                    updated.append(TreeColumn(parentURL: column.parentURL, level: column.level,
                                              items: nodes))
                case .failure(let error):
                    updated.append(TreeColumn(parentURL: column.parentURL, level: column.level,
                                              items: [], error: error.localizedDescription))
                }
            }
            guard !Task.isCancelled, let self, self.sessionRevision == revision else { return }
            if self.isSearchActive { self.normalColumns = updated }
            else { withAnimation { self.columns = updated } }
            if let focused = self.focusedNode, !FileManager.default.fileExists(atPath: focused.url.path) {
                self.focusedNode = nil
                self.preview = nil
            }
            self.startIndex()
            self.installWatchers()
        }
    }

    private func installWatchers() {
        watchers.forEach { $0.stop() }
        watchers = []
        let current = isSearchActive ? normalColumns : columns
        for url in Set(current.map(\.parentURL)) {
            let watcher = DirectoryWatcher(url: url) { [weak self] in self?.refresh() }
            watcher.start()
            watchers.append(watcher)
        }
    }

    func dismiss() {
        dismissUntilPointerLeaves = lastFinderNode
        hoverMachine.reset()
        endSession()
        overlay.dismiss()
    }

    private func endSession() {
        sessionRevision += 1
        indexingTask?.cancel()
        filterTask?.cancel()
        innerHoverTask?.cancel()
        previewTask?.cancel()
        refreshTask?.cancel()
        enumerationTasks.values.forEach { $0.cancel() }
        enumerationTasks = [:]
        metadata.cancel()
        watchers.forEach { $0.stop() }
        watchers = []
        rootWatcher?.stop()
        rootWatcher = nil
        rootURL = nil
        sourceWindowID = nil
        focusedNode = nil
        preview = nil
        columns = []
        normalColumns = []
        normalFocusedNode = nil
        normalSelectedPath = []
        indexRecords = []
        selectedPath = []
        isSearchActive = false
        query = ""
        searchMatchCount = 0
        isIndexing = false
        errorMessage = nil
        hoverProgress = 0
        lastInnerHover = nil
    }

    private func isWithinRoot(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let scope = root.standardizedFileURL.path
        return path == scope || path.hasPrefix(scope.hasSuffix("/") ? scope : scope + "/")
    }
}

/// Layout preparation stays on the search worker, including large-result sorting.
private func searchColumns(records: [IndexRecord], result: SearchResult, root: URL) -> [TreeColumn] {
    let surviving = records.filter { $0.depth > 0 && result.visibleIDs.contains($0.node.id) }
    let grouped = Dictionary(grouping: surviving, by: \.depth)
    return grouped.keys.sorted().map { depth in
        let group = grouped[depth]!.sorted {
            if $0.node.isDirectory != $1.node.isDirectory { return $0.node.isDirectory }
            if $0.normalizedName != $1.normalizedName { return $0.normalizedName < $1.normalizedName }
            return $0.node.id < $1.node.id
        }
        let parents = Set(group.compactMap(\.parentID))
        let parent = parents.count == 1 ? URL(fileURLWithPath: parents.first!) : root
        return TreeColumn(parentURL: parent, level: depth, items: group.map(\.node))
    }
}
