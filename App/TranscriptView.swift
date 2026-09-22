import SwiftUI

struct TranscriptView: View {
    let conversation: Conversation

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(conversation.items) { item in
                    ItemView(item: item)
                }
            }
            .padding(.vertical, 48)
        }
        .scrollIndicators(.never)
        .defaultScrollAnchor(.bottom)
    }
}

struct ItemView: View {
    let item: Item

    var body: some View {
        switch item {
        case .user(_, let text):
            Text(text)
                .font(Type.body)
                .foregroundStyle(Ink.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Surface.userMessage, in: .rect(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: 560, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .text(_, let text):
            Text(text)
                .font(Type.body)
                .foregroundStyle(Ink.primary)
                .textSelection(.enabled)
        case .thinking:
            EmptyView()
        case .tool(_, let call):
            Text(call.name)
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
        case .ask(_, let ask):
            Text("\(ask.tool) is waiting")
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
        case .footer(_, let footer):
            Text("Worked for \(Int(footer.durationMs / 1000))s · \(footer.costUSD, format: .currency(code: "USD"))")
                .font(Type.secondary)
                .foregroundStyle(Ink.faint)
        case .note(_, let text):
            Text(text)
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
        }
    }
}
