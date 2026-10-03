import Foundation

enum ArchiveMetadata {
    static func inspect(_ url: URL, size: Int64) -> [MetadataSection] {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        if ["zip", "jar", "epub", "docx", "xlsx", "pptx"].contains(ext) { return zip(url, size: size) }
        if ext == "rar" || ext == "7z" {
            return [MetadataInspector.section("Archive", [("Format", ext.uppercased()),
                ("Contents", "No native read-only \(ext.uppercased()) parser is installed. Archive contents are not extracted.")])]
        }
        if ext == "tar" || ["tgz", "tbz", "tbz2", "txz"].contains(ext) || name.hasSuffix(".tar.gz") || name.hasSuffix(".tar.bz2") || name.hasSuffix(".tar.xz") {
            guard let listing = InspectionProcess.run("/usr/bin/tar", ["-tf", url.path], timeout: 2) else { return [] }
            guard listing.status == 0 || listing.limited else { return [MetadataInspector.section("Archive", [("Status", "Could not read this archive without extracting it.")])] }
            let names = listing.stdout.components(separatedBy: .newlines).filter { !$0.isEmpty }
            return [MetadataInspector.section("Archive", [("Format", "TAR"), ("Compressed size", MetadataInspector.bytes(size)),
                (listing.limited ? "Entries inspected" : "Listed entries", String(names.count)),
                ("Directories inspected", String(names.filter { $0.hasSuffix("/") }.count)),
                ("Files inspected", String(names.filter { !$0.hasSuffix("/") }.count)),
                ("Contained names", names.prefix(16).joined(separator: "\n")),
                ("Inspection", listing.limited ? "Partial; time or output limit reached." : "Read-only listing; no files extracted."),
                ("Uncompressed size", "Not calculated during bounded hover inspection.")])]
        }
        if ["dmg", "iso", "img", "sparseimage", "sparsebundle"].contains(ext) {
            guard let output = InspectionProcess.run("/usr/bin/hdiutil", ["imageinfo", "-plist", url.path], timeout: 2), output.status == 0, !output.limited,
                  let plist = try? PropertyListSerialization.propertyList(from: Data(output.stdout.utf8), format: nil) as? [String: Any] else {
                return [MetadataInspector.section("Disk image", [("Format", ext.uppercased()), ("Contents", "Not mounted or extracted. Native image information is unavailable.")])]
            }
            var fields = [("Contents", "Image inspected without mounting. Contained file names are unavailable.")]
            if let format = plist["Format Description"] as? String { fields.append(("Format", format)) }
            if let format = plist["Format"] as? String { fields.append(("Image format", format)) }
            if let properties = plist["Properties"] as? [String: Any], let encrypted = properties["Encrypted"] as? Bool { fields.append(("Encrypted", encrypted ? "Yes" : "No")) }
            if let total = plist["Total Bytes"] as? NSNumber { fields.append(("Logical size", MetadataInspector.bytes(total.int64Value))) }
            return [MetadataInspector.section("Disk image", fields)]
        }
        if ["gz", "bz2", "xz"].contains(ext) {
            return [MetadataInspector.section("Archive", [("Format", ext.uppercased()), ("Contents", "A single compressed stream; contents are not decompressed during hover.")])]
        }
        return []
    }

