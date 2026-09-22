import Foundation

struct BranchInfo: Codable, Hashable, Sendable {
    let branch: String
    let ahead: Int
    let upstream: Bool
}

extension AppModel {
    var currentBranch: BranchInfo? {
        selectedChatID.flatMap { branches[$0] }
    }

    func refreshBranch(for chat: Chat?) {
        guard let chat, engineState == .ready else { return }
        let id = chat.id, cwd = chat.cwd
        Task {
            guard let reply = try? await engine.request("git.branch", ["cwd": .string(cwd)]),
                  let info = try? reply.decode(BranchInfo.self)
            else { return }
            if branches[id] != info { branches[id] = info }
        }
    }
}
