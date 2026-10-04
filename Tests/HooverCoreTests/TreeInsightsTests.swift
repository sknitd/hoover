import Foundation
import XCTest
@testable import HooverCore

final class TreeInsightsTests: XCTestCase {
    private func node(_ path: String, folder: Bool = false, size: Int64? = nil,
                      modified: Date? = nil, symlink: Bool = false) -> FileNode {
        FileNode(url: URL(fileURLWithPath: "/tmp/insight-root/" + path), isDirectory: folder,
                 isSymbolicLink: symlink, size: size, modified: modified)
    }

    private func record(_ node: FileNode, depth: Int = 1) -> IndexRecord {
        IndexRecord(node: node, parentID: depth == 0 ? nil : node.url.deletingLastPathComponent().path,
                    depth: depth, relativePath: node.name)
    }

    func testNaturalNamesFoldersFirstDescendingAndStableEqualNames() {
        let ten = node("item10.txt"), two = node("item2.txt"), one = node("item1.txt")
        let folder = node("zFolder", folder: true)
        XCTAssertEqual(TreeOrdering.sorted([ten, two, folder, one]).map(\.name), ["zFolder", "item1.txt", "item2.txt", "item10.txt"])
        XCTAssertEqual(TreeOrdering.sorted([ten, two, folder, one], ascending: false).map(\.name), ["zFolder", "item10.txt", "item2.txt", "item1.txt"])
        let upper = node("a/Report.txt"), lower = node("b/report.txt")
        XCTAssertEqual(TreeOrdering.sorted([upper, lower], foldersFirst: false).map(\.id), [upper.id, lower.id])
        XCTAssertEqual(TreeOrdering.sorted([lower, upper], ascending: false, foldersFirst: false).map(\.id), [lower.id, upper.id])
    }

    func testSizeModifiedAndKindSortingKeepUnknownValuesLastInEitherDirection() {
        let old = node("old.swift", size: 2, modified: Date(timeIntervalSince1970: 1))
        let new = node("new.png", size: 10, modified: Date(timeIntervalSince1970: 2))
        let unknown = node("unknown.txt"), invalid = node("negative.bin", size: -1)
        XCTAssertEqual(TreeOrdering.sorted([unknown, new, old], by: .size).map(\.id), [old.id, new.id, unknown.id])
        XCTAssertEqual(TreeOrdering.sorted([old, unknown, new], by: .size, ascending: false).map(\.id), [new.id, old.id, unknown.id])
        XCTAssertEqual(TreeOrdering.sorted([unknown, new, old], by: .modified).map(\.id), [old.id, new.id, unknown.id])
        XCTAssertEqual(TreeOrdering.sorted([old, unknown, new], by: .modified, ascending: false).map(\.id), [new.id, old.id, unknown.id])
        XCTAssertEqual(TreeOrdering.sorted([unknown, new, old], by: .kind).map(\.id), [old.id, unknown.id, new.id])
        XCTAssertEqual(TreeOrdering.sorted([invalid, old], by: .size).last?.id, invalid.id)
    }

    func testSummaryUsesOnlyIndexedDescendantsAndLatestMetadataForRepeatedIDs() {
        let root = node("", folder: true, size: 999_999)
        let directory = node("Sources", folder: true, size: 4_096)
        let source = node("Sources/code.swift", size: 100, modified: Date(timeIntervalSince1970: 1))
        let refreshed = node("Sources/code.swift", size: 200, modified: Date(timeIntervalSince1970: 2))
        let unknown = node("unknown.bin")
        let symlink = node("link.txt", size: 10, symlink: true)
        let summary = TreeInsights.analyze([record(root, depth: 0), record(directory), record(source, depth: 2),
                                            record(refreshed, depth: 2), record(unknown), record(symlink)])
        XCTAssertEqual(summary.itemCount, 4)
        XCTAssertEqual(summary.folderCount, 1)
        XCTAssertEqual(summary.fileCount, 3)
        XCTAssertEqual(summary.symlinkCount, 1)
        XCTAssertEqual(summary.totalBytes, 210)
        XCTAssertEqual(summary.unknownSizeFileCount, 1)
        XCTAssertFalse(summary.totalBytesOverflowed)
        XCTAssertEqual(summary.extensionCounts, ["swift": 1, "bin": 1, "txt": 1])
        XCTAssertEqual(summary.kindCounts[.folder], 1)
        XCTAssertEqual(summary.kindCounts[.code], 1)
        XCTAssertEqual(summary.largestFiles.map(\.id), [refreshed.id, symlink.id])
        XCTAssertEqual(summary.recentlyModifiedFiles.map(\.id), [refreshed.id])
        XCTAssertTrue(summary.duplicateNameGroups.isEmpty)
    }

