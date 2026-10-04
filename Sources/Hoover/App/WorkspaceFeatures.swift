import AppKit
import Foundation
import HooverCore
import UniformTypeIdentifiers

enum InsightMode: String, CaseIterable {
    case none, largest, recent, duplicateNames
    var title: String {
        switch self {
        case .none: return "Folder tree"
        case .largest: return "Largest files"
        case .recent: return "Recently modified"
        case .duplicateNames: return "Same-name items"
        }
    }
}

enum TreeNavigation { case up, down, left, right }

@MainActor
extension AppState {
    var favoriteRoots: [URL] { workspace.favorites }
    var recentRoots: [URL] { workspace.recentRoots }
    var savedSearches: [SavedSearch] { workspace.savedSearches }
    var isFavoriteRoot: Bool { rootURL.map { workspace.favorites.contains($0) } ?? false }

    func togglePin() { isPinned.toggle() }
    func toggleFavoriteRoot() { if let root = rootURL { workspace.toggleFavorite(root) } }
    func clearRecentRoots() { workspace.clearHistory() }
    func removeSavedSearch(_ id: UUID) { workspace.removeSavedSearch(id: id) }

    func createFolder(in parent: URL) {
        guard let root = rootURL, isWithinRoot(parent, root: root),
              isWithinRoot(parent.resolvingSymlinksInPath(), root: root.resolvingSymlinksInPath()),
              let node = try? DirectoryReader.node(at: parent), node.isDirectory,
              !settings.isExcluded(parent),
              parent.standardizedFileURL == root.standardizedFileURL || !node.isSymbolicLink || settings.followSymlinks else {
            errorMessage = "Choose an accessible folder inside this root. Following folder links must be enabled for descendant links."
            return
        }
        actions.newFolder(in: parent, root: root)
    }

    func openWorkspace(_ url: URL) {
        guard !actions.isOpening else { errorMessage = "Wait for the current file action to finish before switching folders."; return }
        guard url.isFileURL, !settings.isExcluded(url),
              let node = try? DirectoryReader.node(at: url), node.isDirectory else {
            errorMessage = "This saved folder is unavailable or excluded."
            return
        }
        let point = NSEvent.mouseLocation
        activateFolder(url, anchor: CGRect(x: point.x - 220, y: point.y, width: 24, height: 24))
        overlay.focusSearch()
    }

