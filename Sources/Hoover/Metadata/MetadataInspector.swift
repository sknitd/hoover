import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

enum MetadataInspector {
    static let textLimit = 262_144
    static let contentLimit: Int64 = 128 * 1_024 * 1_024
    static let noteAttribute = "org.hoover.note"

    struct Basic: Sendable {
        var metadata: FileMetadata
        var canReadContent: Bool
        var isDirectory: Bool
        var size: Int64
    }

    static func basic(url: URL) -> Basic {
        let keys: Set<URLResourceKey> = [.nameKey, .localizedTypeDescriptionKey, .fileSizeKey,
            .creationDateKey, .contentModificationDateKey, .tagNamesKey, .isDirectoryKey,
            .isSymbolicLinkKey, .isRegularFileKey, .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey]
        let values = try? url.resourceValues(forKeys: keys)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let directory = values?.isDirectory ?? false
        let symlink = values?.isSymbolicLink ?? false
        let size = Int64(values?.fileSize ?? (attributes?[.size] as? NSNumber)?.intValue ?? 0)
        let title = values?.name ?? url.lastPathComponent
        let kind = values?.localizedTypeDescription ?? UTType(filenameExtension: url.pathExtension)?.localizedDescription ?? (directory ? "Folder" : "File")
        var fields = [field("Size", bytes(size)), field("Type", kind)]
        if !url.pathExtension.isEmpty { fields.append(field("Extension", url.pathExtension)) }
        if let date = values?.creationDate { fields.append(field("Created", date.formatted(date: .abbreviated, time: .shortened))) }
        if let date = values?.contentModificationDate { fields.append(field("Modified", date.formatted(date: .abbreviated, time: .shortened))) }
        if let tags = values?.tagNames, !tags.isEmpty { fields.append(field("Finder tags", tags.joined(separator: ", "))) }
        fields.append(field("Path", url.path))
        if symlink, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            fields.append(field("Symlink target", target))
        }
        let placeholder = url.pathExtension.lowercased() == "icloud" ||
            (values?.isUbiquitousItem == true && values?.ubiquitousItemDownloadingStatus == .notDownloaded)
        if values?.isUbiquitousItem == true {
            let state: String
            if placeholder { state = "In iCloud · not downloaded" }
            else if values?.ubiquitousItemIsDownloading == true { state = "Downloading" }
            else { state = "Available locally" }
            fields.append(field("iCloud", state))
        }
        var sections = [MetadataSection(title: "File", fields: fields)]
        if values == nil { sections.append(section("Access", [("Status", "Metadata is unavailable. Check file access permissions.")])) }
        if placeholder { sections.append(section("Preview", [("Status", "Hover previews do not download iCloud files.")])) }
        // Extended attributes are metadata reads. XATTR_NOFOLLOW avoids resolving links.
        var provenance = [MetadataField]()
        if let quarantine = xattr(url, "com.apple.quarantine"), let text = String(data: quarantine, encoding: .utf8) {
            let components = text.split(separator: ";", omittingEmptySubsequences: false)
            provenance.append(field("Quarantine", "Present"))
            if components.count > 2 { provenance.append(field("Downloaded by", String(components[2]))) }
        }
        if let origins = xattr(url, "com.apple.metadata:kMDItemWhereFroms"),
           let urls = try? PropertyListSerialization.propertyList(from: origins, format: nil) as? [String] {
            provenance.append(field("Download source", urls.map(redactCredentials).joined(separator: "\n")))
        }
        if !provenance.isEmpty { sections.append(MetadataSection(title: "Origin", fields: provenance)) }
        if let note = note(url: url), !note.isEmpty { sections.append(section("Notes", [("Personal note", note)])) }
        return Basic(metadata: FileMetadata(url: url, title: title, kind: kind, sections: sections),
                     canReadContent: !placeholder && !symlink && (directory || values?.isRegularFile == true),
                     isDirectory: directory, size: size)
    }

    static func inspect(url: URL) async -> FileMetadata {
        let info = basic(url: url)
        var result = info.metadata
        guard info.canReadContent, !Task.isCancelled else { return result }
        if info.size > contentLimit && !info.isDirectory {
            result.sections.append(section("Inspection", [("Status", "Deep inspection is limited to files under 128 MB. Basic metadata remains available.")]))
            return result
        }
        if info.isDirectory {
            result.sections += SystemMetadata.bundleAndProject(url)
            if !Task.isCancelled { result.sections += SystemMetadata.git(url) }
            return result
        }
        let ext = url.pathExtension.lowercased()
        if !Task.isCancelled { result.sections += MediaMetadata.image(url) }
        if !Task.isCancelled { result.sections += MediaMetadata.pdf(url) }
        if !Task.isCancelled { result.sections += await MediaMetadata.audioVideo(url) }
        if !Task.isCancelled { result.sections += MediaMetadata.design(url) }
        if !Task.isCancelled {
            let text = TextMetadata.inspect(url, size: info.size)
            result.sections += text.sections
            result.textPreview = text.preview
        }
        if !Task.isCancelled { result.sections += ArchiveMetadata.inspect(url, size: info.size) }
        if !Task.isCancelled { result.sections += SystemMetadata.binary(url) }
        if ["sqlite", "sqlite3", "db", "db3"].contains(ext), !Task.isCancelled {
            result.sections += SystemMetadata.sqlite(url)
        }
        if TextMetadata.language(for: url) != nil, !Task.isCancelled { result.sections += SystemMetadata.git(url) }
        return result
    }

    static func field(_ label: String, _ value: String) -> MetadataField { MetadataField(label: label, value: value) }
    static func section(_ title: String, _ fields: [(String, String)]) -> MetadataSection {
        MetadataSection(title: title, fields: fields.filter { !$0.1.isEmpty }.map { field($0.0, $0.1) })
    }
    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: max(0, count), countStyle: .file) }

    static func boundedData(_ url: URL, limit: Int = textLimit) -> Data? {
        guard !Task.isCancelled,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                  .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              !(values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus == .notDownloaded) else { return nil }
        // Nonblocking + no-follow protects against FIFOs and a symlink swap after the resource read.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { close(descriptor); return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        return try? handle.read(upToCount: limit)
    }

    static func xattr(_ url: URL, _ name: String) -> Data? {
        let count = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard count > 0, count <= 65_536 else { return nil }
        var data = Data(count: count)
        let actual = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, count, 0, XATTR_NOFOLLOW) }
        guard actual >= 0 else { return nil }
        return data.prefix(actual)
    }

    static func note(url: URL) -> String? {
        guard let data = xattr(url, noteAttribute) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveNote(_ text: String, url: URL) throws {
        let data = Data(text.utf8)
        guard data.count <= 8_192 else { throw NSError(domain: "Hoover.Notes", code: 1, userInfo: [NSLocalizedDescriptionKey: "Keep notes under 8 KB."]) }
        let status: Int32
        if data.isEmpty {
            status = removexattr(url.path, noteAttribute, XATTR_NOFOLLOW)
            if status != 0 && errno == ENOATTR { return }
        } else {
            status = data.withUnsafeBytes { setxattr(url.path, noteAttribute, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        }
        if status != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "The note could not be saved. This volume may not support extended attributes or file access is denied."]) }
    }

    static func redactCredentials(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value }
        components.user = nil
        components.password = nil
        return components.string ?? value
    }
}
