import Foundation

/// A real filesystem item. Its identity deliberately preserves its visible path,
/// rather than resolving a symbolic link to an item elsewhere.
public struct FileNode: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let size: Int64?
    public let modified: Date?

    public init(url: URL, isDirectory: Bool, isSymbolicLink: Bool = false,
                size: Int64? = nil, modified: Date? = nil) {
        self.url = url.standardizedFileURL
        self.id = self.url.path
        self.name = self.url.lastPathComponent
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.size = size
        self.modified = modified
    }
}

public enum DirectoryReadError: LocalizedError, Sendable {
    case notDirectory(URL)

    public var errorDescription: String? {
        switch self {
        case .notDirectory(let url): return "\(url.lastPathComponent) is not a folder."
        }
    }
}

public enum DirectoryReader {
    public static func node(at url: URL) throws -> FileNode {
        let url = url.standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let kind = attributes[.type] as? FileAttributeType
        let symbolicLink = kind == .typeSymbolicLink
        var directory = ObjCBool(kind == .typeDirectory)
        if symbolicLink {
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
        }
        return FileNode(url: url, isDirectory: directory.boolValue,
                        isSymbolicLink: symbolicLink,
                        size: (attributes[.size] as? NSNumber)?.int64Value,
                        modified: attributes[.modificationDate] as? Date)
    }

    /// Only the direct children are read. Recursive indexing lives on a
    /// cancellable background task in RootIndexer.
    public static func contents(of url: URL, includeHidden: Bool = false) throws -> [FileNode] {
        guard try node(at: url).isDirectory else { throw DirectoryReadError.notDirectory(url) }
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        let children = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: options)
        return children.compactMap { try? node(at: $0) }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }
}
