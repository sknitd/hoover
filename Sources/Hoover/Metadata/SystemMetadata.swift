import Foundation
import SQLite3

enum SystemMetadata {
    static func git(_ url: URL) -> [MetadataSection] {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let directory = isDirectory ? url : url.deletingLastPathComponent()
        var ancestor = directory
        var hasRepository = false
        for _ in 0..<64 {
            if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) { hasRepository = true; break }
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { break }
            ancestor = parent
        }
        guard hasRepository else { return [] }
        guard let git = developerExecutable("git") else {
            return [MetadataInspector.section("Git", [("Status", "Developer tools are unavailable; Git inspection was skipped.")])]
        }
        // Disable config-provided fsmonitor executables and Git's optional writes.
        let prefix = ["-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-C", directory.path]
        let environment = ["GIT_OPTIONAL_LOCKS": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"]
        guard let root = InspectionProcess.run(git, prefix + ["rev-parse", "--show-toplevel"], timeout: 0.5, environment: environment), root.status == 0, !root.limited else { return [] }
        var fields = [("Repository", root.stdout.trimmingCharacters(in: .whitespacesAndNewlines))]
        if let branch = InspectionProcess.run(git, prefix + ["symbolic-ref", "--short", "HEAD"], timeout: 0.5, environment: environment), branch.status == 0 {
            fields.append(("Branch", branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        } else { fields.append(("Branch", "Detached HEAD or unborn branch")) }
        let statusArgs = prefix + ["status", "--porcelain=v1", isDirectory ? "--untracked-files=no" : "--untracked-files=normal", "--"] + (isDirectory ? [] : [url.path])
        if let status = InspectionProcess.run(git, statusArgs, timeout: 0.7, environment: environment), status.status == 0, !status.limited {
            let changes = status.stdout.components(separatedBy: .newlines).filter { !$0.isEmpty }
            fields.append((isDirectory ? "Tracked changes" : "File changes", changes.isEmpty ? "Clean" : "\(changes.count) changed item\(changes.count == 1 ? "" : "s")"))
            if !isDirectory, let first = changes.first { fields.append(("File status", String(first.prefix(2)).trimmingCharacters(in: .whitespaces))) }
        } else { fields.append(("Status", "Not inspected within the hover time limit")) }
        if isDirectory, let log = InspectionProcess.run(git, prefix + ["log", "-1", "--format=%h · %s"], timeout: 0.5, limit: 4_096, environment: environment), log.status == 0 {
            fields.append(("Last commit", log.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if isDirectory, let remote = InspectionProcess.run(git, prefix + ["remote", "get-url", "origin"], timeout: 0.5, limit: 4_096, environment: environment), remote.status == 0 {
            fields.append(("Origin", MetadataInspector.redactCredentials(remote.stdout.trimmingCharacters(in: .whitespacesAndNewlines))))
        }
        return [MetadataInspector.section("Git", fields)]
    }

    static func bundleAndProject(_ url: URL) -> [MetadataSection] {
        let ext = url.pathExtension.lowercased()
        if ext == "app" {
            let infoURL = url.appendingPathComponent("Contents/Info.plist")
            guard let data = MetadataInspector.boundedData(infoURL), let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
            let labels = [("CFBundleIdentifier", "Bundle ID"), ("CFBundleShortVersionString", "Version"), ("CFBundleVersion", "Build"), ("LSMinimumSystemVersion", "Minimum macOS"), ("LSApplicationCategoryType", "Category"), ("NSHumanReadableCopyright", "Copyright")]
            var fields = [(String, String)]()
            for (key, label) in labels { if let value = plist[key] as? String { fields.append((label, value)) } }
            let signing = signature(url)
            fields += signing
            var sections = [MetadataInspector.section("Application", fields)]
            if let executable = plist["CFBundleExecutable"] as? String, !executable.contains("/"), executable != ".", executable != ".." {
                let binaryURL = url.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
                if let attributes = try? binaryURL.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]), attributes.isSymbolicLink != true, Int64(attributes.fileSize ?? Int.max) <= MetadataInspector.contentLimit { sections += binary(binaryURL) }
            }
            return sections
        }
        if ext == "xcodeproj" {
            guard let data = MetadataInspector.boundedData(url.appendingPathComponent("project.pbxproj")), let source = String(data: data, encoding: .utf8) else { return [] }
            var fields = [("Project", url.deletingPathExtension().lastPathComponent),
                          ("Targets inspected", String(source.components(separatedBy: "isa = PBXNativeTarget").count - 1)),
                          ("Configurations inspected", String(source.components(separatedBy: "isa = XCBuildConfiguration").count - 1))]
            for (key, label) in [("SWIFT_VERSION", "Swift"), ("MACOSX_DEPLOYMENT_TARGET", "Minimum macOS"), ("IPHONEOS_DEPLOYMENT_TARGET", "Minimum iOS"), ("ORGANIZATIONNAME", "Organization")] {
                if let value = value(key, source: source) { fields.append((label, value)) }
            }
            fields.append(("Inspection", "First 256 KB; observed counts may be partial."))
            return [MetadataInspector.section("Xcode project", fields)]
        }
        if ext == "xcworkspace", let data = MetadataInspector.boundedData(url.appendingPathComponent("contents.xcworkspacedata")), let source = String(data: data, encoding: .utf8) {
            return [MetadataInspector.section("Xcode workspace", [("Workspace", url.deletingPathExtension().lastPathComponent), ("Project references inspected", String(source.components(separatedBy: "<FileRef").count - 1))])]
        }
        let package = url.appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: package.path), let data = MetadataInspector.boundedData(package), let source = String(data: data, encoding: .utf8) {
            let first = source.components(separatedBy: .newlines).first ?? ""
            return [MetadataInspector.section("Swift package", [("Manifest", "Package.swift"), ("Tools declaration", first)])]
        }
        return []
    }

    static func binary(_ url: URL) -> [MetadataSection] {
        guard !Task.isCancelled, let header = MetadataInspector.boundedData(url, limit: 4), header.count == 4 else { return [] }
        let bytes = Array(header)
        let magics: [[UInt8]] = [[0xFE,0xED,0xFA,0xCE],[0xCE,0xFA,0xED,0xFE],[0xFE,0xED,0xFA,0xCF],[0xCF,0xFA,0xED,0xFE],[0xCA,0xFE,0xBA,0xBE],[0xBE,0xBA,0xFE,0xCA],[0xCA,0xFE,0xBA,0xBF],[0xBF,0xBA,0xFE,0xCA]]
        guard magics.contains(bytes), let file = InspectionProcess.run("/usr/bin/file", ["-b", url.path], timeout: 0.5), file.status == 0, file.stdout.contains("Mach-O") else { return [] }
        var fields = [("Executable type / architecture", file.stdout.trimmingCharacters(in: .whitespacesAndNewlines))]
        fields += signature(url)
        if let otool = developerExecutable("otool"), let load = InspectionProcess.run(otool, ["-l", url.path], timeout: 0.7), load.status == 0 {
            for (key, label) in [("minos", "Minimum OS"), ("sdk", "SDK"), ("version", "Minimum OS (legacy)")] {
                if let regex = try? NSRegularExpression(pattern: "(?m)^\\s*\(key)\\s+([0-9.]+)\\s*$"), let match = regex.firstMatch(in: load.stdout, range: NSRange(load.stdout.startIndex..., in: load.stdout)), let range = Range(match.range(at: 1), in: load.stdout) { fields.append((label, String(load.stdout[range]))) }
            }
        }
        return [MetadataInspector.section("Mach-O", fields)]
    }

    private static func signature(_ url: URL) -> [(String, String)] {
        guard let signing = InspectionProcess.run("/usr/bin/codesign", ["--display", "--verbose=2", url.path], timeout: 0.7, limit: 16_384) else { return [] }
        guard signing.status == 0 else { return [("Code signature", "Absent or unreadable")] }
        let details = signing.stdout + "\n" + signing.stderr
        var fields = [("Code signature", details.contains("Signature=adhoc") ? "Ad hoc signature" : "Present (trust not verified)")]
        for key in ["Authority", "TeamIdentifier", "Identifier"] {
            let matches = details.components(separatedBy: .newlines).filter { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
            if !matches.isEmpty { fields.append((key, matches.joined(separator: " · "))) }
        }
        if let entitlements = InspectionProcess.run("/usr/bin/codesign", ["--display", "--entitlements", "-", url.path], timeout: 0.7, limit: 32_768), entitlements.status == 0, !entitlements.limited {
            let data = Data(entitlements.stdout.utf8)
            if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], !plist.isEmpty { fields.append(("Entitlements", plist.keys.sorted().prefix(25).joined(separator: ", "))) }
        }
        return fields
    }

    static func sqlite(_ url: URL) -> [MetadataSection] {
        guard let header = MetadataInspector.boundedData(url, limit: 16), String(data: header, encoding: .utf8)?.hasPrefix("SQLite format 3") == true else { return [] }
        var database: OpaquePointer?
        // immutable=1 prevents creation or mutation of WAL/SHM files during inspection.
        let uri = url.absoluteString + "?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return [MetadataInspector.section("SQLite", [("Status", "Read-only database inspection unavailable")])]
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 50)
        let budget = SQLiteBudget(deadline: Date().addingTimeInterval(0.4))
        let context = Unmanaged.passUnretained(budget).toOpaque()
        sqlite3_progress_handler(database, 500, { context in
            guard let context else { return 1 }
            return Date() >= Unmanaged<SQLiteBudget>.fromOpaque(context).takeUnretainedValue().deadline || Task.isCancelled ? 1 : 0
        }, context)
        var fields = [(String, String)]()
        let queries = [("Tables", "SELECT count(*) FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'"),
            ("Indexes", "SELECT count(*) FROM sqlite_schema WHERE type='index'"),
            ("Triggers", "SELECT count(*) FROM sqlite_schema WHERE type='trigger'"),
            ("Views", "SELECT count(*) FROM sqlite_schema WHERE type='view'"),
            ("Schema version", "PRAGMA schema_version"), ("Encoding", "PRAGMA encoding"), ("Page size", "PRAGMA page_size")]
        for (label, sql) in queries {
            guard !Task.isCancelled, Date() < budget.deadline else { break }
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement {
                if sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) { fields.append((label, String(cString: text))) }
            }
            if let statement { sqlite3_finalize(statement) }
        }
        let wal = FileManager.default.fileExists(atPath: url.path + "-wal")
        fields.append(("Inspection", wal ? "Immutable file snapshot; pending WAL changes are not included." : "Read-only immutable snapshot; no row scans or sidecar writes."))
        return [MetadataInspector.section("SQLite", fields)]
    }

    private static func value(_ key: String, source: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\\b\(key)\\s*=\\s*([^;]+);"), let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), let range = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\" \t\n"))
    }

    /// Avoid Apple's /usr/bin Git/otool launcher prompting to install developer tools.
    private static func developerExecutable(_ name: String) -> String? {
        let commandLine = "/Library/Developer/CommandLineTools/usr/bin/" + name
        if FileManager.default.isExecutableFile(atPath: commandLine) { return commandLine }
        if let selection = InspectionProcess.run("/usr/bin/xcode-select", ["--print-path"], timeout: 0.3), selection.status == 0, !selection.limited {
            let root = selection.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = URL(fileURLWithPath: root).appendingPathComponent("usr/bin").appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

private final class SQLiteBudget {
    let deadline: Date
    init(deadline: Date) { self.deadline = deadline }
}
