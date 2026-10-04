import Foundation

public enum FileKind: String, CaseIterable, Codable, Sendable {
    case file, folder, image, video, audio, document, code, archive

    public var title: String { rawValue.capitalized }

    /// An extension-based local classification, not a claim about file contents.
    public static func classify(_ node: FileNode) -> FileKind {
        classify(normalizedExtension: node.url.pathExtension.lowercased(), isDirectory: node.isDirectory)
    }

    static func classify(normalizedExtension ext: String, isDirectory: Bool) -> FileKind {
        if isDirectory { return .folder }
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if documentExtensions.contains(ext) { return .document }
        if codeExtensions.contains(ext) { return .code }
        if archiveExtensions.contains(ext) { return .archive }
        return .file
    }

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "webp", "avif", "bmp", "svg", "ico", "icns", "cr2", "cr3", "nef", "arw", "rw2", "dng", "raw", "exr", "hdr"]
    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "mkv", "webm", "avi", "mpg", "mpeg", "mts", "m2ts", "flv", "wmv"]
    private static let audioExtensions: Set<String> = ["mp3", "aac", "m4a", "wav", "flac", "aiff", "aif", "alac", "ogg", "opus", "caf", "wma", "mid", "midi"]
    private static let documentExtensions: Set<String> = ["pdf", "txt", "rtf", "rtfd", "md", "markdown", "doc", "docx", "odt", "pages", "xls", "xlsx", "csv", "ods", "numbers", "ppt", "pptx", "key", "epub"]
    private static let codeExtensions: Set<String> = ["swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cxx", "rs", "go", "py", "rb", "js", "jsx", "ts", "tsx", "java", "kt", "kts", "cs", "fs", "php", "html", "htm", "css", "scss", "sass", "less", "sh", "bash", "zsh", "fish", "sql", "json", "yaml", "yml", "toml", "xml", "plist", "r", "lua", "dart", "vue", "svelte"]
    private static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "lz", "lzma", "iso", "dmg", "cab", "jar", "war"]
}

public enum NodeSortOrder: String, CaseIterable, Codable, Sendable {
    case name, modified, size, kind

    public var title: String {
        switch self {
        case .name: return "Name"
        case .modified: return "Date modified"
        case .size: return "Size"
        case .kind: return "Kind"
        }
    }
}

public enum TreeOrdering {
    /// Unknown dates/sizes stay last in either direction. Folders stay first
    /// when requested; equal keys preserve the original sequence.
    public static func sorted(_ nodes: [FileNode], by order: NodeSortOrder = .name,
                              ascending: Bool = true, foldersFirst: Bool = true) -> [FileNode] {
        offsets(nodes: nodes, names: nodes.map { TreeSearch.normalize($0.name) }, extensions: nil,
                order: order, ascending: ascending, foldersFirst: foldersFirst).map { nodes[$0] }
    }

    /// Existing index keys avoid repeating normalization for broad searches.
    public static func sorted(_ records: [IndexRecord], by order: NodeSortOrder = .name,
                              ascending: Bool = true, foldersFirst: Bool = true) -> [IndexRecord] {
        offsets(nodes: records.map(\.node), names: records.map(\.normalizedName),
                extensions: records.map(\.normalizedExtension), order: order,
                ascending: ascending, foldersFirst: foldersFirst).map { records[$0] }
    }

    private static func offsets(nodes: [FileNode], names: [String], extensions: [String]?,
                                order: NodeSortOrder, ascending: Bool, foldersFirst: Bool) -> [Int] {
        let keys = names.map { Array($0.utf8) }
        let kinds = order == .kind ? nodes.indices.map { index in
            extensions.map { FileKind.classify(normalizedExtension: $0[index], isDirectory: nodes[index].isDirectory) }
                ?? FileKind.classify(nodes[index])
        } : []
        return nodes.indices.sorted { left, right in
            let lhs = nodes[left], rhs = nodes[right]
            if foldersFirst, lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            var comparison = 0
            switch order {
            case .name:
                comparison = naturalCompare(keys[left], keys[right])
            case .kind:
                let a = kinds[left].rawValue, b = kinds[right].rawValue
                comparison = a == b ? 0 : (a < b ? -1 : 1)
            case .modified:
                let a = lhs.modified.flatMap { $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil }
                let b = rhs.modified.flatMap { $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil }
                if (a == nil) != (b == nil) { return a != nil }
                if let a, let b {
                    comparison = a == b ? 0 : (a < b ? -1 : 1)
                }
            case .size:
                let a = lhs.size.flatMap { $0 >= 0 ? $0 : nil }
                let b = rhs.size.flatMap { $0 >= 0 ? $0 : nil }
                if (a == nil) != (b == nil) { return a != nil }
                if let a, let b {
                    comparison = a == b ? 0 : (a < b ? -1 : 1)
                }
            }
            if comparison == 0, order != .name {
                comparison = naturalCompare(keys[left], keys[right])
            }
            if comparison == 0 { return left < right }
            return ascending ? comparison < 0 : comparison > 0
        }
    }

