import Foundation

public struct SizeConstraint: Sendable, Equatable {
    public let lowerBound: Int64?
    public let upperBound: Int64?
    public let includesLowerBound: Bool
    public let includesUpperBound: Bool

    fileprivate func contains(_ size: Int64) -> Bool {
        if let lowerBound, includesLowerBound ? size < lowerBound : size <= lowerBound { return false }
        if let upperBound, includesUpperBound ? size > upperBound : size >= upperBound { return false }
        return true
    }
}

public struct ModifiedConstraint: Sendable, Equatable {
    public let lowerBound: Date?
    public let upperBound: Date?
    public let includesLowerBound: Bool
    public let includesUpperBound: Bool

    fileprivate func contains(_ date: Date) -> Bool {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return false }
        if let lowerBound, includesLowerBound ? date < lowerBound : date <= lowerBound { return false }
        if let upperBound, includesUpperBound ? date > upperBound : date >= upperBound { return false }
        return true
    }
}

public enum AdvancedSearchFilter: Sendable, Equatable {
    case kind(Set<FileKind>)
    case extensions(Set<String>)
    case size(SizeConstraint)
    case modified(ModifiedConstraint)
    case path(String)
}

public struct AdvancedSearchClause: Sendable, Equatable {
    public let filter: AdvancedSearchFilter
    public let isExcluded: Bool
}

public struct ParsedSearchQuery: Sendable, Equatable {
    public let source: String
    public let textTerms: [String]
    public let excludedTerms: [String]
    public let clauses: [AdvancedSearchClause]
    public var isEmpty: Bool { textTerms.isEmpty && excludedTerms.isEmpty && clauses.isEmpty }
}

public enum AdvancedSearchError: LocalizedError, Sendable, Equatable {
    case unterminatedQuote
    case danglingEscape
    case emptyExclusion
    case unknownFilter(String)
    case missingValue(String)
    case invalidKind(String)
    case invalidExtension(String)
    case invalidSize(String)
    case invalidDate(String)
    case invalidRange(String)

    public var errorDescription: String? {
        switch self {
        case .unterminatedQuote: return "Close the quoted phrase before searching."
        case .danglingEscape: return "A trailing backslash must escape another character."
        case .emptyExclusion: return "Add a word or filter after the exclusion minus sign."
        case .unknownFilter(let key): return "Unknown filter “\(key)”. Use kind, ext, size, modified, before, after, or path; quote a filename containing a colon."
        case .missingValue(let key): return "Add a value after \(key):."
        case .invalidKind(let value): return "Unknown kind “\(value)”. Use file, folder, image, video, audio, document, code, or archive."
        case .invalidExtension(let value): return "Invalid extension list “\(value)”. Use ext:swift,pdf without empty entries or paths."
        case .invalidSize(let value): return "Invalid size “\(value)”. Use whole byte amounts, such as 10MB or 2MiB, within the 64-bit byte range."
        case .invalidDate(let value): return "Invalid date “\(value)”. Use an actual YYYY-MM-DD date, today, yesterday, or a positive day count such as 7d."
        case .invalidRange(let value): return "Invalid range “\(value)”. Supply two ordered bounds separated by .. ."
        }
    }
}

public enum AdvancedSearch {
    public static let queryHelp = "Words and quoted phrases combine with AND. Exclude with -word. Filters: kind:image,video (file, folder, audio, document, code, archive also work); ext:swift,pdf; size:>10MB or 1MiB..10MiB; modified:>=2026-01-01, today, yesterday, or 7d; before:2026-01-01; after:2026-01-01; path:\"Sources/Core\". Dates use UTC calendar days; after excludes the named day. Filters stay inside the current root."
    public static let examples = ["\"annual report\" -draft ext:pdf", "kind:image size:>10MB", "ext:swift,json path:Sources", "modified:7d -kind:folder", "size:1MiB..10MiB before:2026-01-01"]

