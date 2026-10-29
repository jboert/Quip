import Foundation

/// A JSON value that keeps object key order and number spelling, so Quip can
/// add one entry to `~/.claude/settings.json` and leave the rest of the
/// owner's file as it was (Q-87). `JSONSerialization` would reorder keys and
/// rewrite `/` as `\/`.
///
/// `serialized()` writes the format `JSON.stringify(value, null, 2)` writes,
/// which is what Claude Code itself uses for this file.
indirect enum OrderedJSON: Equatable {
    case object([(key: String, value: OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    /// The literal as written (`5`, `1.0`, `1e3`), never re-formatted.
    case number(String)
    case bool(Bool)
    case null

    static func == (a: OrderedJSON, b: OrderedJSON) -> Bool {
        switch (a, b) {
        case let (.object(x), .object(y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case let (.array(x), .array(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        case let (.bool(x), .bool(y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    subscript(key: String) -> OrderedJSON? {
        guard case let .object(pairs) = self else { return nil }
        return pairs.first { $0.key == key }?.value
    }

    /// Sets `key`, keeping its position if present, appending if not.
    mutating func set(_ key: String, _ value: OrderedJSON) {
        guard case var .object(pairs) = self else { return }
        if let i = pairs.firstIndex(where: { $0.key == key }) {
            pairs[i].value = value
        } else {
            pairs.append((key, value))
        }
        self = .object(pairs)
    }

    mutating func remove(_ key: String) {
        guard case var .object(pairs) = self else { return }
        pairs.removeAll { $0.key == key }
        self = .object(pairs)
    }

    var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    var arrayValue: [OrderedJSON]? {
        if case let .array(a) = self { return a }
        return nil
    }

    // MARK: - Writing

    func serialized(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch self {
        case let .object(pairs):
            if pairs.isEmpty { return "{}" }
            let body = pairs.map { "\(inner)\(Self.quote($0.key)): \($0.value.serialized(indent: indent + 1))" }
            return "{\n" + body.joined(separator: ",\n") + "\n\(pad)}"
        case let .array(items):
            if items.isEmpty { return "[]" }
            let body = items.map { inner + $0.serialized(indent: indent + 1) }
            return "[\n" + body.joined(separator: ",\n") + "\n\(pad)]"
        case let .string(s): return Self.quote(s)
        case let .number(n): return n
        case let .bool(b): return b ? "true" : "false"
        case .null: return "null"
        }
    }

    /// `JSON.stringify` string escaping: `"`, `\`, and control characters.
    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: - Reading

    struct ParseError: Error, Equatable { let offset: Int }

    static func parse(_ data: Data) throws -> OrderedJSON {
        var p = Parser(bytes: Array(data))
        let value = try p.value()
        p.skipSpace()
        guard p.i == p.bytes.count else { throw ParseError(offset: p.i) }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        mutating func skipSpace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        mutating func value() throws -> OrderedJSON {
            skipSpace()
            guard i < bytes.count else { throw ParseError(offset: i) }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else { throw ParseError(offset: i) }
            i += w.count
        }

        mutating func object() throws -> OrderedJSON {
            i += 1
            var pairs: [(key: String, value: OrderedJSON)] = []
            skipSpace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
            while true {
                skipSpace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw ParseError(offset: i) }
                let key = try string()
                skipSpace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw ParseError(offset: i) }
                i += 1
                pairs.append((key, try value()))
                skipSpace()
                guard i < bytes.count else { throw ParseError(offset: i) }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
                throw ParseError(offset: i)
            }
        }

        mutating func array() throws -> OrderedJSON {
            i += 1
            var items: [OrderedJSON] = []
            skipSpace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                items.append(try value())
                skipSpace()
                guard i < bytes.count else { throw ParseError(offset: i) }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw ParseError(offset: i)
            }
        }

        mutating func number() throws -> OrderedJSON {
            let start = i
            while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
            guard i > start, let text = String(bytes: bytes[start..<i], encoding: .utf8),
                  Double(text) != nil else { throw ParseError(offset: start) }
            return .number(text)
        }

        mutating func string() throws -> String {
            i += 1 // opening quote
            var scalars = String.UnicodeScalarView()
            var raw: [UInt8] = []
            func flushRaw() throws {
                guard !raw.isEmpty else { return }
                guard let s = String(bytes: raw, encoding: .utf8) else { throw ParseError(offset: i) }
                scalars.append(contentsOf: s.unicodeScalars)
                raw.removeAll()
            }
            while i < bytes.count {
                let b = bytes[i]
                if b == UInt8(ascii: "\"") {
                    try flushRaw(); i += 1
                    return String(scalars)
                }
                if b == UInt8(ascii: "\\") {
                    try flushRaw()
                    i += 1
                    guard i < bytes.count else { break }
                    let e = bytes[i]
                    i += 1
                    switch e {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        if (0xD800...0xDBFF).contains(code), i + 1 < bytes.count,
                           bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                            i += 2
                            let low = try hex4()
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let s = Unicode.Scalar(code) else { throw ParseError(offset: i) }
                        scalars.append(s)
                    default: throw ParseError(offset: i)
                    }
                    continue
                }
                raw.append(b); i += 1
            }
            throw ParseError(offset: i)
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count,
                  let s = String(bytes: bytes[i..<i + 4], encoding: .ascii),
                  let v = UInt32(s, radix: 16) else { throw ParseError(offset: i) }
            i += 4
            return v
        }
    }
}
