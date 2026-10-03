import Foundation

@main struct Stress {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("HooverStress-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let started = Date()
        for group in 0..<100 {
            let directory = root.appendingPathComponent("Branch\(group)", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            for file in 0..<1000 {
                if !fm.createFile(atPath: directory.appendingPathComponent("Item-\(group)-\(file).swift").path, contents: Data()) { fatalError("Fixture creation failed") }
            }
        }
        print("Created 100000 real files in \(String(format: "%.3f", Date().timeIntervalSince(started))) sec")
        let indexStart = Date()
        var records: [IndexRecord] = []
        var firstBatch: Double?
        var batches = 0
        for await batch in RootIndexer().stream(root: root) {
            if firstBatch == nil { firstBatch = Date().timeIntervalSince(indexStart) }
            batches += 1
            records.append(contentsOf: batch)
        }
        precondition(records.count == 100101, "Missing descendants: \(records.count)")
        let elapsed = Date().timeIntervalSince(indexStart)
        print("Indexed \(records.count) records in \(String(format: "%.3f", elapsed)) sec across \(batches) batches; first batch \(String(format: "%.4f", firstBatch!)) sec")
        for query in ["Item-99-999", "swift", "nonexistent", "Branch99"] {
            let start = Date()
            let result = TreeSearch.search(query: query, records: records)
            print("Query \(query): \(result.matches.count) matches; \(result.visibleIDs.count) visible IDs; \(String(format: "%.3f", Date().timeIntervalSince(start))) sec")
            if query == "Item-99-999" { precondition(result.matches.count == 1 && result.visibleIDs.count == 3) }
            if query == "swift" { precondition(result.matches.count == 100000) }
            if query == "nonexistent" { precondition(result.matches.isEmpty) }
            if query == "Branch99" { precondition(result.matches.count == 1 && result.visibleIDs.count == 2) }
        }
    }
}
