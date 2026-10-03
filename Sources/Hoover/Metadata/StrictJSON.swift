import Foundation

/// Foundation's Darwin JSON reader accepts some non-JSON extensions. Validate
/// the bounded source against JSON's grammar before advertising it as valid.
enum StrictJSON {
    enum Result {
        case valid(keyCount: Int, nestingDepth: Int)
        case invalid
        case limited
    }

    static func validate(_ source: String) -> Result {
        guard source.utf8.count <= MetadataInspector.textLimit else { return .limited }
        var scanner = Scanner(bytes: Array(source.utf8))
        do {
            // RFC 8259 permits parsers to ignore a leading byte-order mark.
            if scanner.bytes.starts(with: [0xef, 0xbb, 0xbf]) { scanner.position = 3 }
            try scanner.value(depth: 0)
            scanner.whitespace()
            guard scanner.position == scanner.bytes.count else { return .invalid }
            return .valid(keyCount: scanner.keys, nestingDepth: scanner.maximumDepth)
        } catch Failure.limited { return .limited }
        catch { return .invalid }
    }

    private enum Failure: Error { case invalid, limited }

    private struct Scanner {
        let bytes: [UInt8]
        var position = 0
        var keys = 0
        var maximumDepth = 0

        mutating func value(depth: Int) throws {
            guard !Task.isCancelled else { throw Failure.limited }
            whitespace()
            guard position < bytes.count else { throw Failure.invalid }
            switch bytes[position] {
            case 123: try object(depth: depth + 1) // {
            case 91: try array(depth: depth + 1) // [
            case 34: try string()
            case 116: try literal("true")
            case 102: try literal("false")
            case 110: try literal("null")
            case 45, 48...57: try number()
            default: throw Failure.invalid
            }
        }

        mutating func object(depth: Int) throws {
            try enter(depth)
            position += 1
            whitespace()
            if take(125) { return }
            while true {
                // Require a key after each comma, including the final comma.
                try string()
                keys += 1
                whitespace()
                guard take(58) else { throw Failure.invalid }
                try value(depth: depth)
                whitespace()
                if take(125) { return }
                guard take(44) else { throw Failure.invalid }
                whitespace()
            }
        }

        mutating func array(depth: Int) throws {
            try enter(depth)
            position += 1
            whitespace()
            if take(93) { return }
            while true {
                try value(depth: depth)
                whitespace()
                if take(93) { return }
                guard take(44) else { throw Failure.invalid }
            }
        }

        mutating func enter(_ depth: Int) throws {
            guard depth <= 64 else { throw Failure.limited }
            maximumDepth = max(maximumDepth, depth)
        }

        mutating func string() throws {
            guard take(34) else { throw Failure.invalid }
            while position < bytes.count {
                let byte = bytes[position]
                position += 1
                if byte == 34 { return }
                guard byte >= 0x20 else { throw Failure.invalid }
                if byte == 92 {
                    guard position < bytes.count else { throw Failure.invalid }
                    let escaped = bytes[position]
                    position += 1
                    if escaped == 117 {
                        for _ in 0..<4 {
                            guard position < bytes.count else { throw Failure.invalid }
                            let digit = bytes[position]
                            guard (48...57).contains(digit) || (65...70).contains(digit) || (97...102).contains(digit) else { throw Failure.invalid }
                            position += 1
                        }
                    } else if ![34, 92, 47, 98, 102, 110, 114, 116].contains(escaped) { throw Failure.invalid }
                }
            }
            throw Failure.invalid
        }

        mutating func number() throws {
            _ = take(45)
            guard position < bytes.count else { throw Failure.invalid }
            if take(48) {
                // A further digit is rejected by the enclosing separator check.
            } else {
                guard (49...57).contains(bytes[position]) else { throw Failure.invalid }
                digits()
            }
            if take(46) {
                guard position < bytes.count, (48...57).contains(bytes[position]) else { throw Failure.invalid }
                digits()
            }
            if take(101) || take(69) {
                if !take(43) { _ = take(45) }
                guard position < bytes.count, (48...57).contains(bytes[position]) else { throw Failure.invalid }
                digits()
            }
        }

        mutating func digits() {
            while position < bytes.count, (48...57).contains(bytes[position]) { position += 1 }
        }

        mutating func literal(_ string: String) throws {
            for byte in string.utf8 {
                guard take(byte) else { throw Failure.invalid }
            }
        }

        mutating func whitespace() {
            while position < bytes.count, [9, 10, 13, 32].contains(bytes[position]) { position += 1 }
        }

        mutating func take(_ byte: UInt8) -> Bool {
            guard position < bytes.count, bytes[position] == byte else { return false }
            position += 1
            return true
        }
    }
}
