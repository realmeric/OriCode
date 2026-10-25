import CloudKit
import CryptoKit
import Foundation

public enum Container {
    public static let identifier = "iCloud.com.realmeric.oricode"
}

/// The record types. A Mac's are sealed with its state key, a phone's with its pairing key. In the
/// clear there are only these names, record names and CloudKit's own dates.
public enum RecordType {
    public static let mac = "Mac"
    public static let project = "Project"
    public static let thread = "Thread"
    public static let ask = "Ask"
    public static let nudge = "Nudge"
    public static let phone = "Phone"
    public static let command = "Command"
    /// Not a record: the label a wrapped state key is sealed under.
    static let stateKey = "StateKey"
}

/// The fields, all in a record's encryptedValues.
public enum Field {
    /// The sealed content.
    public static let box = "box"
    /// A phone's public key and its proof that it read the code.
    public static let key = "key"
    public static let proof = "proof"
    /// The Mac's state key, sealed under the phone's pairing key.
    public static let wrapped = "wrapped"
    /// Which phone wrote a command, by its record's name, so the Mac knows whose key opens it.
    public static let phone = "phone"
    /// The Mac's answer to a command, sealed under that phone's key.
    public static let outcome = "outcome"
}

/// One zone per Mac in the private database, since database subscriptions don't fire for the
/// default zone.
public enum Zone {
    public static func id(mac: UUID) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "mac-\(mac.uuidString)", ownerName: CKCurrentUserDefaultName)
    }

    public static func mac(of zone: CKRecordZone.ID) -> UUID? {
        guard zone.zoneName.hasPrefix("mac-") else { return nil }
        return UUID(uuidString: String(zone.zoneName.dropFirst(4)))
    }
}

/// Record names: a Mac's record is `mac`, the rest are their kind and the Mac's own id for them,
/// random UUIDs and request ids that mean nothing outside the Mac.
public enum RecordName {
    public static let mac = "mac"
    public static func project(_ id: UUID) -> String { "project-\(id.uuidString)" }
    public static func thread(_ id: UUID) -> String { "thread-\(id.uuidString)" }
    public static func ask(_ id: String) -> String { "ask-\(id)" }
    public static func nudge(_ id: String) -> String { "nudge-\(id)" }

    /// The id a name was made from: `thread-<id>` gives `<id>`.
    public static func id(in name: String) -> String {
        name.firstIndex(of: "-").map { String(name[name.index(after: $0)...]) } ?? name
    }
}

public enum MacState: String, Codable, Sendable {
    case awake, asleep, closed
}

public struct MacInfo: Codable, Equatable, Sendable {
    public var name: String
    public var version: String
    public var state: MacState

    public init(name: String, version: String, state: MacState) {
        self.name = name
        self.version = version
        self.state = state
    }
}

public struct ProjectInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var initials: String
    /// Which of the Mac's eight badge colours, or nil for No folder, which has none.
    public var color: Int?
    /// Whether new threads start here when the phone names no project.
    public var starts: Bool
    /// Its place in the list, as the Mac orders projects.
    public var order: Int

    public init(id: UUID, name: String, initials: String, color: Int?, starts: Bool, order: Int) {
        self.id = id
        self.name = name
        self.initials = initials
        self.color = color
        self.starts = starts
        self.order = order
    }
}

/// A thread's state as the Mac's drawer and heads say it.
public enum ThreadStatus: String, Codable, Sendable {
    case working, asking, idle, stopped, failed
}

public struct ThreadInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var project: UUID
    public var title: String
    /// The agent it runs on, Claude Code's `claude` or another's id, for its mark's colour.
    public var agent: String
    public var status: ThreadStatus
    /// What it's on, as the Mac's heads say it: "Running swift test", "Writing".
    public var step: String?
    /// Lit rays, by where they stand, each with the agent that holds it.
    public var rays: [Int: String]
    /// Its latest finished reply, cut at 4,000 characters.
    public var reply: String?
    public var pinned: Bool
    public var updated: Date

    public init(id: UUID, project: UUID, title: String, agent: String, status: ThreadStatus, step: String?, rays: [Int: String], reply: String?, pinned: Bool, updated: Date) {
        self.id = id
        self.project = project
        self.title = title
        self.agent = agent
        self.status = status
        self.step = step
        self.rays = rays
        self.reply = reply
        self.pinned = pinned
        self.updated = updated
    }
}

/// One ask waiting on you, as the Mac's card shows it.
public struct AskInfo: Codable, Equatable, Sendable, Identifiable {
    public struct Choice: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var allows: Bool

