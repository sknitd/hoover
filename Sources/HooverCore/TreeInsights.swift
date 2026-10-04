import Foundation

public enum FileKind: String, CaseIterable, Codable, Sendable {
    case file, folder, image, video, audio, document, code, archive

    public var title: String { rawValue.capitalized }

    /// An extension-based local classification, not a claim about file contents.
    public static func classify(_ node: FileNode) -> FileKind {
        if node.isDirectory { return .folder }
        let ext = node.url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if documentExtensions.contains(ext) { return .document }
        if codeExtensions.contains(ext) { return .code }
        if archiveExtensions.contains(ext) { return .archive }
        return .file
    }

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "webp", "avif", "bmp", "svg", "ico", "icns", "cr2", "cr3", "nef", "arw", "rw2", "dng", "raw", "exr", "hdr"]
    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "mkv", "webm", "avi", "mpg", "mpeg", "ts", "mts", "m2ts", "flv", "wmv"]
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
        nodes.enumerated().sorted { left, right in
            let lhs = left.element, rhs = right.element
            if foldersFirst, lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            var comparison = ComparisonResult.orderedSame
            switch order {
            case .name:
                comparison = naturalCompare(lhs.name, rhs.name)
            case .kind:
                comparison = naturalCompare(FileKind.classify(lhs).rawValue, FileKind.classify(rhs).rawValue)
            case .modified:
                if (lhs.modified == nil) != (rhs.modified == nil) { return lhs.modified != nil }
                if let a = lhs.modified, let b = rhs.modified {
                    comparison = a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
                }
            case .size:
                let a = lhs.size.flatMap { $0 >= 0 ? $0 : nil }
                let b = rhs.size.flatMap { $0 >= 0 ? $0 : nil }
                if (a == nil) != (b == nil) { return a != nil }
                if let a, let b {
                    comparison = a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
                }
            }
            if comparison == .orderedSame, order != .name {
                comparison = naturalCompare(lhs.name, rhs.name)
            }
            if comparison == .orderedSame { return left.offset < right.offset }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }.map(\.element)
    }

    private static func naturalCompare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: [.numeric, .caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX"))
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
        var nodes: [FileNode] = []
        for record in records where record.depth > 0 {
            if let position = positionByID[record.node.id] {
                nodes[position] = record.node
            } else {
                positionByID[record.node.id] = nodes.count
                nodes.append(record.node)
            }
        }
        var fileCount = 0, folderCount = 0, symlinkCount = 0, unknownSizeCount = 0
        var totalBytes: Int64 = 0
        var overflowed = false
        var extensionCounts: [String: Int] = [:]
        var kindCounts: [FileKind: Int] = [:]
        var nameGroups: [String: [FileNode]] = [:]
        for node in nodes {
            if node.isDirectory { folderCount += 1 } else { fileCount += 1 }
            if node.isSymbolicLink { symlinkCount += 1 }
            kindCounts[FileKind.classify(node), default: 0] += 1
            let nameKey = node.name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .precomposedStringWithCanonicalMapping
            nameGroups[nameKey, default: []].append(node)
            guard !node.isDirectory else { continue }
            extensionCounts[node.url.pathExtension.lowercased(), default: 0] += 1
            if let size = node.size, size >= 0 {
                let sum = totalBytes.addingReportingOverflow(size)
                if sum.overflow { totalBytes = .max; overflowed = true }
                else { totalBytes = sum.partialValue }
            } else { unknownSizeCount += 1 }
        }
        let count = max(0, limit)
        let files = nodes.filter { !$0.isDirectory }
        let largest = TreeOrdering.sorted(files.filter { ($0.size ?? -1) >= 0 }, by: .size,
                                          ascending: false, foldersFirst: false)
        let recent = TreeOrdering.sorted(files.filter { $0.modified != nil }, by: .modified,
                                         ascending: false, foldersFirst: false)
        let duplicates = nameGroups.filter { $0.value.count > 1 }.map { key, entries in
            let sorted = TreeOrdering.sorted(entries, foldersFirst: false)
            return DuplicateNameGroup(id: key, name: sorted[0].name, nodes: sorted)
        }.sorted { $0.id < $1.id }
        return TreeInsightSummary(itemCount: nodes.count, fileCount: fileCount, folderCount: folderCount,
                                  symlinkCount: symlinkCount, totalBytes: totalBytes,
                                  totalBytesOverflowed: overflowed, unknownSizeFileCount: unknownSizeCount,
                                  extensionCounts: extensionCounts, kindCounts: kindCounts,
                                  largestFiles: Array(largest.prefix(count)),
                                  recentlyModifiedFiles: Array(recent.prefix(count)),
                                  duplicateNameGroups: duplicates)
    }
}