    func testKnownByteSumSaturatesAndSignalsOverflowWithoutCrashing() {
        let records = [record(node("largest.bin", size: .max)), record(node("extra.bin", size: 1)),
                       record(node("negative.bin", size: -4))]
        let summary = TreeInsights.analyze(records)
        XCTAssertEqual(summary.totalBytes, .max)
        XCTAssertTrue(summary.totalBytesOverflowed)
        XCTAssertEqual(summary.unknownSizeFileCount, 1)
        XCTAssertEqual(summary.largestFiles.count, 2)
    }

    func testTopNLargestAndRecentFilesAreMetadataBasedAndRespectLimits() {
        let nodes = [node("a.txt", size: 100, modified: Date(timeIntervalSince1970: 10)),
                     node("b.txt", size: 300, modified: Date(timeIntervalSince1970: 20)),
                     node("c.txt", size: 200, modified: Date(timeIntervalSince1970: 30)),
                     node("Folder", folder: true, size: 999, modified: Date(timeIntervalSince1970: 999))]
        let summary = TreeInsights.analyze(nodes.map { record($0) }, limit: 2)
        XCTAssertEqual(summary.largestFiles.map(\.name), ["b.txt", "c.txt"])
        XCTAssertEqual(summary.recentlyModifiedFiles.map(\.name), ["c.txt", "b.txt"])
        XCTAssertTrue(TreeInsights.analyze(nodes.map { record($0) }, limit: -1).largestFiles.isEmpty)
    }

    func testDuplicateNameGroupsUseNamesOnlyAcrossPathsNotContentClaims() {
        let upper = node("a/Report.pdf", size: 1), lower = node("b/report.pdf", size: 999)
        let cafe = node("a/café.txt"), plain = node("b/cafe.txt")
        let summary = TreeInsights.analyze([upper, lower, cafe, plain].map { record($0) })
        XCTAssertEqual(summary.duplicateNameGroups.count, 1)
        XCTAssertEqual(summary.duplicateNameGroups[0].count, 2)
        XCTAssertEqual(Set(summary.duplicateNameGroups[0].nodes.map(\.id)), [upper.id, lower.id])
        XCTAssertNotEqual(summary.duplicateNameGroups[0].nodes[0].size, summary.duplicateNameGroups[0].nodes[1].size)
    }

    func testEmptyTreeNoExtensionClassificationAndNoSymlinkTraversal() {
        let empty = TreeInsights.analyze([])
        XCTAssertEqual(empty.itemCount, 0)
        XCTAssertEqual(empty.totalBytes, 0)
        let link = node("linkedFolder", folder: true, symlink: true)
        let plain = node("LICENSE", size: 5)
        let summary = TreeInsights.analyze([record(link), record(plain)])
        XCTAssertEqual(summary.itemCount, 2)
        XCTAssertEqual(summary.fileCount, 1)
        XCTAssertEqual(summary.folderCount, 1)
        XCTAssertEqual(summary.symlinkCount, 1)
        XCTAssertEqual(summary.extensionCounts[""], 1)
        XCTAssertEqual(FileKind.classify(plain), .file)
        XCTAssertEqual(FileKind.classify(link), .folder)
    }
}
