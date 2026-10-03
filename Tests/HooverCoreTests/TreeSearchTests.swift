import Foundation
import XCTest
@testable import HooverCore

final class TreeSearchTests: XCTestCase {
    private func record(_ path: String, parent: String? = nil, folder: Bool = false, depth: Int = 1) -> IndexRecord {
        let root = "/tmp/search-root"
        return IndexRecord(node: FileNode(url: URL(fileURLWithPath: root + (path.isEmpty ? "" : "/" + path)),
                                          isDirectory: folder),
                           parentID: parent.map { root + ($0.isEmpty ? "" : "/" + $0) },
                           depth: depth, relativePath: path)
    }

    func testRankingSeparatesFullNameBasenamePrefixSubstringAndExtension() {
        let records = [record("Controller.swift"), record("otherController.txt"),
                       record("ControllerTests.swift"), record("Controller"), record("Other.swift")]
        let controller = TreeSearch.search(query: "controller", records: records)
        XCTAssertEqual(controller.matches.map(\.record.node.name),
                       ["Controller", "Controller.swift", "ControllerTests.swift", "otherController.txt"])
        XCTAssertEqual(controller.matches.map(\.rank), [0, 1, 2, 3])
        XCTAssertEqual(TreeSearch.search(query: "Controller.swift", records: records).matches.first?.rank, 0)
        let ext = TreeSearch.search(query: "swift", records: records)
        XCTAssertEqual(ext.matches.count, 3)
        XCTAssertTrue(ext.matches.allSatisfy { $0.rank == 4 })
        XCTAssertEqual(TreeSearch.search(query: ".swift", records: records).matches.count, 3)
    }

    func testDeepMultipleMatchesPreserveEveryRequiredAncestorWithoutSiblings() {
        let records = [record("", folder: true, depth: 0),
                       record("App", parent: "", folder: true),
                       record("App/Core", parent: "App", folder: true, depth: 2),
                       record("App/Core/Config.swift", parent: "App/Core", depth: 3),
                       record("App/Core/Noise.swift", parent: "App/Core", depth: 3),
                       record("Tests", parent: "", folder: true),
                       record("Tests/ConfigTests.swift", parent: "Tests", depth: 2),
                       record("Unrelated", parent: "", folder: true)]
        let result = TreeSearch.search(query: "config", records: records)
        XCTAssertEqual(result.matches.map(\.record.node.name), ["Config.swift", "ConfigTests.swift"])
        XCTAssertEqual(result.visibleIDs, Set(records.filter {
            !["Noise.swift", "Unrelated"].contains($0.node.name)
        }.map(\.node.id)))
    }

    func testFolderNamesCaseDiacriticsAndOptionalFuzzyFallback() {
        let folder = record("Café Resources", folder: true)
        XCTAssertEqual(TreeSearch.search(query: "CAFE", records: [folder]).matches.first?.rank, 2)
        let code = record("DockController.swift")
        XCTAssertTrue(TreeSearch.search(query: "dct", records: [code]).matches.isEmpty)
        XCTAssertEqual(TreeSearch.search(query: "dct", records: [code], fuzzy: true).matches.first?.rank, 5)
        XCTAssertTrue(TreeSearch.search(query: "zzz", records: [code], fuzzy: true).matches.isEmpty)
    }

    func testEmptyQueryRestoresAllIDsAndNoMatchHasNoVisibleBranches() {
        let records = [record("App", folder: true), record("file.md")]
        XCTAssertEqual(TreeSearch.search(query: "  ", records: records).visibleIDs, Set(records.map(\.node.id)))
        XCTAssertTrue(TreeSearch.search(query: "missing", records: records).visibleIDs.isEmpty)
    }

    func testMalformedAncestorCycleCannotHangSearch() {
        let a = record("a", parent: "b", folder: true)
        let b = record("b", parent: "a", folder: true)
        XCTAssertEqual(TreeSearch.search(query: "a", records: [a, b]).visibleIDs, [a.node.id, b.node.id])
    }
}