    /// Read ZIP's central directory directly; never decompress or interpret entry paths.
    private static func zip(_ url: URL, size: Int64) -> [MetadataSection] {
        let title = "Archive"
        guard size >= 22, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        do {
            let tailSize = min(UInt64(size), 65_557)
            try handle.seek(toOffset: UInt64(size) - tailSize)
            guard let tail = try handle.read(upToCount: Int(tailSize)) else { return [] }
            var end: Int?
            if tail.count >= 22 {
                for position in stride(from: tail.count - 22, through: 0, by: -1) {
                    if u32(tail, position) == 0x06054b50, position + 22 + Int(u16(tail, position + 20)) == tail.count { end = position; break }
                }
            }
            guard let end else { return [MetadataInspector.section(title, [("Status", "ZIP central directory is invalid or unavailable.")])] }
            let count = Int(u16(tail, end + 10))
            let directorySize = Int(u32(tail, end + 12)), directoryOffset = UInt64(u32(tail, end + 16))
            guard u16(tail, end + 4) == 0, u16(tail, end + 6) == 0,
                  count != 0xffff, directorySize != Int(UInt32.max), directoryOffset != UInt64(UInt32.max) else {
                return zipFallback(url, size: size, reason: "ZIP64 or split ZIP; totals are unavailable in bounded native inspection.")
            }
            guard directoryOffset + UInt64(directorySize) <= UInt64(size), directorySize <= 1_048_576 else {
                return zipFallback(url, size: size, reason: "Central directory exceeds the 1 MB inspection limit or is invalid.")
            }
            try handle.seek(toOffset: directoryOffset)
            guard let data = try handle.read(upToCount: directorySize), data.count == directorySize else { return [] }
            var offset = 0, files = 0, directories = 0
            var compressed: UInt64 = 0, uncompressed: UInt64 = 0
            var encrypted = false, names = [String]()
            for _ in 0..<count {
                guard !Task.isCancelled, offset + 46 <= data.count, u32(data, offset) == 0x02014b50 else { return zipFallback(url, size: size, reason: "Central directory could not be fully inspected.") }
                let filenameSize = Int(u16(data, offset + 28)), extra = Int(u16(data, offset + 30)), comment = Int(u16(data, offset + 32))
                let next = offset + 46 + filenameSize + extra + comment
                guard next <= data.count else { return [] }
                let nameData = data[(offset + 46)..<(offset + 46 + filenameSize)]
                let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? "Undecodable filename"
                if name.hasSuffix("/") { directories += 1 } else { files += 1 }
                if names.count < 16 { names.append(name) }
                encrypted = encrypted || (u16(data, offset + 8) & 1) != 0
                let packed = u32(data, offset + 20), unpacked = u32(data, offset + 24)
                if packed == UInt32.max || unpacked == UInt32.max { return zipFallback(url, size: size, reason: "ZIP64 entries; totals are unavailable in bounded native inspection.") }
                compressed += UInt64(packed)
                uncompressed += UInt64(unpacked)
                offset = next
            }
            var fields = [("Format", "ZIP"), ("Files", String(files)), ("Directories", String(directories)),
                ("Compressed size", MetadataInspector.bytes(size)), ("Uncompressed size", MetadataInspector.bytes(Int64(uncompressed))),
                ("Encryption", encrypted ? "Encrypted entries present" : "Not encrypted"),
                ("Contained names", names.joined(separator: "\n")), ("Inspection", "Central directory only · no extraction")]
            if uncompressed > 0 { fields.append(("Compression saving", String(format: "%.1f%%", (1 - Double(compressed) / Double(uncompressed)) * 100))) }
            return [MetadataInspector.section(title, fields)]
        } catch { return [MetadataInspector.section(title, [("Status", "Archive metadata could not be read.")])] }
    }

    private static func zipFallback(_ url: URL, size: Int64, reason: String) -> [MetadataSection] {
        var fields = [("Format", "ZIP"), ("Compressed size", MetadataInspector.bytes(size)), ("Inspection", reason)]
        if !Task.isCancelled, let output = InspectionProcess.run("/usr/bin/unzip", ["-Z", "-1", url.path]), output.status == 0 || output.limited {
            let names = output.stdout.components(separatedBy: .newlines).filter { !$0.isEmpty }
            fields += [("Contained names", names.prefix(16).joined(separator: "\n")), ("Listed entries", "\(names.count)\(output.limited ? "+ (partial)" : "")"), ("Encryption", "Not determined")]
        }
        return [MetadataInspector.section("Archive", fields)]
    }
    private static func u16(_ data: Data, _ index: Int) -> UInt16 { UInt16(data[index]) | UInt16(data[index + 1]) << 8 }
    private static func u32(_ data: Data, _ index: Int) -> UInt32 { UInt32(u16(data, index)) | UInt32(u16(data, index + 2)) << 16 }
}
