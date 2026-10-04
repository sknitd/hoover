import Combine
import Foundation

struct SavedSearch: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var query: String

    init(id: UUID = UUID(), name: String, query: String) {
        self.id = id
        self.name = name
        self.query = query
    }
}

/// Local workspace preferences. Stored URLs preserve the chosen visible path;
/// reopening/access validation belongs to the session coordinator.
@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var favorites: [URL] = []
    @Published private(set) var recentRoots: [URL] = []
    @Published private(set) var savedSearches: [SavedSearch] = []

    private let defaults: UserDefaults
    private let storageKey = "Hoover.workspace.v1"
    private static let historyLimit = 12

    private struct Snapshot: Codable {
        let favorites: [URL]
        let recentRoots: [URL]
        let savedSearches: [SavedSearch]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: storageKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        favorites = Self.normalized(snapshot.favorites)
        recentRoots = Array(Self.normalized(snapshot.recentRoots).prefix(Self.historyLimit))
        var ids = Set<UUID>()
        savedSearches = snapshot.savedSearches.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ids.insert($0.id).inserted
        }
    }

    func recordRoot(_ url: URL) {
        guard url.isFileURL else { return }
        let url = url.standardizedFileURL
        recentRoots.removeAll { $0.path == url.path }
        recentRoots.insert(url, at: 0)
        recentRoots = Array(recentRoots.prefix(Self.historyLimit))
        persist()
    }

    func toggleFavorite(_ url: URL) {
        guard url.isFileURL else { return }
        let url = url.standardizedFileURL
        if favorites.contains(where: { $0.path == url.path }) {
            favorites.removeAll { $0.path == url.path }
        } else {
            favorites.append(url)
        }
        persist()
    }

    func removeFavorite(_ url: URL) {
        favorites.removeAll { $0.path == url.standardizedFileURL.path }
        persist()
    }

    func clearFavorites() {
        favorites = []
        persist()
    }

    func removeRecentRoot(_ url: URL) {
        recentRoots.removeAll { $0.path == url.standardizedFileURL.path }
        persist()
    }

    func clearHistory() {
        recentRoots = []
        persist()
    }

    @discardableResult
    func saveSearch(name: String, query: String) -> SavedSearch? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !query.isEmpty else { return nil }
        if let index = savedSearches.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            savedSearches[index].name = name
            savedSearches[index].query = query
            persist()
            return savedSearches[index]
        }
        let saved = SavedSearch(name: name, query: query)
        savedSearches.append(saved)
        persist()
        return saved
    }

    func removeSavedSearch(id: UUID) {
        savedSearches.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        let snapshot = Snapshot(favorites: favorites, recentRoots: recentRoots, savedSearches: savedSearches)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func normalized(_ urls: [URL]) -> [URL] {
        var paths = Set<String>()
        return urls.compactMap {
            guard $0.isFileURL else { return nil }
            let normalized = $0.standardizedFileURL
            return paths.insert(normalized.path).inserted ? normalized : nil
        }
    }
}
