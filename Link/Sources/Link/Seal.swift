import CryptoKit
import Foundation

/// Every record's content, sealed on the device that wrote it before it reaches iCloud:
/// ChaChaPoly under a 256-bit key, with the record's type and name as associated data, so a box
/// lifted onto another record, or another kind of record, doesn't open.
public enum Seal {
    public struct Refused: Error, Equatable {}

    public static func seal(_ plain: Data, key: SymmetricKey, type: String, name: String) throws -> Data {
        try ChaChaPoly.seal(plain, using: key, authenticating: label(type, name)).combined
    }

    public static func open(_ box: Data, key: SymmetricKey, type: String, name: String) throws -> Data {
        do {
            return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: box), using: key, authenticating: label(type, name))
        } catch {
            throw Refused()
        }
    }

    public static func seal(_ value: some Encodable, key: SymmetricKey, type: String, name: String) throws -> Data {
        try seal(coder.encode(value), key: key, type: type, name: name)
    }

    public static func open<Value: Decodable>(_: Value.Type, from box: Data, key: SymmetricKey, type: String, name: String) throws -> Value {
        try decoder.decode(Value.self, from: open(box, key: key, type: type, name: name))
    }

    private static func label(_ type: String, _ name: String) -> Data {
        Data("\(type)/\(name)".utf8)
    }

    private static let coder: JSONEncoder = {
        let coder = JSONEncoder()
        coder.dateEncodingStrategy = .millisecondsSince1970
        return coder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}

extension SymmetricKey {
    public var data: Data { withUnsafeBytes { Data($0) } }
}
