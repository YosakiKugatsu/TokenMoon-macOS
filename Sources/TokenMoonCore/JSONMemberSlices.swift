// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Indexes the values of a UTF-8 JSON container without materializing its contents.
/// All ranges are byte offsets relative to the supplied Data's first byte.
public enum JSONMemberSlices {
    public static func members(in data: Data, range: Range<Int>? = nil) throws -> [String: Range<Int>] {
        let bounds = try checkedRange(range, count: data.count)
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var parser = Parser(bytes: raw, range: bounds)
            return try parser.members()
        }
    }

    /// Delivers one element's bounds at a time, keeping the array index itself out of memory.
    /// A later syntax error can invalidate the whole array; commit results only after this returns.
    public static func forEachElement(
        in data: Data, range: Range<Int>? = nil, _ body: (Range<Int>) throws -> Void
    ) throws {
        let bounds = try checkedRange(range, count: data.count)
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var parser = Parser(bytes: raw, range: bounds)
            try parser.elements(body)
        }
    }

    /// Returns an owning Data view. Its storage remains valid after the original Data is released.
    public static func slice(in data: Data, range: Range<Int>) throws -> Data {
        let bounds = try checkedRange(range, count: data.count)
        return data[(data.startIndex + bounds.lowerBound)..<(data.startIndex + bounds.upperBound)]
    }

    private static func checkedRange(_ range: Range<Int>?, count: Int) throws -> Range<Int> {
        let range = range ?? 0..<count
        guard range.lowerBound >= 0, range.upperBound <= count else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "JSON slice is outside the document"))
        }
        return range
    }

    private struct Parser {
        let bytes: UnsafeRawBufferPointer
        let end: Int
        var cursor: Int
        private static let maxDepth = 512

        init(bytes: UnsafeRawBufferPointer, range: Range<Int>) {
            self.bytes = bytes
            self.cursor = range.lowerBound
            self.end = range.upperBound
            // JSONEncoder emits UTF-8 without a BOM; tolerate one in a complete document.
            if range.lowerBound == 0, end >= 3, bytes[0] == 0xef, bytes[1] == 0xbb, bytes[2] == 0xbf {
                cursor = 3
            }
        }

        mutating func members() throws -> [String: Range<Int>] {
            whitespace()
            try require(0x7b) // {
            var result: [String: Range<Int>] = [:]
            whitespace()
            if !consume(0x7d) { // }
                repeat {
                    let opening = cursor
                    try require(0x22) // "
                    let escaped = try stringTail()
                    let key: String
                    if escaped {
                        key = try JSONDecoder().decode(String.self, from: Data(bytes[opening..<cursor]))
                    } else {
                        key = String(decoding: bytes[(opening + 1)..<(cursor - 1)], as: UTF8.self)
                    }
                    whitespace()
                    try require(0x3a) // :
                    whitespace()
                    let start = cursor
                    try value(depth: 1)
                    guard result.updateValue(start..<cursor, forKey: key) == nil else { throw invalid("Duplicate JSON member") }
                    whitespace()
                    guard consume(0x2c) else { break } // ,
                    whitespace()
                } while true
                try require(0x7d)
            }
            try finish()
            return result
        }

        mutating func elements(_ body: (Range<Int>) throws -> Void) throws {
            whitespace()
            try require(0x5b) // [
            whitespace()
            if !consume(0x5d) { // ]
                repeat {
                    let start = cursor
                    try value(depth: 1)
                    let range = start..<cursor
                    whitespace()
                    if !consume(0x2c) { // ,
                        try require(0x5d)
                        try finish()
                        try body(range)
                        return
                    }
                    try body(range)
                    whitespace()
                } while true
            }
            try finish()
        }

        // The callers already skipped leading whitespace. On success the cursor
        // ends immediately after the value, excluding separators and whitespace.
        private mutating func value(depth: Int) throws {
            guard cursor < end else { throw invalid("Expected a JSON value") }
            switch bytes[cursor] {
            case 0x22:
                cursor += 1
                _ = try stringTail()
            case 0x7b: // {
                guard depth < Self.maxDepth else { throw invalid("JSON nesting is too deep") }
                cursor += 1
                whitespace()
                if consume(0x7d) { return }
                repeat {
                    try require(0x22)
                    _ = try stringTail()
                    whitespace()
                    try require(0x3a)
                    whitespace()
                    try value(depth: depth + 1)
                    whitespace()
                    guard consume(0x2c) else { break }
                    whitespace()
                } while true
                try require(0x7d)
            case 0x5b: // [
                guard depth < Self.maxDepth else { throw invalid("JSON nesting is too deep") }
                cursor += 1
                whitespace()
                if consume(0x5d) { return }
                repeat {
                    try value(depth: depth + 1)
                    whitespace()
                    guard consume(0x2c) else { break }
                    whitespace()
                } while true
                try require(0x5d)
            case 0x2d, 0x30...0x39:
                try number()
            case 0x74: try literal("true")
            case 0x66: try literal("false")
            case 0x6e: try literal("null")
            default: throw invalid("Expected a JSON value")
            }
        }

        private mutating func stringTail() throws -> Bool {
            var escaped = false
            while cursor < end {
                let byte = bytes[cursor]
                cursor += 1
                switch byte {
                case 0x22: return escaped
                case 0x5c: // backslash
                    escaped = true
                    guard cursor < end else { throw invalid("Incomplete JSON escape") }
                    let escape = bytes[cursor]
                    cursor += 1
                    switch escape {
                    case 0x22, 0x5c, 0x2f, 0x62, 0x66, 0x6e, 0x72, 0x74: break
                    case 0x75: // u
                        let first = try hexQuad()
                        if (0xd800...0xdbff).contains(first) {
                            try require(0x5c)
                            try require(0x75)
                            guard (0xdc00...0xdfff).contains(try hexQuad()) else { throw invalid("Invalid JSON surrogate pair") }
                        } else if (0xdc00...0xdfff).contains(first) {
                            throw invalid("Invalid JSON surrogate pair")
                        }
                    default: throw invalid("Invalid JSON escape")
                    }
                case 0x00...0x1f: throw invalid("Unescaped control character in JSON string")
                case 0x80...0xff: try utf8Tail(after: byte)
                default: break
                }
            }
            throw invalid("Unterminated JSON string")
        }

        private mutating func utf8Tail(after first: UInt8) throws {
            let count: Int
            let next: ClosedRange<UInt8>
            switch first {
            case 0xc2...0xdf: (count, next) = (1, 0x80...0xbf)
            case 0xe0: (count, next) = (2, 0xa0...0xbf)
            case 0xe1...0xec, 0xee...0xef: (count, next) = (2, 0x80...0xbf)
            case 0xed: (count, next) = (2, 0x80...0x9f)
            case 0xf0: (count, next) = (3, 0x90...0xbf)
            case 0xf1...0xf3: (count, next) = (3, 0x80...0xbf)
            case 0xf4: (count, next) = (3, 0x80...0x8f)
            default: throw invalid("Invalid UTF-8 in JSON string")
            }
            guard end - cursor >= count, next.contains(bytes[cursor]) else { throw invalid("Invalid UTF-8 in JSON string") }
            cursor += 1
            for _ in 1..<count {
                guard (0x80...0xbf).contains(bytes[cursor]) else { throw invalid("Invalid UTF-8 in JSON string") }
                cursor += 1
            }
        }

        private mutating func hexQuad() throws -> UInt16 {
            guard end - cursor >= 4 else { throw invalid("Incomplete JSON Unicode escape") }
            var value: UInt16 = 0
            for _ in 0..<4 {
                let digit: UInt8
                switch bytes[cursor] {
                case 0x30...0x39: digit = bytes[cursor] - 0x30
                case 0x41...0x46: digit = bytes[cursor] - 0x41 + 10
                case 0x61...0x66: digit = bytes[cursor] - 0x61 + 10
                default: throw invalid("Invalid JSON Unicode escape")
                }
                value = (value << 4) | UInt16(digit)
                cursor += 1
            }
            return value
        }

        private mutating func number() throws {
            _ = consume(0x2d)
            if !consume(0x30) { try digits() }
            if consume(0x2e) { try digits() }
            if consume(0x65) || consume(0x45) {
                if !consume(0x2b) { _ = consume(0x2d) }
                try digits()
            }
        }

        private mutating func digits() throws {
            let start = cursor
            while cursor < end, (0x30...0x39).contains(bytes[cursor]) { cursor += 1 }
            guard cursor > start else { throw invalid("Invalid JSON number") }
        }

        private mutating func literal(_ expected: StaticString) throws {
            let matches = expected.withUTF8Buffer { value in
                guard end - cursor >= value.count else { return false }
                return value.indices.allSatisfy { bytes[cursor + $0] == value[$0] }
            }
            guard matches else { throw invalid("Invalid JSON literal") }
            cursor += expected.utf8CodeUnitCount
        }

        private mutating func whitespace() {
            while cursor < end {
                switch bytes[cursor] {
                case 0x20, 0x09, 0x0a, 0x0d: cursor += 1
                default: return
                }
            }
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard cursor < end, bytes[cursor] == byte else { return false }
            cursor += 1
            return true
        }

        private mutating func require(_ byte: UInt8) throws {
            guard consume(byte) else { throw invalid("Unexpected JSON token") }
        }

        private mutating func finish() throws {
            whitespace()
            guard cursor == end else { throw invalid("Unexpected trailing JSON bytes") }
        }

        private func invalid(_ message: String) -> DecodingError {
            .dataCorrupted(.init(codingPath: [], debugDescription: "\(message) at byte \(cursor)"))
        }
    }
}