        public init(id: String, name: String, allows: Bool) {
            self.id = id
            self.name = name
            self.allows = allows
        }
    }

    public struct Option: Codable, Equatable, Sendable {
        public var label: String
        public var detail: String?

        public init(label: String, detail: String?) {
            self.label = label
            self.detail = detail
        }
    }

    public struct Question: Codable, Equatable, Sendable {
        public var text: String
        public var multiple: Bool
        public var options: [Option]

        public init(text: String, multiple: Bool, options: [Option]) {
            self.text = text
            self.multiple = multiple
            self.options = options
        }
    }

    /// The request id the Mac answers it by.
    public var id: String
    public var thread: UUID
    /// `permission` or `question`.
    public var kind: String
    /// "Run a command?", "Edit App/Store.swift?".
    public var title: String
    /// What it's on: a command, a path, a URL; nil when the title says it all.
    public var detail: String?
    /// Whether the detail is code, set in SF Mono.
    public var code: Bool
    /// The agent's own answers, when it gave them; Claude's asks have none.
    public var choices: [Choice]
    public var questions: [Question]
    /// The worker that asked, "Codex's worker · tests", when one did.
    public var worker: String?
    public var asked: Date

    public init(id: String, thread: UUID, kind: String, title: String, detail: String?, code: Bool, choices: [Choice], questions: [Question], worker: String?, asked: Date) {
        self.id = id
        self.thread = thread
        self.kind = kind
        self.title = title
        self.detail = detail
        self.code = code
        self.choices = choices
        self.questions = questions
        self.worker = worker
        self.asked = asked
    }

    public var isQuestion: Bool { kind == "question" }

    /// A permission's one line, for a notification's body.
    public var line: String {
        if isQuestion { return questions.first?.text ?? title }
        guard let detail else { return title }
        return detail.split(whereSeparator: \.isNewline).first.map(String.init) ?? title
    }
}

/// What makes the phone buzz: the notification's words, made on the phone from this box.
public struct NudgeInfo: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case permission, question, reply
    }

    public var kind: Kind
    public var title: String
    public var body: String
    public var thread: UUID
    public var ask: String?
    /// A question's options, when it has one question of three or fewer, which go on its buttons.
    public var options: [String]

    public init(kind: Kind, title: String, body: String, thread: UUID, ask: String?, options: [String]) {
        self.kind = kind
        self.title = title
        self.body = body
        self.thread = thread
        self.ask = ask
        self.options = options
    }
}

public struct PhoneInfo: Codable, Equatable, Sendable {
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

/// What the phone asks the Mac to do, each with a nonce the Mac remembers, so a saved copy sent
/// again is refused.
public struct Command: Codable, Equatable, Sendable {
    public enum Action: Codable, Equatable, Sendable {
        case answer(ask: String, thread: UUID, allow: Bool, choice: String?, answers: [String: String]?, message: String?)
        case stop(thread: UUID)
        case send(thread: UUID, text: String)
        case open(project: UUID?, text: String)
    }

    public var action: Action
    public var nonce: UUID

    public init(_ action: Action, nonce: UUID = UUID()) {
        self.action = action
        self.nonce = nonce
    }
}

/// The Mac's answer to a command: done, or refused and why, in one line, and for a new thread its id.
public struct Outcome: Codable, Equatable, Sendable {
    public var ok: Bool
    public var reason: String?
    public var thread: UUID?

    public init(ok: Bool, reason: String? = nil, thread: UUID? = nil) {
        self.ok = ok
        self.reason = reason
        self.thread = thread
    }

    public static func refused(_ reason: String) -> Outcome {
        Outcome(ok: false, reason: reason)
    }
}

extension CKRecord {
    /// Seals `value` into the record's box with `key`, under the record's own type and name.
    public func seal(_ value: some Encodable, key: SymmetricKey, field: String = Field.box) throws {
        let label = field == Field.box ? recordType : "\(recordType).\(field)"
        encryptedValues[field] = try Seal.seal(value, key: key, type: label, name: recordID.recordName)
    }

    public func open<Value: Decodable>(_ type: Value.Type, key: SymmetricKey, field: String = Field.box) throws -> Value {
        guard let box = encryptedValues[field] as? Data else { throw Seal.Refused() }
        let label = field == Field.box ? recordType : "\(recordType).\(field)"
        return try Seal.open(type, from: box, key: key, type: label, name: recordID.recordName)
    }

    public func data(_ field: String) -> Data? {
        encryptedValues[field] as? Data
    }

    public func string(_ field: String) -> String? {
        encryptedValues[field] as? String
    }
}
