import Foundation
import XCTest
@testable import Hoover

final class WorkspaceStoreTests: XCTestCase {
    @MainActor
    func testRecentRootsAreBoundedDeduplicatedAndPersistedInRecencyOrder() async throws {
        let (defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: defaults)
        let roots = (0..<15).map { URL(fileURLWithPath: "/tmp/HooverWorkspaceTests/Root\($0)", isDirectory: true) }
        roots.forEach(store.recordRoot)
        XCTAssertEqual(store.recentRoots.count, 12)
        XCTAssertEqual(store.recentRoots.first?.path, roots[14].path)
        XCTAssertFalse(store.recentRoots.contains { $0.path == roots[0].path })
        store.recordRoot(roots[8])
        XCTAssertEqual(store.recentRoots.first?.path, roots[8].path)
        XCTAssertEqual(store.recentRoots.filter { $0.path == roots[8].path }.count, 1)
        XCTAssertEqual(WorkspaceStore(defaults: defaults).recentRoots.map(\.path), store.recentRoots.map(\.path))
    }

    @MainActor
    func testFavoritesUseCanonicalVisiblePathsAndToggleAcrossReloads() async throws {
        let (defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: defaults)
        let root = URL(fileURLWithPath: "/tmp/HooverWorkspaceTests/Project", isDirectory: true)
        store.toggleFavorite(root)
        let restored = WorkspaceStore(defaults: defaults)
        XCTAssertEqual(restored.favorites.map(\.path), [root.path])
        restored.toggleFavorite(URL(fileURLWithPath: "/tmp/HooverWorkspaceTests/Other/../Project"))
        XCTAssertTrue(restored.favorites.isEmpty)
        XCTAssertTrue(WorkspaceStore(defaults: defaults).favorites.isEmpty)
    }

    @MainActor
    func testSavedSearchReplacementPreservesIdentityAndRemovalPersists() async throws {
        let (defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: defaults)
        let first = try XCTUnwrap(store.saveSearch(name: " Swift files ", query: " swift "))
        let replacement = try XCTUnwrap(store.saveSearch(name: "swift FILES", query: "Configuration.swift"))
        XCTAssertEqual(replacement.id, first.id)
        XCTAssertEqual(store.savedSearches.count, 1)
        let restored = WorkspaceStore(defaults: defaults)
        XCTAssertEqual(restored.savedSearches.first?.query, "Configuration.swift")
        XCTAssertEqual(restored.savedSearches.first?.id, first.id)
        restored.removeSavedSearch(id: first.id)
        XCTAssertTrue(WorkspaceStore(defaults: defaults).savedSearches.isEmpty)
    }

    @MainActor
    func testClearingHistoryPreservesFavoritesAndSavedQueries() async throws {
        let (defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: defaults)
        let root = URL(fileURLWithPath: "/tmp/HooverWorkspaceTests/Project", isDirectory: true)
        store.recordRoot(root)
        store.toggleFavorite(root)
        _ = store.saveSearch(name: "Docs", query: "md")
        store.clearHistory()
        let restored = WorkspaceStore(defaults: defaults)
        XCTAssertTrue(restored.recentRoots.isEmpty)
        XCTAssertEqual(restored.favorites.count, 1)
        XCTAssertEqual(restored.savedSearches.map(\.query), ["md"])
    }

    @MainActor
    func testInvalidInputsDoNotAddRemoteRootsOrEmptySearches() async throws {
        let (defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: defaults)
        let remote = try XCTUnwrap(URL(string: "https://example.test/private-root"))
        store.recordRoot(remote)
        store.toggleFavorite(remote)
        XCTAssertTrue(store.recentRoots.isEmpty)
        XCTAssertTrue(store.favorites.isEmpty)
        XCTAssertNil(store.saveSearch(name: " ", query: "swift"))
        XCTAssertNil(store.saveSearch(name: "Files", query: "\n"))
        XCTAssertTrue(store.savedSearches.isEmpty)
    }

    private func fixture() throws -> (UserDefaults, String) {
        let suite = "HooverWorkspaceStoreTests-" + UUID().uuidString
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }
}
