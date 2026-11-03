import CloudKit
import CryptoKit
import Foundation
import Link
import Testing
@testable import OriCode

/// What OriPass leaves to the phone, through the Mac: a fake OriPass speaking OP-88 on a socket of
/// its own, never ~/.oripass, with a P-256 key standing in for the phone's, and commands sealed as
/// a paired phone seals them. CloudKit's trip between is Link's to test; here the sealed command
/// goes straight in.
@MainActor
@Suite(.serialized)
struct PhoneOriPassTests {
    let oriPass: FakeOriPass
    let model: AppModel
    let chat: Chat
    /// The model's own link, so whatever the model can reach, it reaches.
    let link: PhoneLink
    let phone = PhoneKeys.Phone(id: "phone-\(UUID().uuidString)", name: "iPhone", key: SymmetricKey(size: .bits256).data)
    /// The phone's key, which OriPass has registered.
    let enclave = P256.Signing.PrivateKey()

    init() throws {
        oriPass = try FakeOriPass()
        let container = try TestStore.memory()
        let project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        chat = Chat(project: project, title: "Lead")
        chat.started = true
        container.mainContext.insert(chat)
        try container.mainContext.save()
        model = AppModel(container: container)
        link = model.phone
        link.model = model
        var keys = PhoneKeys.make()
        keys.phones = [phone]
        link.keys = keys
        link.oriPass = OriPassLine(path: oriPass.path)
    }

    private func until(_ isSo: () -> Bool) async {
        for _ in 0..<400 where !isSo() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// Connected, said hello, and welcomed.
    private func connected() async throws {
        try oriPass.open()
        link.oriPass.start()
        let hello = try #require(await oriPass.hear())
        #expect(hello["type"] as? String == "hello")
        #expect(hello["v"] as? Int == 1)
        oriPass.say(["type": "welcome", "phone": ["name": "iPhone", "fingerprint": PassWire.fingerprint(of: enclave.publicKey.x963Representation)]])
        await until { link.oriPass.reachable }
    }

    /// OP-88's request, two minutes from now.
    private func request(_ id: String = UUID().uuidString.lowercased()) -> [String: Any] {
        var line = Self.cardsRequest
        line["id"] = id
        line["nonce"] = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
        line["expires"] = Date.now.addingTimeInterval(120).formatted(.iso8601)
        return line
    }

    nonisolated(unsafe) static let cardsRequest: [String: Any] = [
        "type": "request", "act": "stranger",
        "words": "OriCode wants to connect to buzul\nKey: Sunucu anahtarı\nGoing to: buzul\nHost key: SHA256:DemoDemoDemoDemoDemoDemoDemoDemoDemoDemoDem\nAsked by: ssh › zsh › claude › OriCode",
        "app": "OriCode", "appID": "com.realmeric.oricode", "key": "Sunucu anahtarı", "keyFingerprint": "SHA256:KeyDemoKeyDemoKeyDemoKeyDemoKeyDemoKeyDemoK",
        "host": "buzul", "hostKey": "SHA256:DemoDemoDemoDemoDemoDemoDemoDemoDemoDemoDem",
    ]

    /// A command as the phone seals it, taken as a fetch would hand it over; its outcome back.
    @discardableResult
    private func command(_ action: Command.Action) throws -> Link.Outcome {
        let keys = try #require(link.keys)
        let record = CKRecord(recordType: RecordType.command, recordID: CKRecord.ID(recordName: "command-\(UUID().uuidString)", zoneID: keys.zone))
        record.encryptedValues[Field.phone] = phone.id
        try record.seal(Command(action), key: phone.pairingKey)
        link.commanded(record)
        return try record.open(Link.Outcome.self, key: phone.pairingKey, field: Field.outcome)
    }

    /// What OriPass works out from its own copy of what it sent, by OP-88's words and not by Link's.
    private func signed(_ line: [String: Any]) -> Data {
        func field(_ bytes: Data) -> Data { withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { Data($0) } + bytes }
        var shown = Data()
        for name in ["act", "words", "app", "appID", "key", "keyFingerprint", "host", "hostKey", "expires"] {
            shown += field(Data((line[name] as? String ?? "").utf8))
        }
        let id = Data((line["id"] as? String ?? "").utf8)
        let nonce = Data(base64Encoded: line["nonce"] as? String ?? "") ?? Data()
        return Data("oripass.approve.v1".utf8) + [0] + field(id) + field(nonce) + Data(SHA256.hash(data: shown))
    }

    // MARK: A request

    @Test func aRequestReachesThePhoneAndAYesGoesBackAsThePhoneMadeIt() async throws {
        try await connected()
        let line = request()
        let id = try #require(line["id"] as? String)
        oriPass.say(line)
        await until { !link.passAsks().isEmpty }
        let ask = try #require(link.passAsks()[RecordName.pass(id)])
        let shown = try #require(ask.request)
        #expect(shown.words == line["words"] as? String)

        // The phone signs what its copy says, and the Mac hands the signature over untouched.
        let signature = try enclave.signature(for: shown.message).derRepresentation
        #expect(try command(.approve(request: id, signature: signature)).ok)
        let approve = try #require(await oriPass.hear())
        #expect(approve["type"] as? String == "approve")
        #expect(approve["id"] as? String == id)
        #expect(approve["v"] as? Int == 1)
        let carried = try #require((approve["signature"] as? String).flatMap { Data(base64Encoded: $0) })
        #expect(carried == signature)
        #expect(enclave.publicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: carried), for: signed(line)))

        // `closed` is what ends it, heard twice when a late approve is a replay.
        oriPass.say(["type": "closed", "id": id, "outcome": "approved"])
        await until { link.passAsks().isEmpty }
        #expect(link.passAsks().isEmpty)
        oriPass.say(["type": "closed", "id": id, "outcome": "refused", "reason": "replay"])
        #expect(try !command(.approve(request: id, signature: signature)).ok)
        #expect(await oriPass.hear(within: .milliseconds(300)) == nil)
    }

    @Test func denyCarriesNoSignature() async throws {
        try await connected()
        let line = request()
        let id = try #require(line["id"] as? String)
        oriPass.say(line)
        await until { !link.passAsks().isEmpty }
        #expect(try command(.deny(request: id)).ok)
        let deny = try #require(await oriPass.hear())
        #expect(deny["type"] as? String == "deny")
        #expect(deny["id"] as? String == id)
        #expect(deny["signature"] == nil)
    }

    @Test func nothingGoesForARequestOriPassNeverSent() async throws {
        try await connected()
        #expect(try command(.approve(request: UUID().uuidString.lowercased(), signature: Data([1]))).reason == "No longer waiting")
        #expect(await oriPass.hear(within: .milliseconds(300)) == nil)
    }

    @Test func whatStoodOnAConnectionGoesWithItAndComesBackDownTheNext() async throws {
        try await connected()
        let line = request()
        oriPass.say(line)
        await until { !link.passAsks().isEmpty }
        oriPass.shut()
        await until { !link.oriPass.reachable }
        #expect(link.passAsks().isEmpty)
        // OriPass makes its socket again, and sends what's still open after the welcome.
        try oriPass.open()
        let hello = try #require(await oriPass.hear(within: .seconds(2)))
        #expect(hello["type"] as? String == "hello")
        oriPass.say(["type": "welcome", "phone": NSNull()])
        oriPass.say(line)
        await until { !link.passAsks().isEmpty }
        #expect(link.oriPass.phone == nil)
        #expect(link.passAsks().count == 1)
    }

    /// The folder is watched: a socket made after the line started is found well inside the five
    /// seconds a retry would take.
    @Test func aSocketThatAppearsIsFoundAtOnce() async throws {
        link.oriPass.start()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!link.oriPass.reachable)
        let made = ContinuousClock.now
        try oriPass.open()
        let hello = try #require(await oriPass.hear(within: .seconds(2)))
        #expect(hello["type"] as? String == "hello")
        #expect(ContinuousClock.now - made < .seconds(2))
    }

