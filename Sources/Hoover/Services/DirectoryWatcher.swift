import CoreServices
import Darwin
import Foundation

/// Watches visible directory membership without repeatedly enumerating the directory.
@MainActor
final class DirectoryWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pendingChange: Task<Void, Never>?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    @discardableResult
    func start() -> Bool {
        guard source == nil else { return true }
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }
        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
            queue: .main
        )
        watcher.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleChange() }
        }
        // The cancel handler owns the descriptor, including deinitialization and failed restarts.
        watcher.setCancelHandler { Darwin.close(descriptor) }
        source = watcher
        watcher.resume()
        return true
    }

    func stop() {
        pendingChange?.cancel()
        pendingChange = nil
        source?.cancel()
        source = nil
    }

    private func scheduleChange() {
        guard source != nil else { return }
        pendingChange?.cancel()
        pendingChange = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self, self.source != nil else { return }
            self.onChange()
        }
    }

    deinit {
        pendingChange?.cancel()
        source?.cancel()
    }
}

/// Recursive local observation keeps a session's search index current for unopened branches too.
@MainActor
final class RootWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var pendingChange: Task<Void, Never>?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    @discardableResult
    func start() -> Bool {
        guard stream == nil else { return true }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, context, _, _, _, _ in
            guard let context else { return }
            let watcher = Unmanaged<RootWatcher>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [weak watcher] in watcher?.scheduleChange() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let watcher = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.12,
            flags
        ) else { return false }
        FSEventStreamSetDispatchQueue(watcher, .main)
        guard FSEventStreamStart(watcher) else {
            FSEventStreamInvalidate(watcher)
            FSEventStreamRelease(watcher)
            return false
        }
        stream = watcher
        return true
    }

    func stop() {
        pendingChange?.cancel()
        pendingChange = nil
        guard let watcher = stream else { return }
        stream = nil
        FSEventStreamStop(watcher)
        FSEventStreamInvalidate(watcher)
        FSEventStreamRelease(watcher)
    }

    private func scheduleChange() {
        guard stream != nil else { return }
        pendingChange?.cancel()
        pendingChange = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self, self.stream != nil else { return }
            self.onChange()
        }
    }

    deinit {
        pendingChange?.cancel()
        if let watcher = stream {
            FSEventStreamStop(watcher)
            FSEventStreamInvalidate(watcher)
            FSEventStreamRelease(watcher)
        }
    }
}
