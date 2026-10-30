import Foundation
import SwiftUI

/// OriPass's SSH agent, which every agent and terminal OriCode starts may sign with while its
/// socket is there. The socket exists only once the agent is switched on in OriPass, so that is the
/// consent and Settings › Agents' switch starts on, for turning it off. A shell asks when it starts
/// and the engine at each spawn, so nothing watches the path, and neither ever connects: OriCode
/// hands on where the agent is and holds no key.
enum SSHAgent {
    static let key = "sshAgent"
    static let socket = NSHomeDirectory() + "/.oripass/agent.sock"

    static var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// What the engine is told, which looks for the socket itself.
    static var forEngine: JSON { isOn ? .string(socket) : .null }

    /// SSH_AUTH_SOCK for a shell starting now, or nil to leave it as it was given.
    static func path(at socket: String = socket, on: Bool = isOn) -> String? {
        var found = stat()
        guard on, stat(socket, &found) == 0, found.st_mode & S_IFMT == S_IFSOCK else { return nil }
        return socket
    }
}

/// Settings › Agents' card for it.
struct SSHAgentCard: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SSHAgent.key) private var on = true

    var body: some View {
        SectionHeading("SSH")
        SettingsCard {
            SettingsRow(
                title: "Sign with OriPass",
                detail: on ? "Agents and terminals use its SSH agent while it's running." : nil
            ) {
                Toggle("Sign with OriPass", isOn: $on).labelsHidden().toggleStyle(.switch)
                    .onChange(of: on) { model.tellSSHAgent() }
            }
        }
    }
}
