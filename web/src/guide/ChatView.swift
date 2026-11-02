import SwiftUI

/// Экран чата. ChatClient создаёт и держит владелец (App или экран выше),
/// а не этот View: body пересчитывается часто, сокет должен жить дольше.
struct ChatView: View {
    let chat: ChatClient
    @State private var draft = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List {
                    ForEach(chat.messages) { message in
                        MessageRow(
                            author: message.author.username,
                            text: message.text,
                            mine: message.author == chat.me
                        )
                    }
                    ForEach(chat.pending) { item in
                        MessageRow(author: item.failed ? "не отправлено, нажми ещё раз" : "отправляется…", text: item.text, mine: true)
                            .opacity(0.6)
                            .onTapGesture {
                                if item.failed { chat.retry(item) }
                            }
                    }
                }
                .onChange(of: chat.messages.last?.seq) { _, seq in
                    if let seq { proxy.scrollTo(seq, anchor: .bottom) }
                }
            }

            if !chat.typingUsers.isEmpty {
                Text(chat.typingUsers.map(\.username).joined(separator: ", ") + " печатает…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                TextField("Сообщение", text: $draft, axis: .vertical)
                    .onChange(of: draft) { _, text in chat.draftChanged(text) }
                    .onSubmit(send)
                Button("Отправить", action: send)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .navigationTitle(chat.state == .connected ? "Чат" : "Подключение…")
        // В фоне iOS всё равно усыпит сокет: закрываем сами и открываем при возврате.
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: chat.start()
            case .background: chat.stop()
            default: break
            }
        }
    }

    private func send() {
        chat.send(draft)
        draft = ""
    }
}

private struct MessageRow: View {
    let author: String
    let text: String
    let mine: Bool

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
            Text(author).font(.caption).foregroundStyle(.secondary)
            Text(text)
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }
}
