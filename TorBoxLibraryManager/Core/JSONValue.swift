import Foundation

/// A JSON value that round-trips unknown keys untouched. Override entries are kept as
/// `JSONObject` so every key the Kodi addon (or a later version of it) writes survives.
/// Numbers compare like Python: `25 == 25.0`.
enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

typealias JSONObject = [String: JSONValue]

extension JSONValue: Hashable {
    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)): return a == b
        default:
            if let a = lhs.numberValue, let b = rhs.numberValue { return a == b }
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .bool(let value): hasher.combine(value)
        case .int(let value): hasher.combine(Double(value))
        case .double(let value): hasher.combine(value)
        case .string(let value): hasher.combine(value)
        case .array(let value): hasher.combine(value)
        case .object(let value): hasher.combine(value)
        }
    }
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue {
    var numberValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var objectValue: JSONObject? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Python truthiness: None, False, 0, "", [] and {} are false.
    var isTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let value): return value
        case .int(let value): return value != 0
        case .double(let value): return value != 0
        case .string(let value): return !value.isEmpty
        case .array(let value): return !value.isEmpty
        case .object(let value): return !value.isEmpty
        }
    }

    /// Python `str(value)`.
    var pythonString: String {
        switch self {
        case .null: return "None"
        case .bool(let value): return value ? "True" : "False"
        case .int(let value): return String(value)
        case .double(let value):
            if value == value.rounded(), abs(value) < 1e16 { return String(format: "%.1f", value) }
            return String(value)
        case .string(let value): return value
        case .array, .object:
            let data = (try? JSONEncoder().encode(self)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Python `int(value)`, or nil where Python would raise.
    var pythonInt: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value):
            guard value.isFinite, abs(value) < 9.2e18 else { return nil }
            return Int(value)
        case .bool(let value): return value ? 1 : 0
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let digits = trimmed.replacingOccurrences(of: "_", with: "")
            return Int(digits)
        default: return nil
        }
    }

    /// Python `float(value)`, or nil where Python would raise.
    var pythonDouble: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        case .bool(let value): return value ? 1 : 0
        case .string(let value): return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }
}

/// Python-style helpers used by the sync code (ports of `_text`, `_int`, ...).
enum Py {
    /// `_text`: the trimmed string, or nil when empty / missing.
    static func text(_ value: JSONValue?) -> String? {
        guard let value, !value.isNull else { return nil }
        let text = value.pythonString.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func int(_ value: JSONValue?) -> Int? {
        guard let value else { return nil }
        return value.pythonInt
    }

    static func truthy(_ value: JSONValue?) -> Bool {
        value?.isTruthy ?? false
    }

    static func string(_ value: String?) -> JSONValue {
        value.map(JSONValue.string) ?? .null
    }

    static func number(_ value: Int?) -> JSONValue {
        value.map(JSONValue.int) ?? .null
    }

    static func number(_ value: Double?) -> JSONValue {
        value.map(JSONValue.double) ?? .null
    }
}

enum JSONCoding {
    static func decodeObject(_ data: Data) throws -> JSONObject {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let object = value.objectValue else { throw CocoaError(.coderReadCorrupt) }
        return object
    }

    static func encode(_ value: JSONValue, pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