    @Test func aLineOfAnotherVersionOrAnUnknownTypeIsLetBy() async throws {
        try await connected()
        oriPass.say(["type": "request", "v": 2, "id": "x"])
        oriPass.say(["type": "news", "id": "y"])
        oriPass.sayRaw("not json")
        oriPass.say(request())
        await until { link.passAsks().count == 1 }
        #expect(link.passAsks().count == 1)
        #expect(link.oriPass.reachable)
    }

    // MARK: No agent

    /// No path from an agent: a pass isn't a conversation's ask, so answer_ask, the queue, read_plan
    /// and an `answer` command find nothing, and nothing reaches OriPass.
    @Test func noAgentCanAnswerIt() async throws {
        try await connected()
        let line = request()
        let id = try #require(line["id"] as? String)
        oriPass.say(line)
        await until { !link.passAsks().isEmpty }

        #expect(model.waitingAsks.isEmpty)
        #expect(model.waitingCount == 0)
        #expect(link.snapshot().asks.isEmpty)
        #expect(link.snapshot().passes.keys.contains(RecordName.pass(id)))
        for answer in ["allow", "deny", "pass"] {
            #expect(throws: (any Error).self) { try model.answerAsk(["ask": .string(id), "answer": .string(answer), "reason": "agent"], from: chat.id) }
        }
        #expect(try command(.answer(ask: id, thread: chat.id, allow: true, choice: nil, answers: nil, message: nil)).reason == "No longer waiting")
        #expect(await oriPass.hear(within: .milliseconds(300)) == nil)
        #expect(link.passAsks().count == 1)
    }

    // MARK: Registering

