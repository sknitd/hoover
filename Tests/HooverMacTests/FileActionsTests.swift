import AppKit
import Foundation
import HooverCore
import XCTest
@testable import Hoover

final class FileActionsTests: XCTestCase {
    @MainActor
    func testNativeTrashMovesOnlyCreatedFileAndReportsResultURL() async throws {
        try await verifyTrash(folder: false)
    }

    @MainActor
    func testNativeTrashMovesCreatedFolderWithContentsAndReportsResultURL() async throws {
        try await verifyTrash(folder: true)
    }

    @MainActor
    private func verifyTrash(folder: Bool) async throws {
        guard ProcessInfo.processInfo.environment["HOOVER_NATIVE_ACTION_TESTS"] == "1" else {
            throw XCTSkip("Set HOOVER_NATIVE_ACTION_TESTS=1 to test native Trash using disposable test-owned items.")
        }
        _ = NSApplication.shared
        let suite = "HooverTrashTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = HooverSettings(defaults: defaults)
        settings.confirmTrash = false
        let action = FileActions(settings: settings)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let item = directory.appendingPathComponent(folder ? suite : suite + ".txt", isDirectory: folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if folder {
            try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
            try Data("fixture child".utf8).write(to: item.appendingPathComponent("child.txt"))
        } else { try Data("fixture file".utf8).write(to: item) }
        var trashed: URL?
        defer {
            // This URL is supplied by native Trash for this test's own random
            // item. Never enumerate, empty, or remove anything else in the Bin.
            if let trashed { try? FileManager.default.removeItem(at: trashed) }
            try? FileManager.default.removeItem(at: directory)
        }
        var changed: URL?, original: URL?, failure: String?
        action.onTrashed = { source, result in original = source; trashed = result }
        action.onChanged = { changed = $0 }
        action.onError = { failure = $0 }
        action.moveToTrash(try DirectoryReader.node(at: item))
        XCTAssertNil(failure)
        XCTAssertEqual(original, item)
        XCTAssertEqual(changed, item)
        let result = try XCTUnwrap(trashed, "Native Trash must report this exact test item's destination")
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        if folder {
            XCTAssertEqual(try String(contentsOf: result.appendingPathComponent("child.txt"), encoding: .utf8), "fixture child")
        } else { XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "fixture file") }
    }

    @MainActor
    func testClipboardCopiesExactPathNameAndFileURL() async throws {
        guard ProcessInfo.processInfo.environment["HOOVER_NATIVE_ACTION_TESTS"] == "1" else {
            throw XCTSkip("Native clipboard checks are opt-in and preserve accessible prior representations in memory.")
        }
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { pasteboard.clearContents(); if !saved.isEmpty { pasteboard.writeObjects(saved) } }
        let suite = "HooverClipboardTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let actions = FileActions(settings: HooverSettings(defaults: defaults))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(suite + " quote ' café.txt")
        try Data("clipboard fixture".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let node = try DirectoryReader.node(at: url)
        actions.copyPath(node)
        XCTAssertEqual(pasteboard.string(forType: .string), url.path)
        actions.copyName(node)
        XCTAssertEqual(pasteboard.string(forType: .string), url.lastPathComponent)
        actions.copy(node)
        let copied = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        XCTAssertEqual(copied?.map(\.standardizedFileURL), [url.standardizedFileURL])
    }
}
