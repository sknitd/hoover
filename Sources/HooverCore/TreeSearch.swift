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

        var matches: [SearchMatch] = []
        for record in records {
            if let rank = rank(query: query, record: record, fuzzy: fuzzy) {
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
        byID.reserveCapacity(records.count)
        for record in records { byID[record.node.id] = record }

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
    }

    private static func rank(query: String, record: IndexRecord, fuzzy: Bool) -> Int? {
        let name = record.normalizedName
        if name == query { return 0 }
        if record.normalizedBasename == query { return 1 }
        if name.hasPrefix(query) { return 2 }
        if record.normalizedBasename.contains(query) { return 3 }
        let extensionQuery = query.hasPrefix(".") ? String(query.dropFirst()) : query
        if !record.node.isDirectory, !extensionQuery.isEmpty,
           record.normalizedExtension == extensionQuery { return 4 }
        if name.contains(query) { return 3 }
        if fuzzy, query.count >= 2, isSubsequence(query, of: name) { return 5 }
        return nil
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
