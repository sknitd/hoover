import Foundation
import XCTest
@testable import HooverCore

final class AdvancedSearchTests: XCTestCase {
    private let rootPath = "/tmp/advanced-root"

    private func record(_ path: String, folder: Bool = false, size: Int64? = nil,
                        modified: Date? = nil, symlink: Bool = false) -> IndexRecord {
        let url = URL(fileURLWithPath: rootPath + (path.isEmpty ? "" : "/" + path))
        return IndexRecord(node: FileNode(url: url, isDirectory: folder, isSymbolicLink: symlink,
                                          size: size, modified: modified),
                           parentID: path.isEmpty ? nil : url.deletingLastPathComponent().path,
                           depth: path.isEmpty ? 0 : path.split(separator: "/").count,
                           relativePath: path)
    }

    private func date(_ source: String) -> Date {
        ISO8601DateFormatter().date(from: source)!
    }

    func testCompoundQuotedPhraseAndExclusionPreserveCompleteAncestry() throws {
        let root = record("", folder: true), reports = record("Reports", folder: true)
        let matching = record("Reports/Annual Report Final.pdf")
        let draft = record("Reports/Annual Report Draft.pdf")
        let other = record("Reports/Annual Summary.pdf")
        let result = try AdvancedSearch.search(query: "\"annual report\" final -draft ext:pdf",
                                              records: [root, reports, matching, draft, other])
        XCTAssertEqual(result.matches.map(\.record.node.id), [matching.node.id])
        XCTAssertEqual(result.visibleIDs, [root.node.id, reports.node.id, matching.node.id])
        XCTAssertEqual(result.matches.first?.rank, 3)
    }