    public static func parse(query: String, now: Date = Date()) throws -> ParsedSearchQuery {
        var terms: [String] = [], excluded: [String] = [], clauses: [AdvancedSearchClause] = []
        for token in try tokenize(query) {
            if !token.literal, let colon = token.value.firstIndex(of: ":") {
                let key = token.value[..<colon].lowercased()
                let value = String(token.value[token.value.index(after: colon)...])
                guard !value.isEmpty else { throw AdvancedSearchError.missingValue(key) }
                let filter: AdvancedSearchFilter
                switch key {
                case "kind":
                    let values = value.split(separator: ",", omittingEmptySubsequences: false)
                    var kinds: Set<FileKind> = []
                    for value in values {
                        guard let kind = FileKind(rawValue: value.lowercased()) else {
                            throw AdvancedSearchError.invalidKind(String(value))
                        }
                        kinds.insert(kind)
                    }
                    filter = .kind(kinds)
                case "ext":
                    var extensions: Set<String> = []
                    for piece in value.split(separator: ",", omittingEmptySubsequences: false) {
                        let ext = piece.hasPrefix(".") ? String(piece.dropFirst()) : String(piece)
                        guard !ext.isEmpty, !ext.contains(where: { $0.isWhitespace || $0 == "/" || $0 == ":" || $0 == "\\" }) else {
                            throw AdvancedSearchError.invalidExtension(value)
                        }
                        extensions.insert(TreeSearch.normalize(ext))
                    }
                    filter = .extensions(extensions)
                case "size": filter = .size(try parseSizeConstraint(value))
                case "modified": filter = .modified(try parseModified(value, now: now))
                case "before": filter = .modified(try parseModified("<" + value, now: now))
                case "after": filter = .modified(try parseModified(">" + value, now: now))
                case "path": filter = .path(TreeSearch.normalize(value))
                default: throw AdvancedSearchError.unknownFilter(key)
                }
                clauses.append(AdvancedSearchClause(filter: filter, isExcluded: token.excluded))
            } else if token.excluded {
                excluded.append(token.value)
            } else {
                terms.append(token.value)
            }
        }
        return ParsedSearchQuery(source: query, textTerms: terms, excludedTerms: excluded, clauses: clauses)
    }

    public static func search(query: String, records: [IndexRecord], fuzzy: Bool = false,
                              now: Date = Date()) throws -> SearchResult {
        let parsed = try parse(query: query, now: now)
        try Task.checkCancellation()
        if parsed.isEmpty { return TreeSearch.search(query: "", records: records, fuzzy: fuzzy) }
        if parsed.textTerms.count == 1, parsed.excludedTerms.isEmpty, parsed.clauses.isEmpty {
            return TreeSearch.search(query: parsed.textTerms[0], records: records, fuzzy: fuzzy)
        }
        var candidates: [SearchMatch]
        if let term = parsed.textTerms.first {
            candidates = TreeSearch.search(query: term, records: records, fuzzy: fuzzy).matches
            for term in parsed.textTerms.dropFirst() {
                try Task.checkCancellation()
                let additional = TreeSearch.search(query: term, records: candidates.map(\.record), fuzzy: fuzzy)
                let ranks = Dictionary(additional.matches.map { ($0.record.node.id, $0.rank) }, uniquingKeysWith: min)
                candidates = candidates.compactMap { match in
                    ranks[match.record.node.id].map { SearchMatch(record: match.record, rank: max(match.rank, $0)) }
                }
            }
        } else {
            candidates = records.filter { $0.depth > 0 }.map { SearchMatch(record: $0, rank: 0) }
        }
        for term in parsed.excludedTerms {
            try Task.checkCancellation()
            let ids = Set(TreeSearch.search(query: term, records: candidates.map(\.record)).matches.map { $0.record.node.id })
            candidates.removeAll { ids.contains($0.record.node.id) }
        }
        var examined = 0
        try candidates.removeAll { match in
            examined += 1
            if examined.isMultiple(of: 512) { try Task.checkCancellation() }
            return parsed.clauses.contains { clause in
                let passed = matches(clause.filter, record: match.record)
                return clause.isExcluded ? passed : !passed
            }
        }
        var comparisons = 0
        try candidates.sort {
            comparisons += 1
            if comparisons.isMultiple(of: 2_048) { try Task.checkCancellation() }
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.record.depth != $1.record.depth { return $0.record.depth < $1.record.depth }
            if $0.record.normalizedName != $1.record.normalizedName { return $0.record.normalizedName < $1.record.normalizedName }
            return $0.record.node.id < $1.record.node.id
        }
        var parents: [String: IndexRecord] = [:]
        for (offset, record) in records.enumerated() {
            if offset.isMultiple(of: 512) { try Task.checkCancellation() }
            if record.node.isDirectory { parents[record.node.id] = record }
        }
        var visible: Set<String> = []
        for match in candidates {
            var record: IndexRecord? = match.record
            while let item = record, visible.insert(item.node.id).inserted {
                record = item.parentID.flatMap { parents[$0] }
            }
        }
        try Task.checkCancellation()
        return SearchResult(matches: candidates, visibleIDs: visible)
    }

