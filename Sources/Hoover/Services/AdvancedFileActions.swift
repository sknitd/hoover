import AppKit
import CryptoKit
import Darwin
import Foundation
import HooverCore
import ObjectiveC

private enum AdvancedFileActionError: LocalizedError {
    case invalidName
    case destinationExists
    case notLocal
    case notDirectory
    case symbolicLinkParent
    case outsideRoot
    case invalidTags
    case unavailableCloudFile
    case checksumRequiresRegularFile
    case fileChanged
    case invalidChunkSize

    var errorDescription: String? {
        switch self {
        case .invalidName: return "Choose a nonempty name without slashes, colons, or control characters."
        case .destinationExists: return "An item with that name already exists. Nothing was replaced."
        case .notLocal: return "This action requires a local file or folder."
        case .notDirectory: return "Choose an existing folder."
        case .symbolicLinkParent: return "Open the symbolic link as a root before creating a folder inside it."
        case .outsideRoot: return "This item is outside the current root folder."
        case .invalidTags: return "Enter one tag per line, without control characters."
        case .unavailableCloudFile: return "Download this cloud file in Finder before computing its checksum."
        case .checksumRequiresRegularFile: return "Checksums are available for regular files, excluding folders and symbolic links."
        case .fileChanged: return "The file changed while its checksum was being computed. Try again."
        case .invalidChunkSize: return "The checksum read size is invalid."
        }
    }
}

