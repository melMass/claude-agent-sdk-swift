import Foundation

/// Checks tool arguments against a tool's JSON Schema before its handler runs.
///
/// Covers the keywords tool schemas use: `type` (one or several), `properties`,
/// `required`, `additionalProperties`, `items`, `enum`, `const`, `anyOf`,
/// `oneOf`, `allOf`, `not`, numeric bounds, string and array lengths, and
/// `pattern`. Keywords it does not know are ignored, as JSON Schema prescribes.
enum JSONSchemaValidator {
    /// The first violation found, as a message, or nil when `value` conforms.
    static func firstError(_ value: JSONValue, schema: JSONValue, path: String = "") -> String? {
        guard case let .object(schema) = schema else { return nil }

        if let types = schema["type"] {
            let names = types.array?.compactMap(\.string) ?? [types.string].compactMap { $0 }
            if !names.isEmpty, !names.contains(where: { matches(value, type: $0) }) {
                return "\(describe(value)) is not of type \(names.map { "'\($0)'" }.joined(separator: ", "))\(at(path))"
            }
        }
        if let options = schema["enum"]?.array, !options.contains(where: { equal($0, value) }) {
            return "\(describe(value)) is not one of \(JSONValue.array(options).jsonString)\(at(path))"
        }
        if let constant = schema["const"], !equal(constant, value) {
            return "\(constant.jsonString) was expected\(at(path))"
        }
        if let all = schema["allOf"]?.array {
            for sub in all { if let error = firstError(value, schema: sub, path: path) { return error } }
        }
        if let any = schema["anyOf"]?.array, !any.contains(where: { firstError(value, schema: $0, path: path) == nil }) {
            return "\(describe(value)) is not valid under any of the given schemas\(at(path))"
        }
        if let one = schema["oneOf"]?.array {
            let passing = one.filter { firstError(value, schema: $0, path: path) == nil }.count
            if passing != 1 { return "\(describe(value)) is not valid under exactly one of the given schemas\(at(path))" }
        }
        if let not = schema["not"], firstError(value, schema: not, path: path) == nil {
            return "\(describe(value)) should not be valid under \(not.jsonString)\(at(path))"
        }

        switch value {
        case let .object(object):
            for name in schema["required"]?.array?.compactMap(\.string) ?? [] where object[name] == nil {
                return "'\(name)' is a required property\(at(path))"
            }
            let properties = schema["properties"]?.object ?? [:]
            for (key, member) in object.sorted(by: { $0.key < $1.key }) {
                let child = path.isEmpty ? key : "\(path).\(key)"
                if let sub = properties[key] {
                    if let error = firstError(member, schema: sub, path: child) { return error }
                } else if let additional = schema["additionalProperties"] {
                    if additional == .bool(false) {
                        return "Additional properties are not allowed ('\(key)' was unexpected)\(at(path))"
                    }
                    if let error = firstError(member, schema: additional, path: child) { return error }
                }
            }
        case let .array(items):
            if let min = schema["minItems"]?.int, items.count < min { return "\(describe(value)) is too short\(at(path))" }
            if let max = schema["maxItems"]?.int, items.count > max { return "\(describe(value)) is too long\(at(path))" }
            if let itemSchema = schema["items"], itemSchema.object != nil {
                for (index, item) in items.enumerated() {
                    if let error = firstError(item, schema: itemSchema, path: "\(path)[\(index)]") { return error }
                }
            }
        case let .string(text):
            if let min = schema["minLength"]?.int, text.count < min { return "\(describe(value)) is too short\(at(path))" }
            if let max = schema["maxLength"]?.int, text.count > max { return "\(describe(value)) is too long\(at(path))" }
            if let pattern = schema["pattern"]?.string, text.range(of: pattern, options: .regularExpression) == nil {
                return "\(describe(value)) does not match '\(pattern)'\(at(path))"
            }
        case .int, .double:
            let number = value.double ?? 0
            if let min = schema["minimum"]?.double, number < min {
                return "\(describe(value)) is less than the minimum of \(min)\(at(path))"
            }
            if let max = schema["maximum"]?.double, number > max {
                return "\(describe(value)) is greater than the maximum of \(max)\(at(path))"
            }
            if let min = schema["exclusiveMinimum"]?.double, number <= min {
                return "\(describe(value)) is less than or equal to the minimum of \(min)\(at(path))"
            }
            if let max = schema["exclusiveMaximum"]?.double, number >= max {
                return "\(describe(value)) is greater than or equal to the maximum of \(max)\(at(path))"
            }
        default:
            break
        }
        return nil
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("array", .array), ("object", .object): true
        case ("number", .int), ("number", .double): true
        case ("integer", .int): true
        case let ("integer", .double(number)): number.rounded() == number
        default: false
        }
    }

    /// Numbers compare by value, so `1` equals `1.0`.
    private static func equal(_ a: JSONValue, _ b: JSONValue) -> Bool {
        if let x = a.double, let y = b.double, a.bool == nil, b.bool == nil { return x == y }
        return a == b
    }

    private static func describe(_ value: JSONValue) -> String {
        if case let .string(text) = value { return "'\(text)'" }
        return value.jsonString
    }

    private static func at(_ path: String) -> String {
        path.isEmpty ? "" : " (at '\(path)')"
    }
}
