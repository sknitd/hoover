import Foundation

enum TextMetadata {
    struct Result { var sections: [MetadataSection] = []; var preview: String? }
    private static let languages: [String: String] = [
        "swift":"Swift", "m":"Objective-C", "mm":"Objective-C++", "h":"C / C++ Header",
        "c":"C", "cc":"C++", "cpp":"C++", "cxx":"C++", "hpp":"C++ Header",
        "js":"JavaScript", "jsx":"JavaScript / JSX", "ts":"TypeScript", "tsx":"TypeScript / JSX",
        "py":"Python", "rb":"Ruby", "rs":"Rust", "go":"Go", "java":"Java", "kt":"Kotlin",
        "kts":"Kotlin Script", "cs":"C#", "fs":"F#", "php":"PHP", "pl":"Perl", "lua":"Lua",
        "sh":"Shell", "bash":"Bash", "zsh":"Zsh", "fish":"Fish", "ps1":"PowerShell",
        "sql":"SQL", "r":"R", "jl":"Julia", "dart":"Dart", "ex":"Elixir", "exs":"Elixir",
        "erl":"Erlang", "hs":"Haskell", "scala":"Scala", "clj":"Clojure", "lisp":"Lisp",
        "html":"HTML", "htm":"HTML", "css":"CSS", "scss":"SCSS", "sass":"Sass", "less":"Less",
        "vue":"Vue", "svelte":"Svelte", "zig":"Zig", "asm":"Assembly", "s":"Assembly",
        "json":"JSON", "yaml":"YAML", "yml":"YAML", "toml":"TOML", "xml":"XML",
        "plist":"Property List", "md":"Markdown", "markdown":"Markdown", "mdx":"MDX",
        "ini":"INI", "conf":"Configuration", "txt":"Plain Text", "csv":"CSV", "log":"Log",
        "svg":"SVG", "obj":"Wavefront OBJ", "mtl":"Wavefront Material", "gitignore":"Git Ignore"
    ]

    static func language(for url: URL) -> String? {
        if url.lastPathComponent == "Makefile" { return "Make" }
        if url.lastPathComponent == "Dockerfile" { return "Dockerfile" }
        if url.lastPathComponent.hasPrefix(".git") { return "Git Configuration" }
        return languages[url.pathExtension.lowercased()]
    }

