import AppKit
import Foundation
import HooverCore
import XCTest
@testable import Hoover

final class AppStateTests: XCTestCase {
    @MainActor
    func testVerifiedBackgroundFinderHoverOpensRealFolderAfterFullDwell() async throws {
        var timestamp: TimeInterval = 100
        let (state, defaults, suite) = try makeState(monotonicTime: { timestamp })
        let root = try makeFolderFixture()
        defer {
            state.dismiss(restoreFinder: false)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let observation = backgroundFolderObservation(root, verified: true)
        XCTAssertEqual(state.settings.folderDelay, 3)

        state.observeFinder(observation)
        timestamp = 102.999
        state.observeFinder(observation)
        XCTAssertNil(state.rootURL, "A background Finder item must still receive the full folder dwell.")
        XCTAssertFalse(state.overlay.isVisible)

        timestamp = 103
        state.observeFinder(observation)
        XCTAssertEqual(state.rootURL, root.standardizedFileURL)
        XCTAssertTrue(state.overlay.isVisible, "Verified pointer ownership permits no-click hovering over background Finder.")

        // Enumeration is real and asynchronous; allow it to finish without
        // starting the Accessibility tracker or waiting through a real dwell.
        for _ in 0..<100 {
            if state.columns.first?.isLoading == false { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let first = try XCTUnwrap(state.columns.first)
        XCTAssertEqual(first.parentURL, root.standardizedFileURL)
        XCTAssertEqual(first.level, 1)
        XCTAssertFalse(first.isLoading)
        XCTAssertNil(first.error)
        XCTAssertEqual(Set(first.items.map(\.name)), ["README.md", "Sources"])
    }

    @MainActor
    func testUnverifiedBackgroundFinderObservationNeverOpensFolder() throws {
        var timestamp: TimeInterval = 100
        let (state, defaults, suite) = try makeState(monotonicTime: { timestamp })
        let root = try makeFolderFixture()
        defer {
            state.dismiss(restoreFinder: false)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let observation = backgroundFolderObservation(root, verified: false)

        for time in [100.0, 103.0, 200.0] {
            timestamp = time
            state.observeFinder(observation)
            XCTAssertNil(state.rootURL, "A stale item without foreground Finder or verified pointer ownership cannot activate.")
            XCTAssertFalse(state.overlay.isVisible)
            XCTAssertTrue(state.columns.isEmpty)
        }
    }

    @MainActor
    func testBlockedBackgroundFinderHoverRequiresFreshFullDwell() throws {
        var timestamp: TimeInterval = 100
        let (state, defaults, suite) = try makeState(monotonicTime: { timestamp })
        let root = try makeFolderFixture()
        defer {
            state.dismiss(restoreFinder: false)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let observation = backgroundFolderObservation(root, verified: true)
        state.observeFinder(observation)
        timestamp = 102
        state.observeFinder(backgroundFolderObservation(root, verified: true, blocked: true))
        XCTAssertNil(state.rootURL)
        XCTAssertFalse(state.overlay.isVisible)

        // The first unblocked observation begins a new dwell. Time accumulated
        // before or during the blocked interaction must not activate the HUD.
        timestamp = 105
        state.observeFinder(observation)
        XCTAssertNil(state.rootURL)
        timestamp = 107.999
        state.observeFinder(observation)
        XCTAssertNil(state.rootURL)
        XCTAssertFalse(state.overlay.isVisible)

        timestamp = 108
        state.observeFinder(observation)
        XCTAssertEqual(state.rootURL, root.standardizedFileURL)
        XCTAssertTrue(state.overlay.isVisible)
    }

    @MainActor
    func testFirstEscapeRestoresBrowsingContextAndSecondEscapeDismisses() async throws {
        let (state, defaults, suite) = try makeState()
        defer {
            state.dismiss()
            defaults.removePersistentDomain(forName: suite)
        }
        let root = temporaryRoot()
        let branch = FileNode(url: root.appendingPathComponent("Sources"), isDirectory: true)
        let normalFocus = FileNode(url: branch.url.appendingPathComponent("Application.swift"), isDirectory: false)
        let searchFocus = FileNode(url: root.appendingPathComponent("Tests/ConfigurationTests.swift"), isDirectory: false)
        let normal = [
            TreeColumn(parentURL: root, level: 1, items: [branch]),
            TreeColumn(parentURL: branch.url, level: 2, items: [normalFocus], error: "A retained column status")
        ]
        let normalPath: Set<String> = [root.path, branch.id, normalFocus.id]
        state.rootURL = root
        state.columns = normal
        state.focusedNode = normalFocus
        state.selectedPath = normalPath

        state.beginSearch()
        XCTAssertTrue(state.isSearchActive)
        state.query = "Configuration"
        state.searchMatchCount = 1
        state.columns = [TreeColumn(parentURL: root, level: 3, items: [searchFocus])]
        state.focusedNode = searchFocus
        state.selectedPath = [root.path, searchFocus.id]
        // Repeated Command-F must focus search without replacing the first snapshot.
        state.beginSearch()
        state.escape()

        XCTAssertFalse(state.isSearchActive)
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.searchMatchCount, 0)
        XCTAssertEqual(state.rootURL, root)
        assertColumns(state.columns, equalTo: normal)
        XCTAssertEqual(state.focusedNode, normalFocus)
        XCTAssertEqual(state.selectedPath, normalPath)

        state.escape()
        XCTAssertNil(state.rootURL)
        XCTAssertNil(state.focusedNode)
        XCTAssertNil(state.preview)
        XCTAssertTrue(state.columns.isEmpty)
        XCTAssertTrue(state.selectedPath.isEmpty)
        XCTAssertFalse(state.isSearchActive)
        XCTAssertFalse(state.isIndexing)
    }

    @MainActor
    func testSearchExitRestoresAnAbsentFocus() async throws {
        let (state, defaults, suite) = try makeState()
        defer {
            state.dismiss()
            defaults.removePersistentDomain(forName: suite)
        }
        let root = temporaryRoot()
        let file = FileNode(url: root.appendingPathComponent("README.md"), isDirectory: false)
        let normal = [TreeColumn(parentURL: root, level: 1, items: [file])]
        state.rootURL = root
        state.columns = normal
        state.focusedNode = nil
        state.selectedPath = [root.path]

        state.beginSearch()
        state.focusedNode = file
        state.selectedPath = [root.path, file.id]
        state.escape()

        XCTAssertNil(state.focusedNode, "A search selection must not become the restored browsing focus.")
        XCTAssertEqual(state.selectedPath, [root.path])
        assertColumns(state.columns, equalTo: normal)
    }

    @MainActor
    func testClearingQueryRestoresColumnsAndCancelledFilterCannotReplaceThem() async throws {
        let (state, defaults, suite) = try makeState()
        defer {
            state.dismiss()
            defaults.removePersistentDomain(forName: suite)
        }
        let root = temporaryRoot()
        let file = FileNode(url: root.appendingPathComponent("README.md"), isDirectory: false)
        let normal = [TreeColumn(parentURL: root, level: 1, items: [file])]
        state.rootURL = root
        state.columns = normal
        state.selectedPath = [root.path]
        state.beginSearch()

        state.updateQuery("readme")
        // A replacement query arrives while the asynchronous filter is pending.
        state.columns = []
        state.updateQuery("")
        assertColumns(state.columns, equalTo: normal)
        XCTAssertTrue(state.isSearchActive, "Clearing a query must retain search mode.")
        XCTAssertEqual(state.searchMatchCount, 0)
        try await Task.sleep(nanoseconds: 100_000_000)
        assertColumns(state.columns, equalTo: normal)

        state.updateQuery("swift")
        state.escape()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(state.isSearchActive)
        assertColumns(state.columns, equalTo: normal)
        XCTAssertEqual(state.query, "")
    }

    @MainActor
    func testSearchRequiresAnActiveFolderSession() async throws {
        let (state, defaults, suite) = try makeState()
        defer { defaults.removePersistentDomain(forName: suite) }
        state.beginSearch()
        XCTAssertFalse(state.isSearchActive)
        XCTAssertNil(state.rootURL)
        XCTAssertTrue(state.columns.isEmpty)
    }

    func testSearchColumnIdentifiersStayUniqueAcrossMixedAncestryLevels() {
        let root = temporaryRoot()
        // Multiple result branches at different depths may all use root as the
        // common parent context. SwiftUI still needs distinct stable column IDs.
        let shallow = TreeColumn(parentURL: root, level: 1, items: [])
        let middle = TreeColumn(parentURL: root, level: 2, items: [])
        let deep = TreeColumn(parentURL: root, level: 5, items: [])
        XCTAssertEqual(Set([shallow.id, middle.id, deep.id]).count, 3)
        let populated = TreeColumn(parentURL: root, level: 2,
                                   items: [FileNode(url: root.appendingPathComponent("Result.swift"), isDirectory: false)])
        XCTAssertEqual(middle.id, populated.id, "Result updates should preserve column identity.")
    }

    @MainActor
    private func makeState(monotonicTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws -> (AppState, UserDefaults, String) {
        // AppState's lazy overlay may instantiate an NSPanel during dismissal.
        // No tracker is started and no macOS permission prompt is requested.
        _ = NSApplication.shared
        let suite = "HooverAppStateTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (AppState(settings: HooverSettings(defaults: defaults), workspace: WorkspaceStore(defaults: defaults), monotonicTime: monotonicTime), defaults, suite)
    }

    private func makeFolderFixture() throws -> URL {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources", isDirectory: true),
                                                withIntermediateDirectories: true)
        try Data("A real coordinator test fixture.\n".utf8).write(to: root.appendingPathComponent("README.md"))
        return root
    }

    private func backgroundFolderObservation(_ root: URL, verified: Bool, blocked: Bool = false) -> FinderObservation {
        let bounds = CGRect(x: 40, y: 40, width: 220, height: 24)
        return FinderObservation(node: FileNode(url: root, isDirectory: true), bounds: bounds,
                                 blocked: blocked, finderActive: false,
                                 pointer: CGPoint(x: bounds.midX, y: bounds.midY),
                                 pointerOverFinder: verified)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HooverSession-" + UUID().uuidString, isDirectory: true)
    }

    private func assertColumns(_ actual: [TreeColumn], equalTo expected: [TreeColumn],
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actual, expected) in zip(actual, expected) {
            XCTAssertEqual(actual.id, expected.id, file: file, line: line)
            XCTAssertEqual(actual.parentURL, expected.parentURL, file: file, line: line)
            XCTAssertEqual(actual.level, expected.level, file: file, line: line)
            XCTAssertEqual(actual.items, expected.items, file: file, line: line)
            XCTAssertEqual(actual.error, expected.error, file: file, line: line)
            XCTAssertEqual(actual.isLoading, expected.isLoading, file: file, line: line)
        }
    }
}
