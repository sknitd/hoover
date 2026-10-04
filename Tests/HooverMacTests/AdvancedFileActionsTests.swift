import Darwin
import Foundation
import XCTest
@testable import Hoover

final class AdvancedFileActionsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HooverAdvancedFiles-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testRenameRejectsOverwriteAndPreservesBothFiles() throws {
        let source = try file("Source.txt", contents: "source")
        let existing = try file("Existing.txt", contents: "keep this")
        XCTAssertThrowsError(try AdvancedFileOperations.rename(from: source, to: existing.lastPathComponent))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "source")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep this")
        let renamed = try AdvancedFileOperations.rename(from: source, to: "Renamed.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "source")
    }

    func testUnsafeNamesCannotEscapeParentOrCreateEmptyEntries() throws {
        let source = try file("Source.txt")
        for name in ["", " ", ".", "..", "../Outside", "Sub/Folder", "bad:name", "bad\nname", "bad\u{0}name"] {
            XCTAssertThrowsError(try AdvancedFileOperations.rename(from: source, to: name), name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testDuplicatePreservesCompoundExtensionAndNeverOverwrites() throws {
        let source = try file("archive.tar.gz", contents: "archive source")
        let existing = try file("archive copy.tar.gz", contents: "existing copy")
        let duplicate = try AdvancedFileOperations.duplicate(source)
        XCTAssertEqual(duplicate.lastPathComponent, "archive copy 2.tar.gz")
        XCTAssertEqual(try String(contentsOf: duplicate, encoding: .utf8), "archive source")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "existing copy")
    }

    func testFolderDuplicateKeepsContentsWithoutRepeatingCopySuffix() throws {
        let folder = directory.appendingPathComponent("Project.v1 copy", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("nested".utf8).write(to: folder.appendingPathComponent("Nested.txt"))
        let duplicate = try AdvancedFileOperations.duplicate(folder)
        XCTAssertEqual(duplicate.lastPathComponent, "Project.v1 copy 2")
        XCTAssertEqual(try String(contentsOf: duplicate.appendingPathComponent("Nested.txt"), encoding: .utf8), "nested")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".hoover-copy-") }
        XCTAssertTrue(leftovers.isEmpty, "Temporary staging must be removed after a completed copy.")
    }

    func testNewFolderAllocatesDistinctNamesAndPreservesExistingContents() throws {
        let first = try AdvancedFileOperations.createFolder(in: directory)
        try Data("keep".utf8).write(to: first.appendingPathComponent("Existing.txt"))
        let second = try AdvancedFileOperations.createFolder(in: directory)
        XCTAssertEqual(first.lastPathComponent, "New Folder")
        XCTAssertEqual(second.lastPathComponent, "New Folder 2")
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("Existing.txt"), encoding: .utf8), "keep")
        XCTAssertTrue(try second.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }

    func testRelativePathRejectsSiblingPrefixesAndSymlinkEscapes() throws {
        let root = directory.appendingPathComponent("Root", isDirectory: true)
        let sibling = directory.appendingPathComponent("Root-other", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        let nested = root.appendingPathComponent("Nested/file.txt")
        XCTAssertEqual(try AdvancedFileOperations.relativePath(of: nested, root: root), "Nested/file.txt")
        XCTAssertEqual(try AdvancedFileOperations.relativePath(of: root, root: root), ".")
        XCTAssertThrowsError(try AdvancedFileOperations.relativePath(of: sibling.appendingPathComponent("file.txt"), root: root))
        let escape = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: sibling)
        XCTAssertThrowsError(try AdvancedFileOperations.relativePath(of: escape.appendingPathComponent("file.txt"), root: root))
    }

    func testScopedNewFolderRejectsSymlinkEscapeAndAcceptsExplicitSymlinkRoot() throws {
        let root = directory.appendingPathComponent("Root", isDirectory: true)
        let outside = directory.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        XCTAssertThrowsError(try AdvancedFileOperations.createFolder(in: alias, root: root))
        XCTAssertThrowsError(try AdvancedFileOperations.createFolder(in: alias))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        let created = try AdvancedFileOperations.createFolder(in: alias, root: alias)
        XCTAssertTrue(try created.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }

    func testSHA256MatchesKnownDigestAcrossTinyAndDefaultReadChunks() async throws {
        let url = try file("abc.txt", contents: "abc")
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let tiny = try await AdvancedFileOperations.sha256(of: url, chunkSize: 1)
        let standard = try await AdvancedFileOperations.sha256(of: url)
        XCTAssertEqual(tiny, expected)
        XCTAssertEqual(standard, expected)
    }

    func testChecksumRejectsDirectoriesSymlinksAndFIFOs() async throws {
        let target = try file("Target.txt")
        let link = directory.appendingPathComponent("Link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let pipe = directory.appendingPathComponent("Pipe")
        guard mkfifo(pipe.path, 0o600) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        for url in [directory!, link, pipe] {
            do {
                _ = try await AdvancedFileOperations.sha256(of: url)
                XCTFail("A directory, symlink, or FIFO must not be read as a regular file.")
            } catch is CancellationError { XCTFail("The rejection must describe the file kind.") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }

    func testCancelledChecksumDoesNotStartARead() async throws {
        let url = try file("Cancelled.txt")
        let task = Task {
            // Ignore the initial suspension's cancellation to exercise the
            // checksum's own pre-open cancellation gate on a cancelled task.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return try await AdvancedFileOperations.sha256(of: url)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("A cancelled checksum must not complete.") }
        catch is CancellationError { }
    }

    func testFinderTagEditingUsesNativeResourceValuesAndNormalizesDuplicates() throws {
        let target = try file("Tagged.txt")
        let tags = try AdvancedFileOperations.setTags([" Work ", "work", "Urgent", ""], for: target)
        XCTAssertEqual(tags, ["Work", "Urgent"])
        XCTAssertEqual(Set(try target.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []), Set(tags))
        try AdvancedFileOperations.setTags([], for: target)
        XCTAssertTrue(try target.resourceValues(forKeys: [.tagNamesKey]).tagNames?.isEmpty ?? true)
    }

    private func file(_ name: String, contents: String = "fixture") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
}