    private static func matches(_ filter: AdvancedSearchFilter, record: IndexRecord) -> Bool {
        switch filter {
        case .kind(let kinds):
            return kinds.contains(FileKind.classify(normalizedExtension: record.normalizedExtension,
                                                    isDirectory: record.node.isDirectory)) ||
                (kinds.contains(.file) && !record.node.isDirectory)
        case .extensions(let extensions):
            return !record.node.isDirectory && extensions.contains {
                record.normalizedName.hasSuffix("." + $0)
            }
        case .size(let constraint):
            guard !record.node.isDirectory, let size = record.node.size, size >= 0 else { return false }
            return constraint.contains(size)
        case .modified(let constraint):
            return record.node.modified.map { constraint.contains($0) } ?? false
        case .path(let path):
            return TreeSearch.normalize(record.relativePath).contains(path)
        }
    }

    private struct Token { let value: String; let excluded: Bool; let literal: Bool }

    private static func tokenize(_ query: String) throws -> [Token] {
        var tokens: [Token] = [], text = ""
        var quote: Character?, escaping = false, started = false, excluded = false, literal = false
        func finish() throws {
            guard started else { return }
            if excluded && text.isEmpty { throw AdvancedSearchError.emptyExclusion }
            if !text.isEmpty { tokens.append(Token(value: text, excluded: excluded, literal: literal)) }
            text = ""; started = false; excluded = false; literal = false
        }
        for character in query {
            if escaping { text.append(character); escaping = false; started = true; continue }
            if character == "\\" { escaping = true; started = true; continue }
            if let active = quote {
                if character == active { quote = nil } else { text.append(character) }
                continue
            }
            if character == "'", !text.isEmpty, text.last != ":" {
                text.append(character); started = true; continue
            }
            if character == "\"" || character == "'" {
                if text.isEmpty { literal = true }
                quote = character; started = true; continue
            }
            if character.isWhitespace { try finish(); continue }
            if !started, character == "-" { excluded = true; started = true; continue }
            text.append(character); started = true
        }
        if escaping { throw AdvancedSearchError.danglingEscape }
        if quote != nil { throw AdvancedSearchError.unterminatedQuote }
        try finish()
        return tokens
    }

    private static func comparison(_ value: String) -> (String, String) {
        for op in [">=", "<=", ">", "<", "="] where value.hasPrefix(op) {
            return (op, String(value.dropFirst(op.count)))
        }
        return ("=", value)
    }

    private static func parseSizeConstraint(_ value: String) throws -> SizeConstraint {
        if value.contains("..") {
            let pieces = value.components(separatedBy: "..")
            guard pieces.count == 2, !pieces.contains("") else { throw AdvancedSearchError.invalidRange(value) }
            let lower = try byteCount(pieces[0]), upper = try byteCount(pieces[1])
            guard lower <= upper else { throw AdvancedSearchError.invalidRange(value) }
            return SizeConstraint(lowerBound: lower, upperBound: upper, includesLowerBound: true, includesUpperBound: true)
        }
        let (op, amount) = comparison(value)
        let size = try byteCount(amount)
        switch op {
        case ">", ">=": return SizeConstraint(lowerBound: size, upperBound: nil, includesLowerBound: op == ">=", includesUpperBound: false)
        case "<", "<=": return SizeConstraint(lowerBound: nil, upperBound: size, includesLowerBound: false, includesUpperBound: op == "<=")
        default: return SizeConstraint(lowerBound: size, upperBound: size, includesLowerBound: true, includesUpperBound: true)
        }
    }

