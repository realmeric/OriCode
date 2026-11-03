#if DEBUG
import Foundation
import Link

/// OriPass on a made-up Mac: `-Screens oripass` puts OP-88's request at the head of home, and
/// `register` Settings › Phone's Register. What the card sends is written to
/// /tmp/oricode-p26-sent.json with the request it answers, for a script on the Mac to check the
/// signature against OP-88's bytes with code of its own; a moment on, the made-up Mac takes it.
extension Screens {
    static func passes(_ screen: String) -> [PassAsk]? {
        switch screen {
        case "oripass":
            let request = PassRequest(
                id: "6f1d2c3a-0b7e-4f10-9a55-3e1c7a2b9d04", nonce: Data(0..<32), act: "stranger",
                words: "OriCode wants to connect to buzul\nKey: Sunucu anahtarı\nGoing to: buzul\nHost key: SHA256:DemoDemoDemoDemoDemoDemoDemoDemoDemoDemoDem\nAsked by: ssh › zsh › claude › OriCode",
                app: "OriCode", appID: "com.realmeric.oricode", key: "Sunucu anahtarı", keyFingerprint: "SHA256:KeyDemoKeyDemoKeyDemoKeyDemoKeyDemoKeyDemoK",
                host: "buzul", hostKey: "SHA256:DemoDemoDemoDemoDemoDemoDemoDemoDemoDemoDem",
                expires: Date.now.addingTimeInterval(UserDefaults.standard.double(forKey: "PassLife").nonZero ?? 120).formatted(.iso8601))
            return [PassAsk(id: request.id, want: .approve(request), asked: .now)]
        case "register":
            return [PassAsk(id: "register-1", want: .register, asked: .now)]
        default:
            return nil
        }
    }

    @MainActor
    static func answer(_ passes: [PassAsk], in store: PhoneClient) {
        store.showForScreenshots(passes)
        watch(passes, in: store)
    }

    @MainActor
    private static func watch(_ passes: [PassAsk], in store: PhoneClient) {
        let sent = withObservationTracking { store.sent } onChange: {
            Task { @MainActor in watch(passes, in: store) }
        }
        for command in sent.values where command.state == .waiting {
            let out: [String: Any]
            switch command.action {
            case .approve(let id, let signature):
                guard let request = passes.first(where: { $0.id == id })?.request else { continue }
                out = ["type": "approve", "id": id, "signature": signature.base64EncodedString(), "publicKey": (try? PassKey.publicKey().base64EncodedString()) ?? "",
                       "request": ["id": request.id, "nonce": request.nonce.base64EncodedString(), "act": request.act, "words": request.words, "app": request.app,
                                   "appID": request.appID, "key": request.key, "keyFingerprint": request.keyFingerprint, "host": request.host,
                                   "hostKey": request.hostKey, "expires": request.expires]]
            case .deny(let id):
                out = ["type": "deny", "id": id]
            case .register(_, let name, let publicKey, let proof):
                out = ["type": "register", "name": name, "publicKey": publicKey.base64EncodedString(), "proof": proof.base64EncodedString()]
            default:
                continue
            }
            try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]).write(to: URL(filePath: "/tmp/oricode-p26-sent.json"))
            let id = command.id
            Task {
                try? await Task.sleep(for: .seconds(command.action.isRegister ? 6 : 1.5))
                store.settleForScreenshots(id)
            }
        }
    }
}

private extension Command.Action {
    var isRegister: Bool {
        if case .register = self { true } else { false }
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
#endif