    @Test func aPhonesKeyGoesToOriPassAsItCameAndTheAskEndsWithItsAnswer() async throws {
        try await connected()
        link.oriPass.register()
        let ask = try #require(link.passAsks().values.first)
        #expect(ask.want == .register)
        let key = enclave.publicKey.x963Representation
        let proof = try enclave.signature(for: PassWire.registration(name: "iPhone", publicKey: key)).derRepresentation
        // An ask it wasn't given is refused.
        #expect(try !command(.register(ask: "register-other", name: "iPhone", publicKey: key, proof: proof)).ok)
        #expect(try command(.register(ask: ask.id, name: "iPhone", publicKey: key, proof: proof)).ok)
        let register = try #require(await oriPass.hear())
        #expect(register["type"] as? String == "register")
        #expect(register["name"] as? String == "iPhone")
        let sentKey = try #require((register["publicKey"] as? String).flatMap { Data(base64Encoded: $0) })
        let sentProof = try #require((register["proof"] as? String).flatMap { Data(base64Encoded: $0) })
        #expect(sentKey == key)
        let fromKey = try P256.Signing.PublicKey(x963Representation: sentKey)
        #expect(fromKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: sentProof),
                                         for: Data("oripass.register.v1".utf8) + [0, 0, 0, 0, 6] + Data("iPhone".utf8) + [0, 0, 0, 65] + sentKey))
        // Up until OriPass's card is answered, so the phone keeps the fingerprint on screen.
        #expect(link.passAsks().count == 1)
        oriPass.say(["type": "registered", "fingerprint": PassWire.fingerprint(of: key)])
        await until { link.passAsks().isEmpty }
        #expect(link.oriPass.phone == OriPassLine.Phone(name: "iPhone", fingerprint: PassWire.fingerprint(of: key)))
    }

    @Test func aRefusedRegistrationSaysWhy() async throws {
        try await connected()
        link.oriPass.register()
        let ask = try #require(link.passAsks().values.first)
        let key = enclave.publicKey.x963Representation
        let proof = try enclave.signature(for: PassWire.registration(name: "iPhone", publicKey: key)).derRepresentation
        #expect(try command(.register(ask: ask.id, name: "iPhone", publicKey: key, proof: proof)).ok)
        _ = await oriPass.hear()
        oriPass.say(["type": "refused", "reason": "not-waiting"])
        await until { link.passAsks().isEmpty }
        #expect(link.oriPass.registering == .refused("Press Add Phone in OriPass's Settings › Developer first."))
    }

    @Test func aPassBuzzesWithOriPasssWordsAndNoThread() throws {
        let request = try #require(PassRequest(line: request()))
        let nudge = PhoneLink.nudge(for: PassAsk(id: request.id, want: .approve(request), asked: .now))
        #expect(nudge.kind == .pass)
        #expect(nudge.title == "OriPass")
        #expect(nudge.subtitle == "OriCode wants to connect to buzul")
        #expect(nudge.body == request.words)
        #expect(nudge.thread == NudgeInfo.noThread)
        #expect(nudge.ask == request.id)
    }
}

/// OriPass's end of approve.sock as OP-88 says it speaks: one connection at a time, a line each way.
final class FakeOriPass: @unchecked Sendable {
    let folder: URL
    var path: String { folder.appending(path: "approve.sock").path }
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var peer: Int32 = -1
    private var heard: [[String: Any]] = []

    init() throws {
        // A socket's path is held to 104 bytes.
        folder = URL(filePath: "/tmp/p26-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        shut()
        try? FileManager.default.removeItem(at: folder)
    }

    func open() throws {
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        unlink(path)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(listener, 4) == 0 else { throw POSIXError(.EADDRINUSE) }
        lock.withLock { self.listener = listener }
        Thread.detachNewThread { [weak self] in
            let peer = accept(listener, nil, nil)
            guard peer >= 0, let self else { return }
            self.lock.withLock { self.peer = peer }
            self.read(peer)
        }
    }

    func shut() {
        let (listener, peer) = lock.withLock { (self.listener, self.peer) }
        if peer >= 0 { shutdown(peer, SHUT_RDWR); close(peer) }
        if listener >= 0 { close(listener) }
        unlink(path)
        lock.withLock {
            self.listener = -1
            self.peer = -1
            self.heard = []
        }
    }

    func say(_ line: [String: Any]) {
        var line = line
        if line["v"] == nil { line["v"] = 1 }
        sayRaw(String(decoding: try! JSONSerialization.data(withJSONObject: line), as: UTF8.self))
    }

    func sayRaw(_ line: String) {
        let peer = lock.withLock { self.peer }
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(peer, $0.baseAddress, $0.count) }
    }

    /// The next line OriCode wrote, or nil when none comes in time.
    func hear(within wait: Duration = .seconds(2)) async -> [String: Any]? {
        let until = ContinuousClock.now + wait
        while ContinuousClock.now < until {
            if let line = lock.withLock({ heard.isEmpty ? nil : heard.removeFirst() }) { return line }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    private func read(_ peer: Int32) {
        var held = Data()
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while true {
            let got = Darwin.read(peer, &chunk, chunk.count)
            guard got > 0 else { return }
            held.append(contentsOf: chunk.prefix(got))
            while let end = held.firstIndex(of: 10) {
                let line = held[held.startIndex..<end]
                held = Data(held[held.index(after: end)...])
                if let said = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { lock.withLock { heard.append(said) } }
            }
        }
    }
}
