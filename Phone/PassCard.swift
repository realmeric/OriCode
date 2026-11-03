import Link
import SwiftUI

/// What OriPass would ask a finger for at the Mac, which only this phone's key can answer. No
/// agent asks it, so it has none of an agent's card: the icon's violet and OriPass's name, then
/// OriPass's words exactly as it sent them, its clock, and Allow behind Face ID. Allow signs the
/// request's bytes as OP-88 says; Deny signs nothing.
struct PassCard: View {
    @Environment(PhoneClient.self) private var store
    @Environment(Router.self) private var router
    let pass: PassAsk
    @State private var signing = false
    @State private var over = false
    @State private var declined: String?
    @State private var sentAt = 0
    /// Once Register has signed: the fingerprint to compare with OriPass's card on the Mac.
    @State private var fingerprint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .font(.footnote)
                Text("OriPass")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if let expiry = pass.request?.expiry, !over {
                    Text(timerInterval: Date.now...max(expiry, .now), countsDown: true)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Ink.faint)
                }
            }
            .foregroundStyle(Ink.secondary)
            if let request = pass.request {
                words(request)
            } else {
                registration
            }
            if let refused = declined ?? refusal {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                    if !refused.isEmpty { Text(refused) }
                }
                .font(.footnote)
                .foregroundStyle(Ink.red)
            }
            buttons
        }
        .padding(18)
        .background(Ink.pass, in: .rect(cornerRadius: 24, style: .continuous))
        .opacity(waiting || over ? 0.5 : 1)
        .disabled(waiting || over || signing)
        .sensoryFeedback(.impact(weight: .light), trigger: sentAt)
        .task(id: pass.request?.expires) { await expire() }
        // Allow on its notification opened the app here, and Face ID comes at once.
        .task(id: router.allowing) {
            guard router.allowing == pass.id else { return }
            router.allowing = nil
            await allow()
        }
    }

    /// The first line as the statement, every line after it as it came, labels quieter.
    private func words(_ request: PassRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(request.statement)
                .font(.body.weight(.semibold))
                .foregroundStyle(Ink.primary)
            ForEach(Array(request.particulars.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                particular(String(line))
                    .font(.footnote)
                    .textSelection(.enabled)
            }
        }
    }

    private func particular(_ line: String) -> Text {
        guard let colon = line.range(of: ": ") else { return Text(line).foregroundStyle(Ink.secondary) }
        let value = String(line[colon.upperBound...])
        let shown = value.hasPrefix("SHA256:") ? Text(value).font(.system(.footnote, design: .monospaced)) : Text(value)
        return Text("\(Text(line[..<colon.upperBound]).foregroundStyle(Ink.faint))\(shown.foregroundStyle(Ink.secondary))")
    }

    private var registration: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Register this iPhone")
                .font(.body.weight(.semibold))
                .foregroundStyle(Ink.primary)
            if let fingerprint {
                Text(fingerprint)
                    .font(.system(.title3, design: .monospaced).weight(.medium))
                    .foregroundStyle(Ink.primary)
                    .textSelection(.enabled)
                Text("Compare with OriPass's card on your Mac.")
                    .font(.footnote)
                    .foregroundStyle(Ink.secondary)
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if fingerprint == nil {
            HStack(spacing: 8) {
                Spacer()
                if let request = pass.request {
                    Button("Deny") { deny(request) }
                        .buttonStyle(.glass)
                }
                Button {
                    Task { pass.request == nil ? await register() : await allow() }
                } label: {
                    Label(pass.request == nil ? "Register" : "Allow", systemImage: "faceid")
                }
                .lit()
            }
            .controlSize(.regular)
        }
    }

    // MARK: Answering

    private var answer: PhoneClient.Sent? {
        store.sent.values.filter {
            switch $0.action {
            case .approve(let id, _), .deny(let id): id == pass.id
            case .register(let id, _, _, _): id == pass.id
            default: false
            }
        }.max { $0.at < $1.at }
    }

    private var waiting: Bool { answer?.state == .waiting && answer?.undelivered() == false && fingerprint == nil }

    private var refusal: String? {
        guard let answer, answer.undelivered() else { return nil }
        if case .refused(let reason) = answer.state { return reason }
        return ""
    }

    private func allow() async {
        guard let request = pass.request, !request.expired(), !signing else { return }
        signing = true
        defer { signing = false }
        declined = nil
        do {
            let signature = try await PassKey.sign(request.message, reason: "Allow what OriPass asks on your Mac")
            // Past `expires` the phone refuses by itself, Face ID's time included.
            guard !request.expired() else { return over = true }
            if let old = answer { store.clear(old.id) }
            store.send(.approve(request: request.id, signature: signature))
            sentAt += 1
        } catch PassKey.Failure.declined {
        } catch {
            declined = "Register this iPhone with OriPass again."
        }
    }

    private func deny(_ request: PassRequest) {
        if let old = answer { store.clear(old.id) }
        store.send(.deny(request: request.id))
        sentAt += 1
    }

    private func register() async {
        guard !signing else { return }
        signing = true
        defer { signing = false }
        declined = nil
        do {
            let name = String(store.deviceName.prefix(PassWire.longestName))
            let (key, proof) = try await PassKey.registration(name: name)
            store.send(.register(ask: pass.id, name: name, publicKey: key, proof: proof))
            fingerprint = PassWire.fingerprint(of: key)
            sentAt += 1
        } catch PassKey.Failure.declined {
        } catch {
            declined = ""
        }
    }

    private func expire() async {
        guard let expiry = pass.request?.expiry else { return }
        let left = expiry.timeIntervalSinceNow
        if left > 0 { try? await Task.sleep(for: .seconds(left)) }
        guard !Task.isCancelled else { return }
        over = true
    }
}
