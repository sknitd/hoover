import Foundation
import CoreGraphics
import ImageIO
import XCTest
@testable import Hoover

final class MetadataTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HooverMetadataTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func value(_ sections: [MetadataSection], _ label: String) -> String? {
        sections.flatMap(\.fields).first { $0.label == label }?.value
    }

    func testMarkdownMetadataAndPreviewComeFromRealFile() throws {
        let source = "---\nauthor: Ada\n---\n# Hoover\n## Depth\n[Docs](https://example.org)\n![Folder](folder.png)\n```swift\nlet depth = 3\n```\n"
        let url = try file("Guide.md", source)
        let result = TextMetadata.inspect(url, size: Int64(source.utf8.count))
        XCTAssertEqual(value(result.sections, "Title"), "Hoover")
        XCTAssertEqual(value(result.sections, "Headings"), "2")
        XCTAssertEqual(value(result.sections, "Links"), "1")
        XCTAssertEqual(value(result.sections, "Images"), "1")
        XCTAssertEqual(value(result.sections, "Fenced code blocks"), "1")
        XCTAssertEqual(value(result.sections, "Frontmatter"), "author: Ada")
        XCTAssertTrue(result.preview?.contains("let depth = 3") == true)
    }

    func testInvalidJSONIsReportedWithoutInventingKeys() throws {
        let source = "{\"secret\": false,}"
        let result = TextMetadata.inspect(try file("broken.json", source), size: Int64(source.utf8.count))
        XCTAssertEqual(value(result.sections, "Validity"), "Invalid or unsupported encoding")
        XCTAssertNil(value(result.sections, "Key count"))
    }

    func testJSONRejectsNonstandardLiteralsNumbersAndTrailingContent() throws {
        let malformed = [#"{"number":NaN}"#, #"{"number":0x10}"#,
                         #"{"enabled":true} false"#, #"[1,2,]"#,
                         #"{"text":"\q"}"#, #"{"number":01}"#]
        for (index, source) in malformed.enumerated() {
            let result = TextMetadata.inspect(try file("invalid-\(index).json", source), size: Int64(source.utf8.count))
            XCTAssertEqual(value(result.sections, "Validity"), "Invalid or unsupported encoding", source)
            XCTAssertNil(value(result.sections, "Key count"), source)
        }
    }

    func testJSONAcceptsEscapesFractionsAndNestedStatistics() throws {
        let source = #"[{"title":"Hover \"deeper\" \u263A","value":-1.25e+2},null,true]"#
        let result = TextMetadata.inspect(try file("strict-valid.json", source), size: Int64(source.utf8.count))
        XCTAssertEqual(value(result.sections, "Validity"), "Valid")
        XCTAssertEqual(value(result.sections, "Key count"), "2")
        XCTAssertEqual(value(result.sections, "Nesting depth"), "2")
    }

    func testJSONOverInspectionDepthIsReportedAsUnvalidated() throws {
        let source = String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)
        let result = TextMetadata.inspect(try file("too-deep.json", source), size: Int64(source.utf8.count))
        XCTAssertTrue(value(result.sections, "Validity")?.contains("64-level inspection limit") == true)
        XCTAssertNil(value(result.sections, "Key count"))
        XCTAssertNil(value(result.sections, "Nesting depth"))
    }

    func testBinaryPlistIsValidatedWithoutPretendingItIsText() throws {
        let url = directory.appendingPathComponent("Preferences.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: ["active": true, "delay": 3], format: .binary, options: 0)
        try data.write(to: url)
        let result = TextMetadata.inspect(url, size: Int64(data.count))
        XCTAssertEqual(value(result.sections, "Validity"), "Valid")
        XCTAssertEqual(value(result.sections, "Key count"), "2")
        XCTAssertNil(result.preview)
    }

    func testXMLDTDAndExternalEntitiesAreNotEvaluated() throws {
        let source = "<!DOCTYPE root [<!ENTITY outside SYSTEM 'file:///etc/passwd'>]><root>&outside;</root>"
        let result = TextMetadata.inspect(try file("entities.xml", source), size: Int64(source.utf8.count))
        XCTAssertTrue(value(result.sections, "Validity")?.contains("DTD parsing is disabled") == true)
        XCTAssertNil(value(result.sections, "Elements"))
        // The bounded source snippet can show the declaration itself, never the
        // referenced external file's contents.
        XCTAssertFalse(result.preview?.contains("root:x:") == true)
    }

    func testBoundedPreviewMarksPartialStatistics() throws {
        let source = String(repeating: "let value = 1\n", count: 30_000)
        let result = TextMetadata.inspect(try file("Long.swift", source), size: Int64(source.utf8.count))
        XCTAssertNotNil(value(result.sections, "Inspection limit"))
        XCTAssertNotNil(value(result.sections, "Scanned lines"))
        XCTAssertNil(value(result.sections, "Lines"))
        XCTAssertLessThanOrEqual(result.preview?.utf8.count ?? .max, 8_192)
    }

    func testSymlinkContentIsNeverInspectedImplicitly() throws {
        let target = try file("outside.swift", "let privateValue = 42\n")
        let link = directory.appendingPathComponent("link.swift")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let info = MetadataInspector.basic(url: link)
        XCTAssertFalse(info.canReadContent)
        XCTAssertNotNil(value(info.metadata.sections, "Symlink target"))
    }

    func testNotesRoundTripAndRemovalUseFileExtendedAttribute() throws {
        let url = try file("notes.txt", "file content stays unchanged")
        let before = try Data(contentsOf: url)
        try MetadataInspector.saveNote("Check lens settings", url: url)
        XCTAssertEqual(MetadataInspector.note(url: url), "Check lens settings")
        XCTAssertEqual(try Data(contentsOf: url), before)
        try MetadataInspector.saveNote("", url: url)
        XCTAssertNil(MetadataInspector.note(url: url))
    }

    func testNotesRejectOversizedValueWithoutReplacingExistingNote() throws {
        let url = try file("safe.txt", "content")
        try MetadataInspector.saveNote("Preserved", url: url)
        XCTAssertThrowsError(try MetadataInspector.saveNote(String(repeating: "x", count: 8_193), url: url))
        XCTAssertEqual(MetadataInspector.note(url: url), "Preserved")
    }

    func testDownloadSourceRedactsCredentialUserInfo() {
        XCTAssertEqual(MetadataInspector.redactCredentials("https://user:pass@example.org/file.pdf"), "https://example.org/file.pdf")
    }

    func testMetadataFieldIdentitiesAreUniqueAndStableWhenLabelsRepeat() {
        let fields = [MetadataField(label: "Title", value: "English"),
                      MetadataField(label: "Title", value: "Français"),
                      MetadataField(id: "Title#1", label: "Artist", value: "Ada")]
        let first = MetadataSection(title: "Audio", fields: fields)
        let second = MetadataSection(title: "Audio", fields: fields)
        XCTAssertEqual(Set(first.fields.map(\.id)).count, fields.count)
        XCTAssertEqual(first.fields.map(\.id), second.fields.map(\.id))
        XCTAssertEqual(first.fields.map(\.value), ["English", "Français", "Ada"])
    }

    func testSubprocessArgumentsArePassedLiterally() throws {
        let text = "$(touch /tmp/hoover-should-not-exist); `id`; quote ' \" café"
        let result = try XCTUnwrap(InspectionProcess.run("/usr/bin/printf", ["%s", text]))
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, text)
        XCTAssertFalse(result.limited)
    }

    func testSubprocessOutputAndTimeAreBounded() throws {
        let result = try XCTUnwrap(InspectionProcess.run("/usr/bin/printf", ["%s", String(repeating: "a", count: 4_096)], limit: 32))
        XCTAssertEqual(result.stdout.count, 32)
        XCTAssertTrue(result.limited)
        let start = Date()
        let timed = try XCTUnwrap(InspectionProcess.run("/bin/sleep", ["5"], timeout: 0.05))
        XCTAssertTrue(timed.limited)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testZIPNamesCountsAndDeclaredEncryptionDoNotExtractPaths() throws {
        let url = directory.appendingPathComponent("payload.zip")
        let data = zipDirectory([
            ("Folder/", Data(), false),
            ("Folder/README.md", Data("hello".utf8), false),
            ("../outside.txt", Data("private".utf8), true)
        ])
        try data.write(to: url)
        let fields = ArchiveMetadata.inspect(url, size: Int64(data.count))
        XCTAssertEqual(value(fields, "Files"), "2")
        XCTAssertEqual(value(fields, "Directories"), "1")
        XCTAssertEqual(value(fields, "Encryption"), "Encrypted entries present")
        XCTAssertTrue(value(fields, "Contained names")?.contains("../outside.txt") == true)
        XCTAssertEqual(value(fields, "Inspection"), "Central directory only · no extraction")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Folder").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["payload.zip"])
    }

    func testMalformedZIPDirectoryReportsUnavailableWithoutCrashing() throws {
        let url = directory.appendingPathComponent("broken.zip")
        let data = Data(repeating: 0, count: 30)
        try data.write(to: url)
        let result = ArchiveMetadata.inspect(url, size: Int64(data.count))
        XCTAssertEqual(value(result, "Status"), "ZIP central directory is invalid or unavailable.")
    }

    func testPDFPageMetadataComesFromNativeDocument() throws {
        let url = directory.appendingPathComponent("document.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 320, height: 480)
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for _ in 0..<2 { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        let fields = MediaMetadata.pdf(url)
        XCTAssertEqual(value(fields, "Pages"), "2")
        XCTAssertEqual(value(fields, "First page"), "320 × 480 pt")
        XCTAssertEqual(value(fields, "Encryption"), "Not encrypted")
    }

    func testImageDimensionsDoNotInventCameraOrHDRFields() throws {
        let url = directory.appendingPathComponent("plain.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let fields = MediaMetadata.image(url)
        XCTAssertEqual(value(fields, "Dimensions"), "32 × 24 px")
        XCTAssertNil(value(fields, "Camera"))
        XCTAssertNil(value(fields, "HDR format"))
        XCTAssertNil(value(fields, "HDR transfer"))
    }

    /// Build a stored ZIP fixture directly. Inspection reads the directory only,
    /// including a declared encrypted entry; it must never interpret entry paths.
    private func zipDirectory(_ entries: [(String, Data, Bool)]) -> Data {
        var local = Data(), central = Data()
        func u16(_ number: UInt16) -> Data { Data([UInt8(number & 255), UInt8(number >> 8)]) }
        func u32(_ number: UInt32) -> Data { u16(UInt16(number & 65_535)) + u16(UInt16(number >> 16)) }
        func crc(_ content: Data) -> UInt32 {
            var value: UInt32 = .max
            for byte in content {
                value ^= UInt32(byte)
                for _ in 0..<8 { value = (value >> 1) ^ ((value & 1) == 1 ? 0xedb88320 : 0) }
            }
            return value ^ .max
        }
        for (name, content, encrypted) in entries {
            let filename = Data(name.utf8), position = UInt32(local.count), checksum = crc(content)
            let flags: UInt16 = encrypted ? 1 : 0
            let size = UInt32(content.count)
            local += u32(0x04034b50) + u16(20) + u16(flags) + u16(0) + u16(0) + u16(0)
            local += u32(checksum) + u32(size) + u32(size) + u16(UInt16(filename.count)) + u16(0)
            local += filename + content
            central += u32(0x02014b50) + u16(20) + u16(20) + u16(flags) + u16(0) + u16(0) + u16(0)
            central += u32(checksum) + u32(size) + u32(size) + u16(UInt16(filename.count))
            central += u16(0) + u16(0) + u16(0) + u16(0) + u32(0) + u32(position) + filename
        }
        let offset = UInt32(local.count), count = UInt16(entries.count)
        return local + central + u32(0x06054b50) + u16(0) + u16(0) + u16(count) + u16(count) + u32(UInt32(central.count)) + u32(offset) + u16(0)
    }
}
