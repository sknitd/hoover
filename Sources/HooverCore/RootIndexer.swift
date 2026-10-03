import Foundation

public struct IndexRecord: Hashable, Sendable {
    public let node: FileNode
    public let parentID: String?
    public let depth: Int
    public let relativePath: String
    public let normalizedName: String
    public let normalizedBasename: String
    public let normalizedExtension: String

    public init(node: FileNode, parentID: String?, depth: Int, relativePath: String) {
        self.node = node
        self.parentID = parentID
        self.depth = depth
        self.relativePath = relativePath
        self.normalizedName = TreeSearch.normalize(node.name)
        self.normalizedBasename = TreeSearch.normalize(node.url.deletingPathExtension().lastPathComponent)
        self.normalizedExtension = TreeSearch.normalize(node.url.pathExtension)
    }
}

/// A per-session ephemeral, breadth-first index. It never searches ancestors or
/// unrelated locations and never gives symbolic links permission to escape root.
public struct RootIndexer: Sendable {
    public init() {}

    public func stream(root: URL, includeHidden: Bool = false,
                       includePackages: Bool = false, followSymlinks: Bool = false,
                       maxDepth: Int? = nil, excludedPaths: [String] = [],
                       excludeExternalVolumes: Bool = false,
                       excludeNetworkVolumes: Bool = false) -> AsyncStream<[IndexRecord]> {
        AsyncStream(bufferingPolicy: .bufferingOldest(8)) { continuation in
            let producer = Task.detached(priority: .utility) {
                await Self.produce(root: root, includeHidden: includeHidden,
                                   includePackages: includePackages, followSymlinks: followSymlinks,
                                   maxDepth: maxDepth, excludedPaths: excludedPaths,
                                   excludeExternalVolumes: excludeExternalVolumes,
                                   excludeNetworkVolumes: excludeNetworkVolumes,
                                   continuation: continuation)
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    private static func produce(root: URL, includeHidden: Bool, includePackages: Bool,
                                followSymlinks: Bool, maxDepth: Int?,
                                excludedPaths: [String], excludeExternalVolumes: Bool,
                                excludeNetworkVolumes: Bool,
                                continuation: AsyncStream<[IndexRecord]>.Continuation) async {
        defer { continuation.finish() }
        let root = root.standardizedFileURL
        let exclusions = excludedPaths.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.pathComponents
        }
        guard !isExcluded(root, exclusions: exclusions,
                          excludeExternalVolumes: excludeExternalVolumes,
                          excludeNetworkVolumes: excludeNetworkVolumes) else { return }
        guard !Task.isCancelled, let rootNode = try? DirectoryReader.node(at: root) else { return }
        let rootRecord = IndexRecord(node: rootNode, parentID: nil, depth: 0, relativePath: "")
        guard await enqueue([rootRecord], into: continuation) else { return }
        guard rootNode.isDirectory, maxDepth.map({ $0 > 0 }) ?? true else { return }

        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = canonicalRoot.pathComponents
        var visitedDirectories: Set<String> = [canonicalRoot.path]
        var directories = [rootRecord]
        var nextDirectory = 0
        var batch: [IndexRecord] = []
        batch.reserveCapacity(128)
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        let propertyKeys: [URLResourceKey] = [.isPackageKey]

        while nextDirectory < directories.count, !Task.isCancelled {
            let parent = directories[nextDirectory]
            nextDirectory += 1
            let physicalParent = parent.node.url.resolvingSymlinksInPath().standardizedFileURL
            let parentComponents = physicalParent.pathComponents
            guard parentComponents.count >= rootComponents.count,
                  Array(parentComponents.prefix(rootComponents.count)) == rootComponents else { continue }
            guard !isExcluded(physicalParent, exclusions: exclusions,
                              excludeExternalVolumes: excludeExternalVolumes,
                              excludeNetworkVolumes: excludeNetworkVolumes) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: physicalParent, includingPropertiesForKeys: propertyKeys,
                options: options, errorHandler: { _, _ in !Task.isCancelled }) else { continue }

            while !Task.isCancelled, let physicalChild = enumerator.nextObject() as? URL {
                // Enumerate the resolved directory (Foundation does not reliably
                // enumerate a symlink root) but keep the visible ancestry path.
                let childURL = parent.node.url.appendingPathComponent(physicalChild.lastPathComponent)
                guard !isExcluded(childURL, exclusions: exclusions,
                                  excludeExternalVolumes: excludeExternalVolumes,
                                  excludeNetworkVolumes: excludeNetworkVolumes) else { continue }
                guard let node = try? DirectoryReader.node(at: childURL) else { continue }
                let relativePath = parent.relativePath.isEmpty ? node.name : parent.relativePath + "/" + node.name
                let record = IndexRecord(node: node, parentID: parent.node.id,
                                         depth: parent.depth + 1, relativePath: relativePath)
                batch.append(record)

                if node.isDirectory,
                   maxDepth.map({ record.depth < $0 }) ?? true,
                   !node.isSymbolicLink || followSymlinks,
                   includePackages || !isPackage(node.url) {
                    let canonical = node.url.resolvingSymlinksInPath().standardizedFileURL
                    let components = canonical.pathComponents
                    let staysInsideRoot = components.count >= rootComponents.count &&
                        Array(components.prefix(rootComponents.count)) == rootComponents
                    if staysInsideRoot, visitedDirectories.insert(canonical.path).inserted {
                        directories.append(record)
                    }
                }

                if batch.count == 128 {
                    guard await enqueue(batch, into: continuation) else { return }
                    batch.removeAll(keepingCapacity: true)
                    await Task.yield()
                }
            }
            // Release consumed queue entries periodically without changing BFS
            // ordering. The frontier can grow with the real directory tree.
            if nextDirectory >= 1024, nextDirectory * 2 >= directories.count {
                directories.removeFirst(nextDirectory)
                nextDirectory = 0
            }
        }
        if !Task.isCancelled, !batch.isEmpty { _ = await enqueue(batch, into: continuation) }
    }

    private static func isPackage(_ url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true { return true }
        // Foundation's package classification is unavailable on some test hosts.
        return ["app", "bundle", "framework", "plugin", "xcodeproj", "xcworkspace",
                "xcassets", "photoslibrary", "playground", "rtfd", "pages", "numbers",
                "key"].contains(url.pathExtension.lowercased())
    }

    private static func isExcluded(_ url: URL, exclusions: [[String]],
                                   excludeExternalVolumes: Bool, excludeNetworkVolumes: Bool) -> Bool {
        if !exclusions.isEmpty {
            let visible = url.standardizedFileURL.pathComponents
            let physical = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            if exclusions.contains(where: { prefix in
                (visible.count >= prefix.count && Array(visible.prefix(prefix.count)) == prefix) ||
                (physical.count >= prefix.count && Array(physical.prefix(prefix.count)) == prefix)
            }) { return true }
        }
        if excludeExternalVolumes || excludeNetworkVolumes {
            let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey])
            if excludeExternalVolumes, values?.volumeIsInternal == false { return true }
            if excludeNetworkVolumes, values?.volumeIsLocal == false { return true }
        }
        return false
    }

    /// bufferingOldest rejects the new batch when full. Retrying that exact
    /// batch provides bounded, lossless backpressure while a busy UI catches up.
    private static func enqueue(_ batch: [IndexRecord],
                                into continuation: AsyncStream<[IndexRecord]>.Continuation) async -> Bool {
        while !Task.isCancelled {
            switch continuation.yield(batch) {
            case .enqueued: return true
            case .terminated: return false
            case .dropped:
                do { try await Task.sleep(nanoseconds: 1_000_000) }
                catch { return false }
            @unknown default: return false
            }
        }
        return false
    }
}
