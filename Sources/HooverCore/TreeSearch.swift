import Foundation

public struct SearchMatch: Hashable, Sendable {
    public let record: IndexRecord
    /// 0: full name, 1: basename, 2: prefix, 3: substring,
    /// 4: extension only, 5: optional subsequence fallback.
    public let rank: Int

    public init(record: IndexRecord, rank: Int) {
        self.record = record
        self.rank = rank
    }
}

public struct SearchResult: Sendable {
    public let matches: [SearchMatch]
    public let visibleIDs: Set<String>

    public init(matches: [SearchMatch], visibleIDs: Set<String>) {
        self.matches = matches
        self.visibleIDs = visibleIDs
    }
}

public enum TreeSearch {
    public static func search(query: String, records: [IndexRecord], fuzzy: Bool = false) -> SearchResult {
        let query = normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else {
            return SearchResult(matches: [], visibleIDs: Set(records.map { $0.node.id }))
        }
        let queryKey = QueryKey(query)

        var matches: [SearchMatch] = []
        // The immutable root labels the search scope; results are its subtree.
        for record in records where record.depth > 0 {
            if let rank = rank(query: queryKey, record: record, fuzzy: fuzzy) {
                matches.append(SearchMatch(record: record, rank: rank))
            }
        }
        matches.sort {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.record.depth != $1.record.depth { return $0.record.depth < $1.record.depth }
            if $0.record.normalizedName != $1.record.normalizedName {
                return $0.record.normalizedName < $1.record.normalizedName
            }
            return $0.record.node.id < $1.record.node.id
        }

        guard !matches.isEmpty else { return SearchResult(matches: [], visibleIDs: []) }
        var byID: [String: IndexRecord] = [:]
        // Every real parent is a directory. A tree with 100,000 files usually
        // has far fewer parent records; hashing all leaf paths per keystroke
        // wastes both memory and time.
        for record in records where record.node.isDirectory { byID[record.node.id] = record }

        var visibleIDs: Set<String> = []
        visibleIDs.reserveCapacity(matches.count)
        for match in matches {
            var current: IndexRecord? = match.record
            // A previously visited ancestor already brought its entire path
            // into the result. This also terminates malformed parent cycles.
            while let record = current, visibleIDs.insert(record.node.id).inserted {
                current = record.parentID.flatMap { byID[$0] }
            }
        }
        return SearchResult(matches: matches, visibleIDs: visibleIDs)
    }

    static func normalize(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .precomposedStringWithCanonicalMapping
    }

    private struct QueryKey {
        let text: String
        let bytes: [UInt8]
        let extensionText: String
        let allowsFuzzy: Bool

        init(_ text: String) {
            self.text = text
            self.bytes = Array(text.utf8)
            self.extensionText = text.hasPrefix(".") ? String(text.dropFirst()) : text
            self.allowsFuzzy = text.count >= 2
        }
    }

    private static func rank(query: QueryKey, record: IndexRecord, fuzzy: Bool) -> Int? {
        let name = record.normalizedName
        if name == query.text { return 0 }
        if record.normalizedBasename == query.text { return 1 }
        if name.utf8.starts(with: query.bytes) { return 2 }
        if contains(query, in: record.normalizedBasename) { return 3 }
        if !record.node.isDirectory, !query.extensionText.isEmpty,
           record.normalizedExtension == query.extensionText { return 4 }
        if contains(query, in: name) { return 3 }
        if fuzzy, query.allowsFuzzy, isSubsequence(query.text, of: name) { return 5 }
        return nil
    }

    /// Both sides are normalized to NFC once. UTF-8 is self-synchronizing, so
    /// complete query bytes cannot begin halfway through a Unicode character.
    /// This avoids a Foundation substring search for every node and keystroke.
    private static func contains(_ query: QueryKey, in name: String) -> Bool {
        name.utf8.withContiguousStorageIfAvailable { bytes in
            guard bytes.count >= query.bytes.count else { return false }
            let finalStart = bytes.count - query.bytes.count
            for start in 0...finalStart where bytes[start] == query.bytes[0] {
                var offset = 1
                while offset < query.bytes.count, bytes[start + offset] == query.bytes[offset] {
                    offset += 1
                }
                if offset == query.bytes.count { return true }
            }
            return false
        } ?? name.contains(query.text)
    }

    private static func isSubsequence(_ query: String, of name: String) -> Bool {
        var wanted = query.makeIterator()
        guard var next = wanted.next() else { return true }
        for character in name where character == next {
            guard let following = wanted.next() else { return true }
            next = following
        }
        return false
    }
}
