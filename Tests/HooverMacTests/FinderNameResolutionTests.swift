import Foundation
import XCTest
@testable import Hoover

final class FinderNameResolutionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HooverFinderNames-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testHiddenExtensionCollisionWithExactSiblingIsRejected() throws {
        let hidden = try file("Report.txt", hideExtension: true)
        let exact = try file("Report")
        let index = FinderDisplayNameIndex.scan(directory: directory)

        XCTAssertTrue(index.isComplete)
        XCTAssertNil(index.uniqueURL(matching: "Report"),
                     "The extensionless file must not win an ambiguous Finder display label.")
        XCTAssertEqual(index.uniqueURL(matching: "Report.txt")?.standardizedFileURL,
                       hidden.standardizedFileURL)
        XCTAssertNotEqual(hidden, exact)
    }

    func testUniqueHiddenExtensionDisplayLabelResolvesRealFile() throws {
        let hidden = try file("Guide.txt", hideExtension: true)
        _ = try file("Other.md")
        let index = FinderDisplayNameIndex.scan(directory: directory)

        XCTAssertTrue(index.isComplete)
        XCTAssertEqual(index.uniqueURL(matching: "Guide")?.standardizedFileURL,
                       hidden.standardizedFileURL)
        XCTAssertNil(index.uniqueURL(matching: "Missing"))
    }

    func testIncompleteRealDirectoryScanCannotClaimUniqueness() throws {
        _ = try file("First.txt")
        _ = try file("Second.txt")
        let partial = FinderDisplayNameIndex.scan(directory: directory, maximumEntries: 1)

        XCTAssertFalse(partial.isComplete)
        // Enumeration order is deliberately irrelevant: neither a seen nor an
        // unseen label is safe when the rest of the directory was not checked.
        XCTAssertNil(partial.uniqueURL(matching: "First.txt"))
        XCTAssertNil(partial.uniqueURL(matching: "Second.txt"))

        let complete = FinderDisplayNameIndex.scan(directory: directory, maximumEntries: 2)
        XCTAssertTrue(complete.isComplete, "Exactly reaching the cap is complete if no additional entry remains.")
        XCTAssertNotNil(complete.uniqueURL(matching: "First.txt"))
        XCTAssertNotNil(complete.uniqueURL(matching: "Second.txt"))
    }

    func testExactUnambiguousFilenameResolvesRealFile() throws {
        let target = try file("DockController.swift")
        _ = try file("README.md")
        let index = FinderDisplayNameIndex.scan(directory: directory)

        XCTAssertTrue(index.isComplete)
        XCTAssertEqual(index.uniqueURL(matching: "DockController.swift")?.standardizedFileURL,
                       target.standardizedFileURL)
    }

    func testOrdinaryDirectoryLabelResolvesAlongsideAFile() throws {
        let folder = directory.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        _ = try file("README.md")
        let index = FinderDisplayNameIndex.scan(directory: directory)

        XCTAssertTrue(index.isComplete, "Ordinary folder resource values must support a complete name snapshot.")
        XCTAssertEqual(index.uniqueURL(matching: "Sources")?.standardizedFileURL,
                       folder.standardizedFileURL)
        XCTAssertNotNil(index.uniqueURL(matching: "README.md"))
    }

    func testConflictingAndAmbiguousLabelAttributesCannotChooseAFile() throws {
        let hidden = try file("Report.txt", hideExtension: true)
        _ = try file("Report")
        _ = try file("Other.md")
        let index = FinderDisplayNameIndex.scan(directory: directory)

        XCTAssertTrue(index.isComplete)
        XCTAssertEqual(index.uniqueURL(matchingAny: ["Report.txt", "Report.txt"])?.standardizedFileURL,
                       hidden.standardizedFileURL, "Repeated attributes identifying one URL remain safe.")
        XCTAssertNil(index.uniqueURL(matchingAny: ["Report.txt", "Other.md"]),
                     "Conflicting attributes cannot prefer whichever filename appears first.")
        XCTAssertNil(index.uniqueURL(matchingAny: ["Report.txt", "Report"]),
                     "An exact attribute cannot override another ambiguous display label.")
    }

    private func file(_ name: String, hideExtension: Bool = false) throws -> URL {
        var url = directory.appendingPathComponent(name)
        try Data("Real Finder name-resolution fixture.\n".utf8).write(to: url)
        if hideExtension {
            var values = URLResourceValues()
            values.hasHiddenExtension = true
            try url.setResourceValues(values)
            XCTAssertEqual(try url.resourceValues(forKeys: [.hasHiddenExtensionKey]).hasHiddenExtension, true,
                           "The fixture must have the real macOS hidden-extension flag.")
        }
        return url
    }
}