/// Testable local operations used by the native prompts below. Destination
/// creation/moves are exclusive, so collisions cannot overwrite existing items.
enum AdvancedFileOperations {
    static func validatedName(_ name: String) throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains(":"),
              name.rangeOfCharacter(from: .controlCharacters) == nil,
              name.lengthOfBytes(using: .utf8) <= 255 else { throw AdvancedFileActionError.invalidName }
        return name
    }

    static func rename(from source: URL, to name: String) throws -> URL {
        try requireFileURL(source)
        let name = try validatedName(name)
        _ = try FileManager.default.attributesOfItem(atPath: source.path)
        let destination = source.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL
        if source.standardizedFileURL.path == destination.path { return source.standardizedFileURL }
        try exclusiveMove(from: source, to: destination)
        return destination
    }

    static func duplicate(_ source: URL) throws -> URL {
        try requireFileURL(source)
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let ordinaryFolder = values.isDirectory == true && values.isPackage != true
        let parts = nameParts(source.lastPathComponent, preserveAsFolder: ordinaryFolder)
        let parent = source.deletingLastPathComponent()
        let staging = try temporaryDirectory(in: parent)
        defer { try? FileManager.default.removeItem(at: staging) }
        let copy = staging.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: copy)
        for number in parts.firstNumber...(parts.firstNumber + 10_000) {
            let suffix = number == 1 ? " copy" : " copy \(number)"
            let destination = parent.appendingPathComponent(parts.stem + suffix + parts.extensionSuffix)
            do {
                try exclusiveMove(from: copy, to: destination)
                return destination
            } catch AdvancedFileActionError.destinationExists { continue }
        }
        throw AdvancedFileActionError.destinationExists
    }

    static func createFolder(in parent: URL, name: String = "New Folder", root: URL? = nil) throws -> URL {
        try requireFileURL(parent)
        if let root {
            _ = try relativePath(of: parent, root: root)
        } else {
            let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw AdvancedFileActionError.symbolicLinkParent }
        }
        var directory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue else {
            throw AdvancedFileActionError.notDirectory
        }
        let name = try validatedName(name)
        for number in 1...10_000 {
            let candidate = parent.appendingPathComponent(number == 1 ? name : "\(name) \(number)", isDirectory: true)
            if mkdir(candidate.path, 0o755) == 0 { return candidate.standardizedFileURL }
            let code = errno
            if code == EEXIST { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        throw AdvancedFileActionError.destinationExists
    }

    static func relativePath(of url: URL, root: URL) throws -> String {
        try requireFileURL(url)
        try requireFileURL(root)
        let path = url.standardizedFileURL.path
        let scope = root.standardizedFileURL.path
        guard within(path, root: scope),
              within(url.resolvingSymlinksInPath().standardizedFileURL.path,
                     root: root.resolvingSymlinksInPath().standardizedFileURL.path) else {
            throw AdvancedFileActionError.outsideRoot
        }
        if path == scope { return "." }
        let prefix = scope.hasSuffix("/") ? scope : scope + "/"
        return String(path.dropFirst(prefix.count))
    }

    static func normalizedTags(_ tags: [String]) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            let name = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.rangeOfCharacter(from: .controlCharacters) == nil else { throw AdvancedFileActionError.invalidTags }
            if !name.isEmpty, seen.insert(name.lowercased()).inserted { result.append(name) }
        }
        return result
    }

    @discardableResult
    static func setTags(_ tags: [String], for url: URL) throws -> [String] {
        try requireFileURL(url)
        let tags = try normalizedTags(tags)
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        return tags
    }

    /// The nonisolated async function runs away from the MainActor. Reads remain
    /// bounded per chunk; cancellation is checked before opening and each read.
    static func sha256(of url: URL, chunkSize: Int = 1_048_576) async throws -> String {
        try Task.checkCancellation()
        try requireFileURL(url)
        guard (1...8_388_608).contains(chunkSize) else { throw AdvancedFileActionError.invalidChunkSize }
        var initial = stat()
        guard lstat(url.path, &initial) == 0 else { throw posixError() }
        guard initial.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw AdvancedFileActionError.checksumRequiresRegularFile
        }
        let cloud = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if initial.st_flags & UInt32(SF_DATALESS) != 0 ||
            (cloud.isUbiquitousItem == true && cloud.ubiquitousItemDownloadingStatus != .current &&
             cloud.ubiquitousItemDownloadingStatus != .downloaded) {
            throw AdvancedFileActionError.unavailableCloudFile
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else { throw posixError() }
        guard opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              opened.st_dev == initial.st_dev, opened.st_ino == initial.st_ino else {
            throw AdvancedFileActionError.fileChanged
        }
        guard opened.st_flags & UInt32(SF_DATALESS) == 0 else { throw AdvancedFileActionError.unavailableCloudFile }
        var digest = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            digest.update(data: data)
        }
        try Task.checkCancellation()
        var finished = stat()
        var pathState = stat()
        guard fstat(descriptor, &finished) == 0, lstat(url.path, &pathState) == 0,
              finished.st_size == opened.st_size,
              finished.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
              finished.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec,
              pathState.st_dev == opened.st_dev, pathState.st_ino == opened.st_ino else {
            throw AdvancedFileActionError.fileChanged
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func requireFileURL(_ url: URL) throws {
        if !url.isFileURL { throw AdvancedFileActionError.notLocal }
    }

    private static func within(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func exclusiveMove(from source: URL, to destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw AdvancedFileActionError.destinationExists }
            throw posixError()
        }
    }

    private static func temporaryDirectory(in parent: URL) throws -> URL {
        var template = parent.appendingPathComponent(".hoover-copy-XXXXXX").path.utf8CString
        guard mkdtemp(&template) != nil else { throw posixError() }
        let path = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func nameParts(_ name: String, preserveAsFolder: Bool) -> (stem: String, extensionSuffix: String, firstNumber: Int) {
        let filename = URL(fileURLWithPath: name)
        var suffix = preserveAsFolder || filename.pathExtension.isEmpty ? "" : "." + filename.pathExtension
        for compound in ["tar.gz", "tar.bz2", "tar.xz", "tar.zst", "tar.lzma"] where !preserveAsFolder && name.lowercased().hasSuffix("." + compound) {
            suffix = String(name.suffix(compound.count + 1))
            break
        }
        var stem = suffix.isEmpty ? name : String(name.dropLast(suffix.count))
        var firstNumber = 1
        if let range = stem.range(of: #"(?i) copy(?: \d+)?$"#, options: .regularExpression), range.lowerBound != stem.startIndex {
            let ending = String(stem[range])
            let prior = ending.split(separator: " ").last.flatMap { Int($0) } ?? 1
            firstNumber = max(2, min(1_000_000, prior) + 1)
            stem = String(stem[..<range.lowerBound])
        }
        return (stem, suffix, firstNumber)
    }

    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

@MainActor
private final class AdvancedActionState: NSObject {
    var checksumTask: Task<Void, Never>?
    var checksumRevision = 0
    var sharingPicker: NSSharingServicePicker?
    deinit { checksumTask?.cancel() }
}

@MainActor private var advancedActionStateKey: UInt8 = 0

extension FileActions {
    private var advancedState: AdvancedActionState {
        if let existing = objc_getAssociatedObject(self, &advancedActionStateKey) as? AdvancedActionState { return existing }
        let state = AdvancedActionState()
        objc_setAssociatedObject(self, &advancedActionStateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }

    func rename(_ node: FileNode) {
        guard let name = advancedPrompt(title: "Rename “\(node.name)”", message: "Enter the new name.", value: node.name) else { return }
        runAdvancedMutation(changed: node.url) { try AdvancedFileOperations.rename(from: node.url, to: name) }
    }

    func duplicate(_ node: FileNode) {
        runAdvancedMutation(changed: node.url) { try AdvancedFileOperations.duplicate(node.url) }
    }

    func newFolder(in parent: URL, root: URL? = nil) {
        guard let name = advancedPrompt(title: "New Folder", message: "Create a folder here.", value: "New Folder") else { return }
        runAdvancedMutation(changed: parent) { try AdvancedFileOperations.createFolder(in: parent, name: name, root: root) }
    }

    func copyRelativePath(_ node: FileNode, root: URL) {
        do { advancedCopyText(try AdvancedFileOperations.relativePath(of: node.url, root: root)) }
        catch { onError?(error.localizedDescription) }
    }

    func copyFileURL(_ node: FileNode) {
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        let text = node.url.absoluteString
        guard clipboard.setString(text, forType: .string), clipboard.setString(text, forType: .fileURL) else {
            onError?("The clipboard is unavailable.")
            return
        }
    }

    func share(_ node: FileNode) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
              let view = window.contentView else { onError?("Open the file HUD before sharing this item."); return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let point = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let anchor = CGRect(x: min(max(point.x, view.bounds.minX), view.bounds.maxX),
                            y: min(max(point.y, view.bounds.minY), view.bounds.maxY), width: 1, height: 1)
        let picker = NSSharingServicePicker(items: [node.url])
        advancedState.sharingPicker = picker
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    func openTerminal(_ node: FileNode) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            onError?("Terminal is unavailable.")
            return
        }
        let directory = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        beginOpening()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([directory], withApplicationAt: terminal, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                defer { self.endOpening() }
                if let error { self.onError?(error.localizedDescription) }
                else { self.onDismiss?() }
            }
        }
    }

    func copyChecksum(_ node: FileNode) {
        cancelChecksum()
        let state = advancedState
        let revision = state.checksumRevision
        state.checksumTask = Task { [weak self] in
            do {
                let checksum = try await AdvancedFileOperations.sha256(of: node.url)
                guard !Task.isCancelled, let self, self.advancedState.checksumRevision == revision else { return }
                self.advancedCopyText(checksum)
                self.advancedState.checksumTask = nil
            } catch is CancellationError {
                // Cancellation or changing selection must not write the clipboard.
            } catch {
                guard let self, self.advancedState.checksumRevision == revision else { return }
                self.advancedState.checksumTask = nil
                self.onError?("Could not compute SHA-256. \(error.localizedDescription)")
            }
        }
    }

    func cancelChecksum() {
        let state = advancedState
        state.checksumRevision += 1
        state.checksumTask?.cancel()
        state.checksumTask = nil
    }

    func editTags(_ node: FileNode) {
        do {
            let existing = try node.url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
            guard let text = advancedPrompt(title: "Finder Tags", message: "Enter one tag per line. Remove a line to remove that tag.",
                                            value: existing.joined(separator: "\n"), multiline: true) else { return }
            let tags = try AdvancedFileOperations.normalizedTags(text.components(separatedBy: .newlines))
            runAdvancedMutation(changed: node.url) {
                try AdvancedFileOperations.setTags(tags, for: node.url)
                return node.url
            }
        } catch { onError?("Could not edit Finder tags. \(error.localizedDescription)") }
    }

    private func runAdvancedMutation(changed url: URL, operation: @escaping @Sendable () throws -> URL) {
        beginOpening()
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try operation() } }.value
            guard let self else { return }
            defer { self.endOpening() }
            switch result {
            case .success: self.onChanged?(url)
            case .failure(let error): self.onError?(error.localizedDescription)
            }
        }
    }

    private func advancedCopyText(_ text: String) {
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.setString(text, forType: .string) { onError?("The clipboard is unavailable.") }
    }

    private func advancedPrompt(title: String, message: String, value: String, multiline: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: value)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 340, height: 130))
        if multiline {
            text.isRichText = false
            text.string = value
            let scroll = NSScrollView(frame: text.frame)
            scroll.hasVerticalScroller = true
            scroll.documentView = text
            alert.accessoryView = scroll
        } else {
            field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
            alert.accessoryView = field
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = multiline ? text : field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return multiline ? text.string : field.stringValue
    }
}
