import Foundation

/// Untyped JSON, for the wire and for event payloads stored as-is.
enum JSON: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSON? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    var double: Double? {
        if case .number(let value) = self { value } else { nil }
    }

    var int: Int? { double.map { Int($0) } }

    var bool: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    var array: [JSON]? {
        if case .array(let value) = self { value } else { nil }
    }

    var object: [String: JSON]? {
        if case .object(let value) = self { value } else { nil }
    }

    func data() throws -> Data {
        try JSONEncoder().encode(self)
    }

    func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: data())
    }

    static func from<T: Encodable>(_ value: T) throws -> JSON {
        try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(value))
    }
}

extension JSON: ExpressibleByDictionaryLiteral, ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByArrayLiteral, ExpressibleByNilLiteral
{
    init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }

    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(nilLiteral: ()) { self = .null }

    init(_ value: String?) {
        self = value.map(JSON.string) ?? .null
    }
}