    func testTokenizationHandlesEscapedQuotesWhitespaceAndLiteralColonMinus() throws {
        let parsed = try AdvancedSearch.parse(query: #""say \"hello\"" annual\ report -"draft copy" "kind:image" \-literal"#)
        XCTAssertEqual(parsed.textTerms, ["say \"hello\"", "annual report", "kind:image", "-literal"])
        XCTAssertEqual(parsed.excludedTerms, ["draft copy"])
        XCTAssertTrue(parsed.clauses.isEmpty)
        let path = try AdvancedSearch.parse(query: #"path:"Source Files/Core" -kind:archive"#)
        XCTAssertEqual(path.clauses.count, 2)
        XCTAssertEqual(path.clauses[0].filter, .path("source files/core"))
        XCTAssertTrue(path.clauses[1].isExcluded)
        XCTAssertEqual(try AdvancedSearch.parse(query: "D'Angelo 'annual report' path:'Source Files'").textTerms,
                       ["D'Angelo", "annual report"])
    }

    func testAllFiltersAndExclusionsCombineWithANDWithoutChangingSymlinkIdentityOrDepth() throws {
        let records = [record("", folder: true), record("Sources", folder: true),
                       record("Sources/Core", folder: true),
                       record("Sources/Core/Controller.swift", size: 12_000_000, modified: date("2026-10-04T10:00:00Z"), symlink: true),
                       record("Sources/Core/Small.swift", size: 5, modified: date("2026-10-04T10:00:00Z")),
                       record("Sources/Other.swift", size: 20_000_000, modified: date("2026-10-04T10:00:00Z")),
                       record("Sources/Core/Old.swift", size: 20_000_000, modified: date("2025-01-01T10:00:00Z"))]
        let result = try AdvancedSearch.search(query: "kind:code ext:swift,pdf size:>10MB modified:>=2026-10-01 path:Sources/Core -old", records: records)
        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.matches[0].record, records[3])
        XCTAssertTrue(result.matches[0].record.node.isSymbolicLink)
        XCTAssertEqual(result.matches[0].record.depth, 3)
        XCTAssertEqual(result.visibleIDs, Set(records.prefix(4).map(\.node.id)))
        let unicode = [record("", folder: true), record("Café Files", folder: true), record("Café Files/code.swift")]
        XCTAssertEqual(try AdvancedSearch.search(query: "path:\"cafe files\"", records: unicode).matches.count, 2)
    }

    func testKindsAlternativesFileUmbrellaExtensionsAndCompoundArchiveExtension() throws {
        let records = [record("", folder: true), record("folder", folder: true), record("photo.CR3"),
                       record("clip.mov"), record("sound.flac"), record("readme.md"), record("source.swift"),
                       record("backup.tar.gz"), record("binary")]
        XCTAssertEqual(try AdvancedSearch.search(query: "kind:file", records: records).matches.count, 7)
        XCTAssertEqual(try AdvancedSearch.search(query: "kind:folder", records: records).matches.map(\.record.node.name), ["folder"])
        XCTAssertEqual(try AdvancedSearch.search(query: "kind:image,video", records: records).matches.count, 2)
        XCTAssertEqual(try AdvancedSearch.search(query: "kind:audio", records: records).matches.count, 1)
        XCTAssertEqual(try AdvancedSearch.search(query: "kind:document", records: records).matches.count, 1)
        XCTAssertEqual(try AdvancedSearch.search(query: "kind:code", records: records).matches.count, 1)
        XCTAssertEqual(try AdvancedSearch.search(query: "kind:archive ext:.tar.gz", records: records).matches.map(\.record.node.name), ["backup.tar.gz"])
        XCTAssertEqual(try AdvancedSearch.search(query: "-kind:file", records: records).matches.map(\.record.node.name), ["folder"])
    }

    func testSIAndBinarySizesInclusiveRangesAndUnknownMetadata() throws {
        let records = [record("", folder: true), record("folder", folder: true, size: 8_000_000),
                       record("decimal.bin", size: 1_000_000), record("binary.bin", size: 1_048_576),
                       record("unknown.bin"), record("bad.bin", size: -1)]
        XCTAssertEqual(try AdvancedSearch.search(query: "size:1MB", records: records).matches.map(\.record.node.name), ["decimal.bin"])
        XCTAssertEqual(try AdvancedSearch.search(query: "size:>=1MiB", records: records).matches.map(\.record.node.name), ["binary.bin"])
        XCTAssertEqual(try AdvancedSearch.search(query: "size:1MB..1MiB", records: records).matches.count, 2)
        XCTAssertEqual(try AdvancedSearch.search(query: "size:<1MiB", records: records).matches.map(\.record.node.name), ["decimal.bin"])
        XCTAssertEqual(try AdvancedSearch.search(query: "size:>1MiB", records: records).matches.count, 0)
        XCTAssertEqual(try AdvancedSearch.search(query: "size:<=1MB", records: records).matches.count, 1)
        XCTAssertNoThrow(try AdvancedSearch.parse(query: "size:9223372036854775807B"))
        XCTAssertNoThrow(try AdvancedSearch.parse(query: "size:1.5KB"))
    }

    func testDateFiltersIncludeFullUTCDaysAndValidateCalendarDates() throws {
        let now = date("2026-10-04T12:00:00Z")
        let records = [record("", folder: true), record("before.txt", modified: date("2026-10-02T23:59:59Z")),
                       record("start.txt", modified: date("2026-10-03T00:00:00Z")),
                       record("end.txt", modified: date("2026-10-03T23:59:59Z")),
                       record("after.txt", modified: date("2026-10-04T00:00:00Z")), record("unknown.txt")]
        XCTAssertEqual(try AdvancedSearch.search(query: "modified:2026-10-03", records: records, now: now).matches.count, 2)
        XCTAssertEqual(try AdvancedSearch.search(query: "before:2026-10-03", records: records, now: now).matches.map(\.record.node.name), ["before.txt"])
        XCTAssertEqual(try AdvancedSearch.search(query: "after:2026-10-03", records: records, now: now).matches.map(\.record.node.name), ["after.txt"])
        XCTAssertEqual(try AdvancedSearch.search(query: "modified:<=2026-10-03", records: records, now: now).matches.count, 3)
        XCTAssertEqual(try AdvancedSearch.search(query: "modified:>=2026-10-03", records: records, now: now).matches.count, 3)
        XCTAssertEqual(try AdvancedSearch.search(query: "modified:2026-10-02..2026-10-03", records: records, now: now).matches.count, 3)
        XCTAssertEqual(try AdvancedSearch.search(query: "modified:yesterday", records: records, now: now).matches.count, 2)
        XCTAssertEqual(try AdvancedSearch.search(query: "modified:today", records: records, now: now).matches.count, 1)
        XCTAssertEqual(try AdvancedSearch.search(query: "modified:7d", records: records, now: now).matches.count, 4)
        XCTAssertNoThrow(try AdvancedSearch.parse(query: "modified:2024-02-29"))
        XCTAssertTrue(try AdvancedSearch.search(query: "modified:today", records: [record("invalid.txt", modified: Date(timeIntervalSinceReferenceDate: .nan))], now: now).matches.isEmpty)
    }

    func testInvalidSyntaxProvidesExplanatoryErrorsInsteadOfIgnoringFilters() {
        for query in ["\"open quote", "trailing\\", "-", "kind:", "kind:unknown", "ext:pdf,,swift", "depth:3",
                      "size:-1MB", "size:1.5B", "size:10watts", "size:9223372036854775808B", "size:10MB..1MB",
                      "size:1MB...2MB", "modified:2026-02-29", "modified:2026-02-30", "modified:2026-13-01",
                      "modified:2026-1-01", "modified:2026-10-04..2026-10-01", "path:"] {
            XCTAssertThrowsError(try AdvancedSearch.parse(query: query), query) { error in
                XCTAssertFalse(error.localizedDescription.isEmpty)
                XCTAssertTrue(error is AdvancedSearchError)
            }
        }
    }

    func testEmptyRootNameAndSingleTermRemainCompatibleWithOriginalRanking() throws {
        let records = [record("", folder: true), record("Controller.swift"), record("ControllerTests.swift")]
        XCTAssertEqual(try AdvancedSearch.search(query: "Controller", records: records).matches,
                       TreeSearch.search(query: "Controller", records: records).matches)
        XCTAssertEqual(try AdvancedSearch.search(query: "", records: records).visibleIDs, Set(records.map(\.node.id)))
        XCTAssertTrue(try AdvancedSearch.search(query: "advanced-root", records: records).matches.isEmpty)
        XCTAssertTrue(try AdvancedSearch.search(query: "kind:file path:../outside", records: records).matches.isEmpty)
    }

    func testCancelledSearchThrowsRatherThanPublishingPartialResults() async {
        let task = Task<Bool, Never> {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try AdvancedSearch.search(query: "kind:file", records: [])
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
    }
}
