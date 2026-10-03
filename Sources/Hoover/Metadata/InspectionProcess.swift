import Darwin
import Foundation

/// No shell, no stdin, bounded time and output, with concurrent pipe draining.
enum InspectionProcess {
    struct Result {
        let stdout: String
        let stderr: String
        let status: Int32
        let limited: Bool
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 1.5,
                    limit: Int = 131_072, environment: [String: String] = [:]) -> Result? {
        guard !Task.isCancelled, FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"].merging(environment) { _, value in value }
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let output = BoundedCapture(limit: limit), errors = BoundedCapture(limit: limit)
        let readers = DispatchGroup()
        do { try process.run() } catch { return nil }
        for (pipe, capture) in [(stdout, output), (stderr, errors)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { readers.leave() }
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    capture.append(data)
                }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var limited = false
        while process.isRunning {
            if Date() >= deadline || Task.isCancelled || output.overflow || errors.overflow {
                limited = true
                process.terminate()
                let grace = Date().addingTimeInterval(0.15)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        _ = readers.wait(timeout: .now() + 0.5)
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
        return Result(stdout: output.string, stderr: errors.string,
                      status: process.terminationStatus, limited: limited || output.overflow || errors.overflow)
    }
}

private final class BoundedCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var wasLimited = false
    init(limit: Int) { self.limit = limit }
    var overflow: Bool { lock.lock(); defer { lock.unlock() }; return wasLimited }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - data.count)
        data.append(chunk.prefix(remaining))
        if chunk.count > remaining { wasLimited = true }
    }
}
