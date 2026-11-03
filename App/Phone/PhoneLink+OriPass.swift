import Foundation
import Link

/// What OriPass leaves to the phone (OriPassLine.swift), published as `Ask` records named
/// `oripass-<id>` beside the agents' asks, sealed as they are, and buzzed for as they are. None of
/// it is a conversation's ask: answer_ask, the queue and Threads answer first see only those, so
/// the one way to a yes is a command a paired phone sealed, with a signature only its key makes.
extension PhoneLink {
    func passAsks() -> [String: PassAsk] {
        var asks: [String: PassAsk] = [:]
        for (request, came) in oriPass.requests.values {
            asks[RecordName.pass(request.id)] = PassAsk(id: request.id, want: .approve(request), asked: came)
        }
        if let (id, since) = oriPass.registeringAsk {
            asks[RecordName.pass(id)] = PassAsk(id: id, want: .register, asked: since)
        }
        return asks
    }

    /// OriPass's words as they came, the first line heading the notification.
    static func nudge(for pass: PassAsk) -> NudgeInfo {
        NudgeInfo(kind: .pass, title: "OriPass", body: pass.request?.words ?? "Register this iPhone", thread: NudgeInfo.noThread, ask: pass.id, options: [])
    }

    func applyPass(_ action: Command.Action) -> Link.Outcome {
        let taken: Bool
        switch action {
        case .approve(let request, let signature): taken = oriPass.approve(request, signature: signature)
        case .deny(let request): taken = oriPass.deny(request)
        case .register(let ask, let name, let publicKey, let proof): taken = oriPass.register(ask, name: name, publicKey: publicKey, proof: proof)
        default: taken = false
        }
        return taken ? Link.Outcome(ok: true) : .refused("No longer waiting")
    }
}