    private static func byteCount(_ value: String) throws -> Int64 {
        let source = value.trimmingCharacters(in: .whitespaces)
        let pattern = #"^([0-9]+(?:\.[0-9]+)?)\s*([a-zA-Z]*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let numberRange = Range(match.range(at: 1), in: source),
              let unitRange = Range(match.range(at: 2), in: source),
              let number = Decimal(string: String(source[numberRange]), locale: Locale(identifier: "en_US_POSIX")) else {
            throw AdvancedSearchError.invalidSize(value)
        }
        let multipliers: [String: Int64] = ["": 1, "B": 1, "KB": 1_000, "MB": 1_000_000, "GB": 1_000_000_000,
                                             "TB": 1_000_000_000_000, "PB": 1_000_000_000_000_000, "EB": 1_000_000_000_000_000_000,
                                             "KIB": 1_024, "MIB": 1_048_576, "GIB": 1_073_741_824,
                                             "TIB": 1_099_511_627_776, "PIB": 1_125_899_906_842_624, "EIB": 1_152_921_504_606_846_976]
        guard let multiplier = multipliers[source[unitRange].uppercased()] else { throw AdvancedSearchError.invalidSize(value) }
        var bytes = number * Decimal(multiplier)
        guard !bytes.isNaN, bytes >= 0, bytes <= Decimal(Int64.max) else { throw AdvancedSearchError.invalidSize(value) }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &bytes, 0, .plain)
        guard rounded == bytes else { throw AdvancedSearchError.invalidSize(value) }
        return NSDecimalNumber(decimal: bytes).int64Value
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func parseModified(_ value: String, now: Date) throws -> ModifiedConstraint {
        if value.contains("..") {
            let pieces = value.components(separatedBy: "..")
            guard pieces.count == 2, !pieces.contains("") else { throw AdvancedSearchError.invalidRange(value) }
            let lower = try day(pieces[0], now: now), upper = try day(pieces[1], now: now)
            guard lower <= upper else { throw AdvancedSearchError.invalidRange(value) }
            return ModifiedConstraint(lowerBound: lower, upperBound: upper.addingTimeInterval(86_400), includesLowerBound: true, includesUpperBound: false)
        }
        let (op, source) = comparison(value)
        if source.lowercased().hasSuffix("d"), let count = Int(source.dropLast()), count > 0, count <= 36_500,
           op == "=", now.timeIntervalSinceReferenceDate.isFinite {
            return ModifiedConstraint(lowerBound: now.addingTimeInterval(-Double(count) * 86_400), upperBound: now,
                                      includesLowerBound: true, includesUpperBound: true)
        }
        let date = try day(source, now: now)
        switch op {
        case ">": return ModifiedConstraint(lowerBound: date.addingTimeInterval(86_400), upperBound: nil, includesLowerBound: true, includesUpperBound: false)
        case ">=": return ModifiedConstraint(lowerBound: date, upperBound: nil, includesLowerBound: true, includesUpperBound: false)
        case "<": return ModifiedConstraint(lowerBound: nil, upperBound: date, includesLowerBound: false, includesUpperBound: false)
        case "<=": return ModifiedConstraint(lowerBound: nil, upperBound: date.addingTimeInterval(86_400), includesLowerBound: false, includesUpperBound: false)
        default: return ModifiedConstraint(lowerBound: date, upperBound: date.addingTimeInterval(86_400), includesLowerBound: true, includesUpperBound: false)
        }
    }

    private static func day(_ value: String, now: Date) throws -> Date {
        let calendar = utcCalendar
        if ["today", "yesterday"].contains(value.lowercased()), now.timeIntervalSinceReferenceDate.isFinite {
            let today = calendar.startOfDay(for: now)
            return value.lowercased() == "today" ? today : today.addingTimeInterval(-86_400)
        }
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]), year >= 1,
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            throw AdvancedSearchError.invalidDate(value)
        }
        let verified = calendar.dateComponents([.year, .month, .day], from: date)
        guard verified.year == year, verified.month == month, verified.day == day else { throw AdvancedSearchError.invalidDate(value) }
        return date
    }
}