    /// Numeric runs are compared by significant length and then digits rather
    /// than converted to Int, so arbitrarily long filenames cannot overflow.
    private static func naturalCompare(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        var a = 0, b = 0
        while a < lhs.count, b < rhs.count {
            if (48...57).contains(lhs[a]), (48...57).contains(rhs[b]) {
                var aEnd = a, bEnd = b
                while aEnd < lhs.count, (48...57).contains(lhs[aEnd]) { aEnd += 1 }
                while bEnd < rhs.count, (48...57).contains(rhs[bEnd]) { bEnd += 1 }
                var aSignificant = a, bSignificant = b
                while aSignificant < aEnd, lhs[aSignificant] == 48 { aSignificant += 1 }
                while bSignificant < bEnd, rhs[bSignificant] == 48 { bSignificant += 1 }
                let aLength = aEnd - aSignificant, bLength = bEnd - bSignificant
                if aLength != bLength { return aLength < bLength ? -1 : 1 }
                while aSignificant < aEnd {
                    if lhs[aSignificant] != rhs[bSignificant] { return lhs[aSignificant] < rhs[bSignificant] ? -1 : 1 }
                    aSignificant += 1; bSignificant += 1
                }
                a = aEnd; b = bEnd
            } else {
                if lhs[a] != rhs[b] { return lhs[a] < rhs[b] ? -1 : 1 }
                a += 1; b += 1
            }
        }
        return a == lhs.count ? (b == rhs.count ? 0 : -1) : 1
    }
}

public struct DuplicateNameGroup: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let nodes: [FileNode]
    public var count: Int { nodes.count }

    public init(id: String, name: String, nodes: [FileNode]) {
        self.id = id
        self.name = name
        self.nodes = nodes
    }
}

public struct TreeInsightSummary: Sendable, Equatable {
    public let itemCount: Int
    public let fileCount: Int
    public let folderCount: Int
    public let symlinkCount: Int
    public let totalBytes: Int64
    public let totalBytesOverflowed: Bool
    public let unknownSizeFileCount: Int
    public let extensionCounts: [String: Int]
    public let kindCounts: [FileKind: Int]
    public let largestFiles: [FileNode]
    public let recentlyModifiedFiles: [FileNode]
    public let duplicateNameGroups: [DuplicateNameGroup]
}

public enum TreeInsights {
    /// Summarizes only the supplied indexed descendants. No filesystem is read,
    /// symlinks are not followed, and the immutable root is not counted.
    public static func analyze(_ records: [IndexRecord], limit: Int = 10) -> TreeInsightSummary {
        var positionByID: [String: Int] = [:]
        var uniqueRecords: [IndexRecord] = []
        for record in records where record.depth > 0 {
            if let position = positionByID[record.node.id] {
                uniqueRecords[position] = record
            } else {
                positionByID[record.node.id] = uniqueRecords.count
                uniqueRecords.append(record)
            }
        }
        var fileCount = 0, folderCount = 0, symlinkCount = 0, unknownSizeCount = 0
        var totalBytes: Int64 = 0
        var overflowed = false
        var extensionCounts: [String: Int] = [:]
        var kindCounts: [FileKind: Int] = [:]
        var nameGroups: [String: [FileNode]] = [:]
        for record in uniqueRecords {
            let node = record.node
            if node.isDirectory { folderCount += 1 } else { fileCount += 1 }
            if node.isSymbolicLink { symlinkCount += 1 }
            kindCounts[FileKind.classify(normalizedExtension: record.normalizedExtension, isDirectory: node.isDirectory), default: 0] += 1
            let nameKey = node.name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .precomposedStringWithCanonicalMapping
            nameGroups[nameKey, default: []].append(node)
            guard !node.isDirectory else { continue }
            extensionCounts[record.normalizedExtension, default: 0] += 1
            if let size = node.size, size >= 0 {
                let sum = totalBytes.addingReportingOverflow(size)
                if sum.overflow { totalBytes = .max; overflowed = true }
                else { totalBytes = sum.partialValue }
            } else { unknownSizeCount += 1 }
        }
        let count = max(0, limit)
        let files = uniqueRecords.filter { !$0.node.isDirectory }
        let largest = TreeOrdering.sorted(files.filter { ($0.node.size ?? -1) >= 0 }, by: .size,
                                          ascending: false, foldersFirst: false)
        let recent = TreeOrdering.sorted(files.filter { $0.node.modified?.timeIntervalSinceReferenceDate.isFinite == true }, by: .modified,
                                         ascending: false, foldersFirst: false)
        let duplicates = nameGroups.filter { $0.value.count > 1 }.map { key, entries in
            let sorted = TreeOrdering.sorted(entries, foldersFirst: false)
            return DuplicateNameGroup(id: key, name: sorted[0].name, nodes: sorted)
        }.sorted { $0.id < $1.id }
        return TreeInsightSummary(itemCount: uniqueRecords.count, fileCount: fileCount, folderCount: folderCount,
                                  symlinkCount: symlinkCount, totalBytes: totalBytes,
                                  totalBytesOverflowed: overflowed, unknownSizeFileCount: unknownSizeCount,
                                  extensionCounts: extensionCounts, kindCounts: kindCounts,
                                  largestFiles: largest.prefix(count).map(\.node),
                                  recentlyModifiedFiles: recent.prefix(count).map(\.node),
                                  duplicateNameGroups: duplicates)
    }
}
