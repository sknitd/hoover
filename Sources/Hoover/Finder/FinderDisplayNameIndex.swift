import Foundation

/// A complete, bounded snapshot of the labels Finder may display for direct
/// children. Name-only lookup must be unique across all of these labels: an
/// extensionless sibling cannot take precedence over a hidden-extension file.
struct FinderDisplayNameIndex {
    let isComplete: Bool
    private let entries: [String: Set<URL>]

    static func scan(directory: URL, maximumEntries: Int = 2_000) -> FinderDisplayNameIndex {
        guard maximumEntries > 0 else { return FinderDisplayNameIndex(isComplete: false, entries: [:]) }
        let keys: [URLResourceKey] = [.nameKey, .localizedNameKey, .hasHiddenExtensionKey]
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, _ in enumerationFailed = true; return false }
        ) else { return FinderDisplayNameIndex(isComplete: false, entries: [:]) }

        var entries: [String: Set<URL>] = [:]
        var visited = 0
        var complete = true
        while let item = enumerator.nextObject() {
            // One URL beyond the cap distinguishes a genuinely complete directory
            // with exactly `maximumEntries` children from a truncated scan. No
            // metadata is read for that extra item.
            guard visited < maximumEntries, let url = item as? URL else { complete = false; break }
            visited += 1
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                guard let localized = values.localizedName, let hiddenExtension = values.hasHiddenExtension else {
                    complete = false
                    break
                }
                var labels = Set([url.lastPathComponent, localized])
                if hiddenExtension { labels.insert(url.deletingPathExtension().lastPathComponent) }
                let canonical = url.standardizedFileURL
                for label in labels { entries[label, default: []].insert(canonical) }
            } catch {
                // Missing metadata could hide another child's display-name
                // collision; a partial result must never establish uniqueness.
                complete = false
                break
            }
        }
        return FinderDisplayNameIndex(isComplete: complete && !enumerationFailed, entries: entries)
    }

    func uniqueURL(matching label: String) -> URL? {
        guard isComplete, let matches = entries[label], matches.count == 1 else { return nil }
        return matches.first
    }

    /// AX may offer several label attributes for the same hit item. Conflicting
    /// or ambiguous labels cannot be used to guess which sibling was hovered.
    func uniqueURL(matchingAny labels: [String]) -> URL? {
        guard isComplete else { return nil }
        var resolved = Set<URL>()
        for label in labels {
            guard let matches = entries[label] else { continue }
            guard matches.count == 1 else { return nil }
            resolved.formUnion(matches)
        }
        return resolved.count == 1 ? resolved.first : nil
    }
}
