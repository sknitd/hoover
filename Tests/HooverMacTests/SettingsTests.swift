import Foundation
import XCTest
@testable import Hoover

final class SettingsTests: XCTestCase {
    @MainActor
    func testSafeDefaultsAndPreferenceClamping() async throws {
        let name = "HooverSettingsTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let fresh = HooverSettings(defaults: defaults)
        XCTAssertEqual(fresh.folderDelay, 3)
        XCTAssertEqual(fresh.fileDelay, 0.6)
        XCTAssertEqual(fresh.innerDelay, 0.3)
        XCTAssertTrue(fresh.confirmTrash)
        XCTAssertFalse(fresh.followSymlinks)
        XCTAssertFalse(fresh.liquidGlass)
        XCTAssertFalse(fresh.showCountdown)
        defaults.set(20.0, forKey: "Hoover.folderDelay")
        defaults.set(-5.0, forKey: "Hoover.fileDelay")
        defaults.set("Unknown", forKey: "Hoover.theme")
        defaults.set(["archive", "archive", "unknown"], forKey: "Hoover.metadataOrder")
        let restored = HooverSettings(defaults: defaults)
        XCTAssertEqual(restored.folderDelay, 5)
        XCTAssertEqual(restored.fileDelay, 0.1)
        XCTAssertEqual(restored.theme, "System")
        XCTAssertEqual(restored.metadataOrder.first, "archive")
        XCTAssertEqual(Set(restored.metadataOrder), Set(HooverSettings.categories))
        XCTAssertEqual(restored.metadataOrder.count, HooverSettings.categories.count)
    }

    @MainActor
    func testExclusionsRespectPathComponentsAndResolveSymlinks() async throws {
        let name = "HooverExclusionsTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = HooverSettings(defaults: defaults)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let excluded = directory.appendingPathComponent("private", isDirectory: true)
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: excluded)
        settings.exclusions = [excluded.path]
        XCTAssertTrue(settings.isExcluded(excluded.appendingPathComponent("file.txt")))
        XCTAssertTrue(settings.isExcluded(link))
        XCTAssertFalse(settings.isExcluded(directory.appendingPathComponent("private-other/file.txt")))
    }
}
