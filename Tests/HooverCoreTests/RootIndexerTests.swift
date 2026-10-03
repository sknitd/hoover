import Foundation
import XCTest
@testable import HooverCore

final class RootIndexerTests: XCTestCase {
    private var temporary: URL!
    private var root: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("hoover-tests-" + UUID().uuidString)
        root = temporary.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporary)
    }

    @discardableResult
    private func file(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test".utf8).write(to: url)
        return url
    }

    private func collect(includeHidden: Bool = false, includePackages: Bool = false,
                         followSymlinks: Bool = false, maxDepth: Int? = nil) async -> [IndexRecord] {
        var records: [IndexRecord] = []
        for await batch in RootIndexer().stream(root: root, includeHidden: includeHidden,
                                              includePackages: includePackages, followSymlinks: followSymlinks,
                                              maxDepth: maxDepth) {
            records.append(contentsOf: batch)
        }
        return records
    }

    func testDirectReaderMetadataDirectorySortingAndHiddenVisibility() throws {
        let ordinary = try file("file.txt")
        try file(".hidden")
        try file("folder/nested.txt")
        let children = try DirectoryReader.contents(of: root)
        XCTAssertEqual(children.map(\.name), ["folder", "file.txt"])
        XCTAssertEqual(try DirectoryReader.contents(of: root, includeHidden: true).count, 3)
        let node = try DirectoryReader.node(at: ordinary)
        XCTAssertFalse(node.isDirectory)
        XCTAssertEqual(node.size, 4)
        XCTAssertNotNil(node.modified)
        XCTAssertEqual(node.id, ordinary.standardizedFileURL.path)
        XCTAssertThrowsError(try DirectoryReader.contents(of: ordinary))
    }

    func testProgressiveBreadthFirstBatchesHaveNoImplicitDepthLimit() async throws {
        for index in 0..<300 { try file("wide/file-\(index).txt") }
        let deep = (0..<12).map { "level-\($0)" }.joined(separator: "/") + "/target.swift"
        try file(deep)
        var batches: [[IndexRecord]] = []
        for await batch in RootIndexer().stream(root: root) { batches.append(batch) }
        XCTAssertGreaterThan(batches.count, 2)
        XCTAssertTrue(batches.allSatisfy { $0.count <= 128 })
        let records = batches.flatMap { $0 }
        XCTAssertEqual(records.count, 315)
        XCTAssertEqual(records.first?.node.url, root)
        XCTAssertEqual(records.first?.depth, 0)
        XCTAssertTrue(records.contains { $0.relativePath == deep && $0.depth == 13 })
        XCTAssertEqual(records.map(\.depth), records.map(\.depth).sorted())
        XCTAssertEqual(Set(records.map(\.node.id)).count, records.count)
    }

    func testHiddenAndPackageOptionsAreIndependentAndExplicitDepthIsRespected() async throws {
        try file(".hidden/deep.txt")
        try file("Sample.app/Contents/info.txt")
        try file("visible/deep.txt")
        let standard = await collect()
        XCTAssertFalse(standard.contains { $0.relativePath.hasPrefix(".hidden") })
        XCTAssertTrue(standard.contains { $0.relativePath == "Sample.app" })
        XCTAssertFalse(standard.contains { $0.relativePath == "Sample.app/Contents" })
        let all = await collect(includeHidden: true, includePackages: true)
        XCTAssertTrue(all.contains { $0.relativePath == ".hidden/deep.txt" })
        XCTAssertTrue(all.contains { $0.relativePath == "Sample.app/Contents/info.txt" })
        let shallow = await collect(includeHidden: true, includePackages: true, maxDepth: 1)
        XCTAssertTrue(shallow.allSatisfy { $0.depth <= 1 })
        let rootOnly = await collect(maxDepth: 0)
        XCTAssertEqual(rootOnly.count, 1)
    }

    func testDefaultNeverFollowsSymlinksAndOptInCannotEscapeRootOrLoop() async throws {
        try file("inside/real.txt")
        let external = temporary.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: external.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: external)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("inside/loop"), withDestinationURL: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("shortcut"), withDestinationURL: root.appendingPathComponent("inside"))
        let standard = await collect()
        XCTAssertTrue(standard.contains { $0.relativePath == "escape" && $0.node.isSymbolicLink })
        XCTAssertFalse(standard.contains { $0.relativePath.hasPrefix("shortcut/") })
        let followed = await collect(followSymlinks: true)
        XCTAssertFalse(followed.contains { $0.relativePath.hasPrefix("escape/") })
        XCTAssertFalse(followed.contains { $0.relativePath.contains("loop/") })
        XCTAssertEqual(followed.filter { $0.node.name == "real.txt" }.count, 1)
        XCTAssertLessThan(followed.count, 10)
    }

    func testCancellationStopsConsumerAndDoesNotPublishTheRestOfTree() async throws {
        for index in 0..<500 { try file("file-\(index).txt") }
        let root = self.root!
        let task = Task<Int, Never> {
            var count = 0
            for await batch in RootIndexer().stream(root: root) {
                count += batch.count
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return count
        }
        let count = await task.value
        XCTAssertGreaterThan(count, 0)
        XCTAssertLessThan(count, 501)
    }

    func testMissingRootFinishesCleanlyAndFileRootDoesNotTraverse() async throws {
        let ordinary = try file("file.txt")
        var fileRecords: [IndexRecord] = []
        for await batch in RootIndexer().stream(root: ordinary) { fileRecords += batch }
        XCTAssertEqual(fileRecords.count, 1)
        var missingRecords: [IndexRecord] = []
        for await batch in RootIndexer().stream(root: root.appendingPathComponent("missing")) { missingRecords += batch }
        XCTAssertTrue(missingRecords.isEmpty)
    }

    func testSymbolicLinkRootIndexesItsOwnResolvedSubtree() async throws {
        try file("inside/real.txt")
        let linkedRoot = temporary.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
        var records: [IndexRecord] = []
        for await batch in RootIndexer().stream(root: linkedRoot) { records += batch }
        XCTAssertTrue(records.contains { $0.relativePath == "inside/real.txt" })
        XCTAssertTrue(records.allSatisfy { $0.node.id.hasPrefix(linkedRoot.path) })
    }

    func testExclusionsPruneBeforeTraversalAndUseComponentBoundaries() async throws {
        try file("blocked/deeper/secret.txt")
        try file("blocked-sibling/allowed.txt")
        try file("public/allowed.txt")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("shortcut"),
                                                 withDestinationURL: root.appendingPathComponent("blocked"))
        var records: [IndexRecord] = []
        for await batch in RootIndexer().stream(root: root, followSymlinks: true,
                                               excludedPaths: [root.appendingPathComponent("blocked").path]) {
            records += batch
        }
        XCTAssertFalse(records.contains { $0.relativePath == "blocked" || $0.relativePath.hasPrefix("blocked/") })
        XCTAssertFalse(records.contains { $0.relativePath.hasPrefix("shortcut") })
        XCTAssertTrue(records.contains { $0.relativePath == "blocked-sibling/allowed.txt" })
        XCTAssertTrue(records.contains { $0.relativePath == "public/allowed.txt" })
        var excludedRootRecords: [IndexRecord] = []
        for await batch in RootIndexer().stream(root: root, excludedPaths: [root.path]) { excludedRootRecords += batch }
        XCTAssertTrue(excludedRootRecords.isEmpty)
    }

    func testSlowConsumerReceivesEveryItemWithoutDroppingBufferedBatches() async throws {
        for index in 0..<2_000 { try file("file-\(index).txt") }
        let stream = RootIndexer().stream(root: root)
        // Let the producer fill its bounded buffer before consumption begins.
        try await Task.sleep(nanoseconds: 80_000_000)
        var records: [IndexRecord] = []
        for await batch in stream {
            records += batch
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(records.count, 2_001)
        XCTAssertEqual(Set(records.map(\.node.id)).count, records.count)
    }
}
