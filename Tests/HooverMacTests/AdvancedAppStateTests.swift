import AppKit
import Foundation
import HooverCore
import XCTest
@testable import Hoover

final class AdvancedAppStateTests: XCTestCase {
    @MainActor
    func testCompoundSearchKeepsRootAndCompleteRealAncestry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = try fixture.folder("Project")
        let target = try fixture.file("Project/Sources/release notes.txt", bytes: 8)
        _ = try fixture.file("Project/Docs/release notes draft.txt", bytes: 4)
        _ = try fixture.file("Project/release notes.md", bytes: 2)
        fixture.state.openWorkspace(root)
        try await waitUntil("Real folder indexing completes") { !fixture.state.isIndexing }

        fixture.state.beginSearch()
        fixture.state.updateQuery("\"release notes\" -draft ext:txt")
        try await waitUntil("Compound query resolves only the intended real file") {
            fixture.state.searchMatchCount == 1 && fixture.state.searchMatches.first?.url == target
        }
        XCTAssertEqual(fixture.state.rootURL, root)
        XCTAssertNil(fixture.state.errorMessage)
        XCTAssertTrue(fixture.state.selectedPath.contains(root.path))
        XCTAssertTrue(fixture.state.selectedPath.contains(target.deletingLastPathComponent().path))
        XCTAssertTrue(fixture.state.selectedPath.contains(target.path))
        XCTAssertEqual(Set(fixture.state.columns.flatMap(\.items).map(\.url)),
                       [target.deletingLastPathComponent(), target])
    }

    @MainActor
    func testLatestQueryWinsAndValidQueryClearsParseFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = try fixture.folder("Project")
        _ = try fixture.file("Project/Alpha.txt", bytes: 1)
        let markdown = try fixture.file("Project/Guide.md", bytes: 2)
        fixture.state.openWorkspace(root)
        try await waitUntil("Index completes") { !fixture.state.isIndexing }
        fixture.state.beginSearch()
        fixture.state.updateQuery("kind:unrecognized-kind")
        try await waitUntil("Invalid query reports an error") { fixture.state.errorMessage != nil && fixture.state.columns.isEmpty }
        XCTAssertEqual(fixture.state.rootURL, root)

        fixture.state.updateQuery("ext:txt")
        fixture.state.updateQuery("ext:md")
        try await waitUntil("The replacement query owns the result") {
            fixture.state.searchMatches.map(\.url) == [markdown] && fixture.state.errorMessage == nil
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(fixture.state.searchMatches.map(\.url), [markdown])
        XCTAssertEqual(fixture.state.query, "ext:md")
        XCTAssertEqual(fixture.state.rootURL, root)
    }

    @MainActor
    func testSortChangesSurviveSearchEscapeWithoutReplacingRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = try fixture.folder("Project")
        let small = try fixture.file("Project/Alpha.txt", bytes: 1)
        let large = try fixture.file("Project/Zulu.txt", bytes: 20)
        fixture.state.openWorkspace(root)
        try await waitUntil("Browsing and indexing complete") {
            !fixture.state.isIndexing && fixture.state.columns.first?.items.count == 2
        }
        fixture.state.setSortOrder(.size)
        fixture.state.setAscending(false)
        XCTAssertEqual(fixture.state.columns.first?.items.map(\.url), [large, small])
        fixture.state.beginSearch()
        fixture.state.updateQuery("ext:txt")
        try await waitUntil("Both search matches arrive") { fixture.state.searchMatchCount == 2 }
        fixture.state.setSortOrder(.name)
        fixture.state.setAscending(true)
        fixture.state.escape()

        XCTAssertFalse(fixture.state.isSearchActive)
        XCTAssertEqual(fixture.state.columns.first?.items.map(\.url), [small, large])
        XCTAssertEqual(fixture.state.rootURL, root)
    }

    @MainActor
    func testLargeAsyncOrderingCompletesAndCannotReplaceNewWorkspace() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.folder("First")
        for index in 0..<550 {
            _ = try fixture.file("First/Item-\(index).txt", bytes: index + 1)
        }
        let second = try fixture.folder("Second")
        let target = try fixture.file("Second/Only.txt", bytes: 2)
        fixture.state.openWorkspace(first)
        try await waitUntil("Large real folder browsing completes") {
            !fixture.state.isIndexing && fixture.state.columns.first?.items.count == 550
        }
        fixture.state.setSortOrder(.size)
        fixture.state.setAscending(false)
        try await waitUntil("Asynchronous ordering publishes the requested descending sizes") {
            fixture.state.columns.first?.items.first?.name == "Item-549.txt"
        }
        let sizes = try XCTUnwrap(fixture.state.columns.first).items.compactMap(\.size)
        XCTAssertEqual(sizes, Array(stride(from: Int64(550), through: 1, by: -1)))
        XCTAssertEqual(fixture.state.rootURL, first)

        // Supersede another large ordering request before its detached worker
        // can publish. No real application or Finder focus is asserted.
        fixture.state.setSortOrder(.name)
        fixture.state.setAscending(true)
        fixture.state.openWorkspace(second)
        try await waitUntil("The newer workspace publishes its own real child") {
            !fixture.state.isIndexing && fixture.state.columns.first?.items.map(\.url) == [target]
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(fixture.state.rootURL, second)
        XCTAssertEqual(fixture.state.columns.first?.parentURL, second)
        XCTAssertEqual(fixture.state.columns.first?.items.map(\.url), [target])
        XCTAssertTrue(fixture.state.columns.allSatisfy { $0.parentURL.path.hasPrefix(second.path) })
    }

    @MainActor
    func testWorkspacePersistenceAndSavedQueryReuseCurrentRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.folder("First")
        _ = try fixture.file("First/Original.txt", bytes: 1)
        let second = try fixture.folder("Second")
        let target = try fixture.file("Second/Current.txt", bytes: 2)
        fixture.state.openWorkspace(first)
        try await waitUntil("First index completes") { !fixture.state.isIndexing }
        fixture.state.toggleFavoriteRoot()
        fixture.state.beginSearch()
        fixture.state.updateQuery("ext:txt")
        fixture.state.saveCurrentSearch()
        let saved = try XCTUnwrap(fixture.state.savedSearches.first)
        let restored = WorkspaceStore(defaults: fixture.defaults)
        XCTAssertEqual(restored.favorites, [first])
        XCTAssertEqual(restored.savedSearches.first?.query, "ext:txt")

        fixture.state.openWorkspace(second)
        try await waitUntil("Second index completes") { !fixture.state.isIndexing }
        fixture.state.applySavedSearch(saved)
        try await waitUntil("Saved query applies to the newly chosen scope") {
            fixture.state.searchMatches.map(\.url) == [target]
        }
        XCTAssertEqual(fixture.state.rootURL, second, "Reusable saved filters must not reopen their earlier folder.")
        XCTAssertEqual(fixture.state.favoriteRoots, [first])
        XCTAssertEqual(fixture.state.recentRoots, [second, first])
        XCTAssertEqual(WorkspaceStore(defaults: fixture.defaults).recentRoots, [second, first])
    }

    @MainActor
    func testKeyboardBreadcrumbAndMatchNavigationStayWithinRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = try fixture.folder("Project")
        let sources = try fixture.folder("Project/Sources")
        let core = try fixture.folder("Project/Sources/Core")
        let first = try fixture.file("Project/Sources/Core/One.txt", bytes: 1)
        let second = try fixture.file("Project/Sources/Core/Two.txt", bytes: 2)
        let sibling = try fixture.folder("Project-Other")
        fixture.state.openWorkspace(root)
        try await waitUntil("Root browsing completes") {
            !fixture.state.isIndexing && fixture.state.columns.first?.isLoading == false
        }
        fixture.state.navigate(.down)
        XCTAssertEqual(fixture.state.focusedNode?.url, sources)
        fixture.state.navigate(.right)
        try await waitUntil("Right navigation focuses the real child folder") { fixture.state.focusedNode?.url == core }
        fixture.state.navigate(.right)
        try await waitUntil("Right navigation focuses the real child file") { fixture.state.focusedNode?.url == first }
        XCTAssertEqual(fixture.state.breadcrumbURLs, [root, sources, core])

        fixture.state.navigateToBreadcrumb(sibling)
        XCTAssertEqual(fixture.state.rootURL, root)
        XCTAssertEqual(fixture.state.focusedNode?.url, first)
        fixture.state.navigateToBreadcrumb(sources)
        try await waitUntil("Ancestor navigation removes deeper columns") {
            fixture.state.columns.allSatisfy { $0.level <= 2 } && fixture.state.columns.last?.isLoading == false
        }
        XCTAssertEqual(fixture.state.rootURL, root)
        fixture.state.beginSearch()
        fixture.state.updateQuery("ext:txt")
        try await waitUntil("Real matches arrive") { fixture.state.searchMatchCount == 2 }
        fixture.state.cycleSearchMatch()
        XCTAssertEqual(fixture.state.focusedNode?.url, first)
        fixture.state.cycleSearchMatch()
        XCTAssertEqual(fixture.state.focusedNode?.url, second)
        fixture.state.cycleSearchMatch()
        XCTAssertEqual(fixture.state.focusedNode?.url, first)
        fixture.state.cycleSearchMatch(backwards: true)
        XCTAssertEqual(fixture.state.focusedNode?.url, second)
        XCTAssertEqual(fixture.state.rootURL, root)
    }

    @MainActor
    func testPinnedSessionRetainsHoverButStillUsesTwoStepSearchEscape() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = try fixture.folder("Project")
        _ = try fixture.file("Project/One.txt", bytes: 1)
        fixture.state.openWorkspace(root)
        try await waitUntil("Index completes") { !fixture.state.isIndexing }
        fixture.state.togglePin()
        fixture.state.observeFinder(FinderObservation(node: nil, bounds: nil, blocked: false,
                                                      finderActive: false, pointer: .zero))
        XCTAssertTrue(fixture.state.isPinned)
        XCTAssertEqual(fixture.state.rootURL, root)
        fixture.state.beginSearch()
        fixture.state.updateQuery("ext:txt")
        try await waitUntil("Search completes") { fixture.state.searchMatchCount == 1 }
        fixture.state.escape()
        XCTAssertFalse(fixture.state.isSearchActive)
        XCTAssertTrue(fixture.state.isPinned)
        XCTAssertEqual(fixture.state.rootURL, root)
        fixture.state.escape()
        XCTAssertFalse(fixture.state.isPinned)
        XCTAssertNil(fixture.state.rootURL)
        XCTAssertFalse(fixture.state.overlay.isVisible)
    }

    @MainActor
    func testHiddenRefreshAndSupersededSessionCannotPublishOldIndex() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.folder("First")
        _ = try fixture.file("First/Visible.txt", bytes: 1)
        let hidden = try fixture.file("First/.Hidden.txt", bytes: 2)
        let second = try fixture.folder("Second")
        let target = try fixture.file("Second/Current.md", bytes: 3)
        fixture.state.openWorkspace(first)
        try await waitUntil("First index excludes hidden files") {
            !fixture.state.isIndexing && fixture.state.indexRecords.count == 2
        }
        XCTAssertFalse(fixture.state.indexRecords.contains { $0.node.url == hidden })
        fixture.state.settings.includeHidden = true
        try await waitUntil("Changing visibility rebuilds the current index") {
            !fixture.state.isIndexing && fixture.state.indexRecords.contains { $0.node.url == hidden }
        }

        fixture.state.beginSearch()
        fixture.state.updateQuery("ext:txt")
        fixture.state.refresh()
        fixture.state.openWorkspace(second)
        try await waitUntil("The new session owns its index and insights") {
            !fixture.state.isIndexing && fixture.state.insights?.fileCount == 1 && fixture.state.indexRecords.count == 2
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(fixture.state.rootURL, second)
        XCTAssertEqual(Set(fixture.state.indexRecords.map(\.node.url)), [second, target])
        XCTAssertFalse(fixture.state.isSearchActive)
        XCTAssertEqual(fixture.state.query, "")
        XCTAssertTrue(fixture.state.searchMatches.isEmpty)
    }

    @MainActor
    func testInsightsUseActualDescendantsAndReturnToNormalTree() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = try fixture.folder("Project")
        _ = try fixture.file("Project/Small.txt", bytes: 1)
        let large = try fixture.file("Project/Sources/Repeat.txt", bytes: 20)
        let repeated = try fixture.file("Project/Other/Repeat.txt", bytes: 5)
        fixture.state.openWorkspace(root)
        try await waitUntil("Completed insights arrive") { !fixture.state.isIndexing && fixture.state.insights != nil }
        let summary = try XCTUnwrap(fixture.state.insights)
        XCTAssertEqual(summary.fileCount, 3)
        XCTAssertEqual(summary.folderCount, 2)
        XCTAssertEqual(summary.totalBytes, 26)
        XCTAssertEqual(summary.duplicateNameGroups.first?.count, 2)
        let normalIDs = fixture.state.columns.map(\.id)
        fixture.state.showInsight(.largest)
        XCTAssertEqual(fixture.state.columns.first?.items.first?.url, large)
        XCTAssertEqual(fixture.state.rootURL, root)
        fixture.state.showInsight(.duplicateNames)
        XCTAssertEqual(Set(fixture.state.columns.flatMap(\.items).map(\.url)), [large, repeated])
        fixture.state.escape()
        XCTAssertEqual(fixture.state.insightMode, .none)
        XCTAssertEqual(fixture.state.columns.map(\.id), normalIDs)
        XCTAssertEqual(fixture.state.rootURL, root)
    }

    @MainActor
    func testCSVQuotesRealNamesAndNeutralizesSpreadsheetFormulas() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = try fixture.folder("Project")
        _ = try fixture.file("Project/=SUM(1,2).txt", bytes: 1)
        _ = try fixture.file("Project/line,\n\"quote\".txt", bytes: 2)
        _ = try fixture.file("Project/\n=SUM(2,3).txt", bytes: 3)
        fixture.state.openWorkspace(root)
        try await waitUntil("Real manifest records arrive") { !fixture.state.isIndexing && fixture.state.indexRecords.count == 4 }
        let csv = AppState.inventoryCSV(fixture.state.indexRecords)
        XCTAssertTrue(csv.contains("\"'=SUM(1,2).txt\""))
        XCTAssertTrue(csv.contains("\"line,\n\"\"quote\"\".txt\""))
        XCTAssertTrue(csv.contains("\"'\n=SUM(2,3).txt\""), "A leading newline cannot bypass spreadsheet-formula neutralization.")
        XCTAssertFalse(csv.contains(root.path), "Manifest paths must be relative descendants, without the contextual root row.")
        XCTAssertTrue(csv.contains(",\"finished\"\r\n"))
        let partial = AppState.inventoryCSV(fixture.state.indexRecords, indexFinished: false)
        XCTAssertTrue(partial.contains(",\"in progress\"\r\n"), "A saved partial manifest must retain its snapshot status.")
    }

    func testKeyboardCommandsRespectTextEditingAndMatchDirection() {
        for key: UInt16 in [123, 124, 125, 126, 36, 49] {
            XCTAssertNil(OverlayCommand.match(keyCode: key, flags: [], folder: true, editing: true),
                         "Typing and navigating inside an editor must not trigger tree/file commands.")
        }
        XCTAssertEqual(OverlayCommand.match(keyCode: 125, flags: [], folder: true, editing: false), .down)
        XCTAssertNil(OverlayCommand.match(keyCode: 125, flags: [], folder: false, editing: false))
        XCTAssertEqual(OverlayCommand.match(keyCode: 5, flags: .command, folder: true, editing: true), .nextMatch)
        XCTAssertEqual(OverlayCommand.match(keyCode: 5, flags: [.command, .shift], folder: true, editing: true), .previousMatch)
        XCTAssertNil(OverlayCommand.match(keyCode: 15, flags: .command, folder: true, editing: true))
        XCTAssertEqual(OverlayCommand.match(keyCode: 15, flags: .command, folder: true, editing: false), .refresh)
        XCTAssertEqual(OverlayCommand.match(keyCode: 35, flags: [.command, .shift], folder: false, editing: true), .pin)
    }

    @MainActor
    func testDiagnosticsDistinguishMissingBlockedAndPausedObservations() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let root = try fixture.folder("Project")
        let node = try DirectoryReader.node(at: root)
        fixture.state.updateDiagnostics(FinderObservation(node: nil, bounds: nil, blocked: false,
                                                          finderActive: false, pointer: .zero))
        XCTAssertEqual(fixture.state.diagnosticReason, "No verified Finder item beneath the pointer.")
        XCTAssertFalse(fixture.state.diagnosticFinderOwned)
        fixture.state.updateDiagnostics(FinderObservation(node: node, bounds: nil, blocked: true,
                                                          finderActive: false, pointer: .zero,
                                                          pointerOverFinder: true))
        XCTAssertTrue(fixture.state.diagnosticReason.contains("blocked"))
        XCTAssertTrue(fixture.state.diagnosticFinderOwned)
        XCTAssertNotNil(fixture.state.diagnosticTimestamp)
        fixture.state.settings.enabled = false
        fixture.state.updateDiagnostics(FinderObservation(node: node, bounds: nil, blocked: false,
                                                          finderActive: true, pointer: .zero,
                                                          pointerOverFinder: true))
        XCTAssertEqual(fixture.state.diagnosticReason, "Hoover is paused.")
    }

    @MainActor
    private func waitUntil(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    @MainActor
    private final class Fixture {
        let state: AppState
        let defaults: UserDefaults
        let suite = "HooverAdvancedState-" + UUID().uuidString
        let directory: URL

        init() throws {
            _ = NSApplication.shared
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            // Coordinator tests do not need framework preview subprocesses.
            defaults.set(false, forKey: "Hoover.showPreviews")
            defaults.set(false, forKey: "Hoover.showThumbnail")
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            state = AppState(settings: HooverSettings(defaults: defaults), workspace: WorkspaceStore(defaults: defaults))
        }

        func folder(_ path: String) throws -> URL {
            let url = directory.appendingPathComponent(path, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func file(_ path: String, bytes: Int) throws -> URL {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 120, count: bytes).write(to: url)
            return url
        }

        func cleanup() {
            state.dismiss(restoreFinder: false)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
