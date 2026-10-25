import Foundation

/// Any JSON value: what the CLI sends and receives on the wire, kept losslessly
/// so fields this SDK does not model stay readable.
///
/// Integers and floating-point numbers are kept apart (`.int` / `.double`), so
/// ids and token counts round-trip exactly. Literals build values directly:
///
/// ```swift
/// let schema: JSONValue = ["type": "object", "properties": ["a": ["type": "number"]]]
/// ```
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Accessors

extension JSONValue {
    /// The member named `key` when this is an object, else nil.
    public subscript(key: String) -> JSONValue? {
        get {
            if case let .object(object) = self { return object[key] }
            return nil
        }
        set {
            guard case var .object(object) = self else { return }
            object[key] = newValue
            self = .object(object)
        }
    }

    /// The element at `index` when this is an array and the index is in range, else nil.
    public subscript(index: Int) -> JSONValue? {
        guard case let .array(array) = self, array.indices.contains(index) else { return nil }
        return array[index]
    }

    public var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    /// The value as an integer: an `.int`, or a `.double` with no fractional part.
    public var int: Int? {
        switch self {
        case let .int(value): return value
        case let .double(value) where value.rounded() == value && abs(value) < 9.0e15: return Int(value)
        default: return nil
        }
    }

    /// The value as a floating-point number: a `.double` or an `.int`.
    public var double: Double? {
        switch self {
        case let .double(value): return value
        case let .int(value): return Double(value)
        default: return nil
        }
    }

    public var array: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// The value, or nil when it is `.null`.
    var nonNull: JSONValue? { isNull ? nil : self }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSONValue {
    /// A string value, or `.null` for nil.
    public init(_ value: String?) { self = value.map(JSONValue.string) ?? .null }
    /// An array of strings.
    public init(_ values: [String]) { self = .array(values.map(JSONValue.string)) }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
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
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

// MARK: - Serialization

extension JSONValue {
    /// Parses one JSON document.
    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// A value `JSONSerialization` made, for bulk reads such as transcripts
    /// (hundreds of MB), where it is about five times faster than `JSONDecoder`.
    /// Its numbers are `NSNumber`s: a
    /// boolean is the `CFBoolean` singleton, and an integer is any number
    /// that is not a floating-point type.
    init(foundation value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if !CFNumberIsFloatType(number), let int = Int(exactly: number.int64Value), number.compare(NSNumber(value: int)) == .orderedSame {
                self = .int(int)
            } else {
                self = .double(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = try .array(array.map(JSONValue.init(foundation:)))
        case let object as [String: Any]:
            self = try .object(object.mapValues(JSONValue.init(foundation:)))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Not a JSON value: \(type(of: value))"))
        }
    }

    /// Parses one JSON document from text.
    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    /// The value as compact JSON with sorted keys.
    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// The value as compact JSON text with sorted keys.
    public var jsonString: String {
        (try? data()).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    /// Converts any `Encodable` value to JSON.
    public init<T: Encodable>(encoding value: T) throws {
        let encoder = JSONEncoder()
        self = try JSONValue.parse(encoder.encode(value))
    }

    /// Decodes this JSON into a `Decodable` type.
    public func decode<T: Decodable>(as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: data())
    }
}

extension JSONValue {
    /// A compact JSON object with its keys in the given order. The CLI's own
    /// transcript lines start with `"type"`, and readers scanning raw lines
    /// (e.g. for `{"type":"tag"`) rely on that.
    static func orderedObject(_ members: KeyValuePairs<String, JSONValue>) -> String {
        "{" + members.map { "\(JSONValue.string($0.key).jsonString):\($0.value.jsonString)" }.joined(separator: ",") + "}"
    }
}

extension JSONValue: CustomStringConvertible {
    public var description: String { jsonString }
}

// MARK: - Building objects

extension Dictionary where Key == String, Value == JSONValue {
    /// Sets `key` only when `value` is non-nil.
    mutating func set(_ key: String, _ value: JSONValue?) {
        if let value { self[key] = value }
    }
}