    static func inspect(_ url: URL, size: Int64) -> Result {
        guard let language = language(for: url), let data = MetadataInspector.boundedData(url), !data.isEmpty else { return Result() }
        let partial = size > Int64(data.count)
        if url.pathExtension.lowercased() == "plist", data.starts(with: Data("bplist".utf8)) {
            return Result(sections: config("", data: data, ext: "plist", partial: partial), preview: nil)
        }
        var encoding = "UTF-8"
        let source: String
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            guard let text = String(data: data, encoding: .utf16) else { return Result() }
            source = text
            encoding = "UTF-16"
        } else {
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return Result() }
            source = text
        }
        let lines = source.components(separatedBy: .newlines)
        var fields = [("Language", language), ("Encoding", encoding),
                      (partial ? "Scanned lines" : "Lines", String(max(1, lines.count - (source.hasSuffix("\n") ? 1 : 0))))]
        if partial { fields.append(("Inspection limit", "First 256 KB; statistics and preview are partial.")) }
        let preview = lines.prefix(30).joined(separator: "\n")
        var result = Result(sections: [MetadataInspector.section("Text", fields)], preview: String(preview.prefix(8_192)))
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown", "mdx"].contains(ext) { result.sections += markdown(source) }
        if ["json", "plist", "xml", "yaml", "yml", "toml"].contains(ext) { result.sections += config(source, data: data, ext: ext, partial: partial) }
        return result
    }

    private static func markdown(_ source: String) -> [MetadataSection] {
        let lines = source.components(separatedBy: .newlines)
        let headings = lines.filter { $0.range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) != nil }
        var fields = [("Words", String(source.split(whereSeparator: { $0.isWhitespace }).count)),
                      ("Headings", String(headings.count)),
                      ("Links", String(matches(#"(?<!!)\[[^\]]+\]\([^\)]+\)"#, source))),
                      ("Images", String(matches(#"!\[[^\]]*\]\([^\)]+\)"#, source))),
                      ("Fenced code blocks", String(lines.filter { $0.hasPrefix("```") || $0.hasPrefix("~~~") }.count / 2))]
        if let heading = headings.first { fields.insert(("Title", heading.trimmingCharacters(in: CharacterSet(charactersIn: "# "))), at: 0) }
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            fields.append(("Frontmatter", lines[1..<end].prefix(20).joined(separator: "\n")))
        }
        return [MetadataInspector.section("Markdown", fields)]
    }

    private static func config(_ source: String, data: Data, ext: String, partial: Bool) -> [MetadataSection] {
        var fields = [(String, String)]()
        if partial { return [MetadataInspector.section("Configuration", [("Validity", "Not validated; file exceeds bounded text inspection limit.")])] }
        if ext == "json" || ext == "plist" {
            let parsed: Any?
            if ext == "json" { parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
            else { parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) }
            fields.append(("Validity", parsed == nil ? "Invalid or unsupported encoding" : "Valid"))
            if let parsed {
                let keys = (parsed as? [String: Any])?.keys.sorted() ?? []
                fields += [("Top-level keys", keys.prefix(30).joined(separator: ", ")),
                           ("Key count", String(countKeys(parsed))), ("Nesting depth", String(depth(parsed)))]
            }
        } else if ext == "xml" {
            guard source.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil else {
                return [MetadataInspector.section("Configuration", [("Validity", "Not validated; DTD parsing is disabled during hover inspection.")])]
            }
            let parser = XMLParser(data: data)
            let delegate = BoundedXMLCounter()
            parser.delegate = delegate
            parser.shouldResolveExternalEntities = false
            parser.externalEntityResolvingPolicy = .never
            fields += [("Validity", parser.parse() ? "Valid" : "Invalid XML"),
                       ("Elements", String(delegate.elements)), ("Nesting depth", String(delegate.maximumDepth))]
        } else {
            let keys = source.components(separatedBy: .newlines).compactMap { line -> String? in
                guard !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#"),
                      let range = line.range(of: ext == "toml" ? "=" : ":") else { return nil }
                return String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            fields += [("Validity", "Not validated; a full \(ext.uppercased()) parser is unavailable."),
                       ("Observed top-level keys", keys.prefix(30).joined(separator: ", "))]
        }
        return [MetadataInspector.section("Configuration", fields)]
    }

    private static func countKeys(_ object: Any, budget: Int = 10_000) -> Int {
        guard budget > 0 else { return 0 }
        if let map = object as? [String: Any] { return map.count + map.values.prefix(budget).reduce(0) { $0 + countKeys($1, budget: budget / max(1, map.count)) } }
        if let array = object as? [Any] { return array.prefix(budget).reduce(0) { $0 + countKeys($1, budget: budget / max(1, array.count)) } }
        return 0
    }
    private static func depth(_ object: Any, level: Int = 0) -> Int {
        guard level < 64 else { return level }
        if let map = object as? [String: Any] { return (map.values.prefix(1_000).map { depth($0, level: level + 1) }.max() ?? level) }
        if let array = object as? [Any] { return (array.prefix(1_000).map { depth($0, level: level + 1) }.max() ?? level) }
        return level
    }
    private static func matches(_ pattern: String, _ source: String) -> Int {
        (try? NSRegularExpression(pattern: pattern).numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))) ?? 0
    }
}

final class BoundedXMLCounter: NSObject, XMLParserDelegate {
    var elements = 0
    var maximumDepth = 0
    private var currentDepth = 0
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        elements += 1
        currentDepth += 1
        maximumDepth = max(maximumDepth, currentDepth)
        if elements > 100_000 || currentDepth > 128 || Task.isCancelled { parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { currentDepth -= 1 }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { parser.abortParsing() }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
}