    func saveCurrentSearch() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        workspace.saveSearch(name: String(value.prefix(64)), query: value)
    }

    func applySavedSearch(_ saved: SavedSearch) {
        guard rootURL != nil else { return }
        beginSearch()
        updateQuery(saved.query)
    }

    func setSortOrder(_ value: NodeSortOrder) { sortOrder = value; resortColumns(); if isSearchActive { updateQuery(query) } }
    func setAscending(_ value: Bool) { sortAscending = value; resortColumns(); if isSearchActive { updateQuery(query) } }

    func resortColumns() {
        orderingTask?.cancel()
        let current = columns
        let normal = normalColumns
        let order = sortOrder
        let ascending = sortAscending
        let revision = sessionRevision
        let visibleRevision = columnsRevision
        let savedRevision = normalColumnsRevision
        let searchOwnsVisible = isSearchActive && !query.isEmpty
        let total = current.reduce(0) { $0 + $1.items.count } + normal.reduce(0) { $0 + $1.items.count }
        if total < 500 {
            if !searchOwnsVisible { columns = Self.orderedColumns(current, order: order, ascending: ascending) }
            normalColumns = Self.orderedColumns(normal, order: order, ascending: ascending)
            return
        }
        orderingTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                (searchOwnsVisible ? current : Self.orderedColumns(current, order: order, ascending: ascending),
                 Self.orderedColumns(normal, order: order, ascending: ascending))
            }
            let (visible, saved) = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, let self, self.sessionRevision == revision,
                  self.sortOrder == order, self.sortAscending == ascending else { return }
            if !searchOwnsVisible, self.columnsRevision == visibleRevision { self.columns = visible }
            if self.normalColumnsRevision == savedRevision { self.normalColumns = saved }
        }
    }

    nonisolated static func orderedColumns(_ input: [TreeColumn], order: NodeSortOrder, ascending: Bool) -> [TreeColumn] {
        input.map { column in
            var column = column
            column.items = TreeOrdering.sorted(column.items, by: order, ascending: ascending)
            return column
        }
    }

    var breadcrumbURLs: [URL] {
        guard let root = rootURL else { return [] }
        var target = focusedNode.map { $0.isDirectory ? $0.url : $0.url.deletingLastPathComponent() } ?? root
        guard isWithinRoot(target, root: root) else { return [root] }
        var urls: [URL] = []
        while isWithinRoot(target, root: root) {
            urls.append(target)
            if target.standardizedFileURL == root.standardizedFileURL { break }
            target.deleteLastPathComponent()
        }
        return urls.reversed()
    }

    func navigateToBreadcrumb(_ url: URL) {
        guard let root = rootURL, isWithinRoot(url, root: root) else { return }
        if insightMode != .none { resetInsight() }
        if isSearchActive { escape() }
        guard let node = try? DirectoryReader.node(at: url), node.isDirectory else { return }
        if url.standardizedFileURL == root.standardizedFileURL {
            columns = columns.filter { $0.level == 1 }
            focusedNode = nil
            selectedPath = [root.path]
            preview = nil
            return
        }
        // Breadcrumbs always navigate inside the immutable original root.
        let depth = url.standardizedFileURL.pathComponents.count - root.standardizedFileURL.pathComponents.count
        select(node, level: max(1, depth))
    }

    func cycleSearchMatch(backwards: Bool = false) {
        guard isSearchActive, !searchMatches.isEmpty else { return }
        let current = searchMatches.firstIndex { $0.id == focusedNode?.id }
        let next = current.map { ($0 + (backwards ? -1 : 1) + searchMatches.count) % searchMatches.count }
            ?? (backwards ? searchMatches.count - 1 : 0)
        focusForKeyboard(searchMatches[next])
    }

    func focusForKeyboard(_ node: FileNode) {
        focusedNode = node
        keyboardFocusRevision &+= 1
        if !isSearchActive { updateActivePath(node.url) }
        if node.isDirectory { preview = nil }
        else if settings.showPreviews { loadPreview(node) }
    }

    func navigate(_ direction: TreeNavigation) {
        guard !columns.isEmpty else { return }
        let columnIndex = columns.firstIndex { column in column.items.contains { $0.id == focusedNode?.id } } ?? 0
        let column = columns[columnIndex]
        switch direction {
        case .up, .down:
            guard !column.items.isEmpty else { return }
            let current = column.items.firstIndex { $0.id == focusedNode?.id }
            let index = current.map { min(column.items.count - 1, max(0, $0 + (direction == .up ? -1 : 1))) }
                ?? (direction == .up ? column.items.count - 1 : 0)
            focusForKeyboard(column.items[index])
        case .right:
            guard let node = focusedNode, node.isDirectory, insightMode == .none,
                  !isSearchActive || query.isEmpty else { return }
            if let child = columns.first(where: { $0.parentURL == node.url })?.items.first {
                focusForKeyboard(child)
            } else {
                pendingFocusParent = node.url
                select(node, level: column.level)
            }
        case .left:
            guard columnIndex > 0, !isSearchActive, insightMode == .none,
                  let node = try? DirectoryReader.node(at: column.parentURL) else { return }
            columns = Array(columns.prefix(columnIndex))
            focusForKeyboard(node)
        }
    }

    func updateInsights() {
        insightsTask?.cancel()
        let records = indexRecords
        let revision = sessionRevision
        insightsTask = Task { [weak self] in
            let summary = await Task.detached(priority: .utility) {
                TreeInsights.analyze(records, limit: 50)
            }.value
            guard !Task.isCancelled, let self, self.sessionRevision == revision else { return }
            self.insights = summary
            if self.insightMode != .none { self.displayInsight() }
        }
    }

    func showInsight(_ mode: InsightMode) {
        guard rootURL != nil else { return }
        if mode == .none { resetInsight(); return }
        if isSearchActive { escape() }
        if insightMode == .none { normalColumns = columns }
        insightMode = mode
        displayInsight()
    }

    private func displayInsight() {
        guard let root = rootURL else { return }
        let items: [FileNode]
        switch insightMode {
        case .none: return
        case .largest: items = insights?.largestFiles ?? []
        case .recent: items = insights?.recentlyModifiedFiles ?? []
        case .duplicateNames: items = insights?.duplicateNameGroups.flatMap(\.nodes) ?? []
        }
        columns = [TreeColumn(parentURL: root, level: 1, items: items, isLoading: isIndexing)]
        focusedNode = nil
        preview = nil
        selectedPath = []
    }

    func resetInsight() {
        guard insightMode != .none else { return }
        insightMode = .none
        columns = normalColumns
        normalColumns = []
        focusedNode = nil
        preview = nil
        selectedPath = Set(rootURL.map { [$0.path] } ?? [])
        resortColumns()
    }

    func exportManifest() {
        guard rootURL != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = (rootURL?.lastPathComponent ?? "Hoover") + "-inventory.csv"
        panel.message = isIndexing ? "Indexing is in progress. This exports the currently indexed items." : "Export this root’s indexed file inventory."
        let records = indexRecords
        let indexFinished = !isIndexing
        let exportRevision = sessionRevision
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try await Task.detached(priority: .utility) {
                        try Self.inventoryCSV(records, indexFinished: indexFinished).write(to: url, atomically: true, encoding: .utf8)
                    }.value
                } catch {
                    guard let self, self.sessionRevision == exportRevision else { return }
                    self.errorMessage = "Could not export inventory: \(error.localizedDescription)"
                }
            }
        }
    }

    nonisolated static func inventoryCSV(_ records: [IndexRecord], indexFinished: Bool = true) -> String {
        func cell(_ text: String) -> String {
            let safe = text.first.map { "=+-@\t\r".contains($0) } == true ? "'" + text : text
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let formatter = ISO8601DateFormatter()
        let lines = records.filter { $0.depth > 0 }.map { record in
            [record.relativePath, record.node.isDirectory ? "folder" : "file",
             record.node.size.map(String.init) ?? "", record.node.modified.map(formatter.string) ?? "", indexFinished ? "finished" : "in progress"]
                .map(cell).joined(separator: ",")
        }
        return "Path,Kind,Bytes,Modified,IndexState\r\n" + lines.joined(separator: "\r\n") + "\r\n"
    }

    func updateDiagnostics(_ observation: FinderObservation) {
        let reason: String
        if !settings.enabled { reason = "Hoover is paused." }
        else if isPinned { reason = "The current HUD is pinned; hover replacement is paused." }
        else if observation.blocked { reason = "Hover is blocked by permission, dragging, or an active editing interaction." }
        else if let node = observation.node, settings.isExcluded(node.url) { reason = "This location is excluded in Settings." }
        else if let node = observation.node, node.isDirectory ? !settings.folderEnabled : !settings.fileEnabled {
            reason = "This item’s hover feature is disabled in Settings."
        } else if observation.node != nil { reason = overlay.isVisible ? "HUD is open." : "Item resolved; waiting for the hover delay." }
        else { reason = "No verified Finder item beneath the pointer." }
        if diagnosticReason != reason { diagnosticReason = reason; diagnosticTimestamp = Date() }
        let item = observation.node.map { $0.isDirectory ? "Folder resolved" : "File resolved" } ?? "No resolved item"
        if diagnosticItem != item { diagnosticItem = item }
        if diagnosticFinderOwned != observation.pointerOverFinder { diagnosticFinderOwned = observation.pointerOverFinder }
    }

    func restartTracking() { tracker.stop(); tracker.start() }
}
