import AppKit
import Foundation
import QuickLookThumbnailing

@MainActor
final class MetadataService {
    private var loading: Task<FileMetadata, Never>?
    private var thumbnailRequest: QLThumbnailGenerator.Request?
    private var generation = UUID()
    private var thumbnailGeneration = UUID()

    /// Use this first so the HUD can appear while richer analysis is still running.
    func basic(url: URL) async -> FileMetadata {
        await Task.detached(priority: .userInitiated) {
            MetadataInspector.basic(url: url).metadata
        }.value
    }

    func load(url: URL) async -> FileMetadata {
        loading?.cancel()
        let token = UUID()
        generation = token
        let task = Task.detached(priority: .userInitiated) {
            await MetadataInspector.inspect(url: url)
        }
        loading = task
        let result = await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            task.cancel()
        })
        if generation == token { loading = nil }
        return result
    }

    /// Generate separately from metadata; never cause an iCloud download on hover.
    func thumbnail(url: URL) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let token = UUID()
        thumbnailGeneration = token
        if let request = thumbnailRequest { QLThumbnailGenerator.shared.cancel(request) }
        thumbnailRequest = nil
        let info = await Task.detached { MetadataInspector.basic(url: url) }.value
        guard thumbnailGeneration == token, !Task.isCancelled,
              info.canReadContent, info.size <= MetadataInspector.contentLimit else { return nil }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 560, height: 360),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: [.thumbnail])
        thumbnailRequest = request
        let generator = QLThumbnailGenerator.shared
        let image: NSImage? = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let completion = ThumbnailCompletion(continuation)
                generator.generateBestRepresentation(for: request) { representation, _ in
                    completion.finish(representation?.nsImage)
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                    generator.cancel(request)
                    completion.finish(nil)
                }
            }
        }, onCancel: {
            generator.cancel(request)
        })
        if thumbnailRequest === request { thumbnailRequest = nil }
        guard thumbnailGeneration == token, !Task.isCancelled else { return nil }
        if let image { return image }
        let artwork = await Task.detached { await MediaMetadata.audioArtwork(url) }.value
        guard thumbnailGeneration == token, !Task.isCancelled else { return nil }
        return artwork
    }

    func note(url: URL) async -> String? {
        await Task.detached { MetadataInspector.note(url: url) }.value
    }

    /// Explicit user action only. The note follows the file without changing its contents.
    func saveNote(_ note: String, url: URL) async throws {
        try await Task.detached {
            try MetadataInspector.saveNote(note, url: url)
        }.value
    }

    func cancel() {
        generation = UUID()
        thumbnailGeneration = UUID()
        loading?.cancel()
        loading = nil
        if let request = thumbnailRequest { QLThumbnailGenerator.shared.cancel(request) }
        thumbnailRequest = nil
    }
}

/// Quick Look may invoke its completion after cancellation; resume exactly once.
private final class ThumbnailCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NSImage?, Never>?

    init(_ continuation: CheckedContinuation<NSImage?, Never>) { self.continuation = continuation }

    func finish(_ image: NSImage?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: image)
    }
}
