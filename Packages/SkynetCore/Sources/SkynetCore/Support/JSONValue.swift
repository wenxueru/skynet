import Foundation

/// A self-describing JSON value, used wherever SkynetCore needs to carry
/// provider-specific payloads it does not fully model (tool arguments, raw
/// protocol frames, unhandled events).
///
/// `JSONValue` round-trips losslessly through `Codable` and preserves numeric
/// precision by keeping numbers as `String` in their textual form.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    /// Numeric literal, preserved exactly as it appeared in the source JSON.
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Literal conveniences

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(String(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(String(value)) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var object: [String: JSONValue] = [:]
        for (key, value) in elements { object[key] = value }
        self = .object(object)
    }
}

// MARK: - Accessors

extension JSONValue {
    /// The string value, if this is a string.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The boolean value, if this is a bool.
    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The integer value parsed from a number, if representable.
    public var intValue: Int? {
        if case .number(let text) = self { return Int(text) }
        return nil
    }

    /// The double value parsed from a number, if representable.
    public var doubleValue: Double? {
        if case .number(let text) = self { return Double(text) }
        return nil
    }

    /// The array elements, if this is an array.
    public var arrayValue: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    /// The object entries, if this is an object.
    public var objectValue: [String: JSONValue]? {
        if case .object(let entries) = self { return entries }
        return nil
    }

    /// Subscript access into an object; returns `nil` for non-objects and
    /// missing keys.
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Subscript access into an array; returns `nil` for non-arrays and
    /// out-of-bounds indexes.
    public subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else {
            return nil
        }
        return array[index]
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    private struct AnyCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) {
            self.intValue = intValue
            stringValue = "\(intValue)"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(NumberText.self) {
            self = .number(number.text)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let text):
            // Re-encode through the textual form so precision survives a
            // round trip.
            try container.encode(NumberText(text))
        case .string(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let entries): try container.encode(entries)
        }
    }

    /// Wrapper that decodes a JSON number while keeping its raw text.
    private struct NumberText: Codable {
        let text: String
        init(_ text: String) { self.text = text }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int.self) {
                text = String(value)
            } else if let value = try? container.decode(Double.self) {
                text = String(value)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected a JSON number"
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            if let value = Int(text) {
                try container.encode(value)
            } else if let value = Double(text) {
                try container.encode(value)
            } else {
                throw EncodingError.invalidValue(
                    text,
                    .init(
                        codingPath: encoder.codingPath,
                        debugDescription: "Number text is not a valid number"
                    )
                )
            }
        }
    }
}

// MARK: - Conversion helpers

extension JSONValue {
    /// Decodes any `Decodable` value out of this JSON value.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let encoder = JSONEncoder()
        let data = try encoder.encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Wraps any `Encodable` value into a JSON value.
    public static func wrap<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
