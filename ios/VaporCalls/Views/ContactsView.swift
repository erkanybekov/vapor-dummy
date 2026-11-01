import SwiftUI

struct ContactsView: View {
    @Environment(AppModel.self) private var model
    let calls: CallManager

    @State private var email = ""
    @State private var adding = false
    @State private var contacts: [Contact] = []
    @State private var blocked: [BlockedUser] = []
    @State private var loaded = false
    @State private var loadError: String?

    private var canCall: Bool {
        calls.connection == .online && calls.call == nil
    }

    private var target: String {
        email.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                    Button("Добавить", action: add)
                        .disabled(adding || target.isEmpty)
                } header: {
                    Text("Добавить контакт")
                } footer: {
                    Text("Человек не получит уведомления. Статус «в сети» виден, когда вы добавили друг друга.")
                }

                Section("Контакты") {
                    if let loadError {
                        Text(loadError).foregroundStyle(.red)
                    } else if loaded, contacts.isEmpty {
                        Text("Контактов пока нет.").foregroundStyle(.secondary)
                    }
                    ForEach(contacts) { contact in
                        ContactRow(contact: contact, canCall: canCall) { video in
                            Task { await calls.startCall(to: .user(id: contact.id, name: contact.username), video: video) }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Удалить", role: .destructive) {
                                change { try await model.api.removeContact(id: contact.id) }
                            }
                            .tint(.red)
                            Button("Заблокировать") {
                                change { try await model.api.block(id: contact.id) }
                            }
                            .tint(.orange)
                        }
                    }
                }

                if !blocked.isEmpty {
                    Section {
                        ForEach(blocked) { user in
                            HStack {
                                Text(user.username).lineLimit(1)
                                Spacer()
                                Button("Разблокировать") {
                                    change { try await model.api.unblock(id: user.id) }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    } header: {
                        Text("Заблокированные")
                    } footer: {
                        Text("Заблокированный не сможет вам дозвониться: для него вы просто не в сети.")
                    }
                }
            }
            .navigationTitle("Контакты")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ConnectionBadge(state: calls.connection)
                }
            }
            .refreshable { await load() }
            // Also after reconnecting: changes made while offline were not announced.
            .task(id: "\(calls.contactChanges)/\(calls.connection == .online)") { await load() }
        }
    }

    private func load() async {
        do {
            async let list = model.api.contacts()
            async let blockedList = model.api.blockedUsers()
            (contacts, blocked) = try await (list, blockedList)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
    }

    private func add() {
        guard !adding, !target.isEmpty else { return }
        adding = true
        Task {
            defer { adding = false }
            do {
                try await model.api.addContact(email: target)
                email = ""
                await load()
            } catch {
                calls.notice = Self.addErrorText(error)
            }
        }
    }

    private func change(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                await load()
            } catch {
                calls.notice = error.localizedDescription
            }
        }
    }

    private static func addErrorText(_ error: any Error) -> String {
        switch (error as? APIError)?.status {
        case 400: "Себя добавить нельзя"
        case 404: "Пользователь с таким email не найден"
        case 409: "Этот пользователь заблокирован: сначала разблокируйте его"
        case 429: "Слишком много попыток, подождите"
        default: error.localizedDescription
        }
    }
}

private struct ContactRow: View {
    let contact: Contact
    let canCall: Bool
    let call: (_ video: Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(contact.online ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.username).lineLimit(1)
                Text(contact.online ? "в сети" : "не в сети").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                call(true)
            } label: {
                Image(systemName: "video.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!canCall)
            .accessibilityLabel("Видеозвонок: \(contact.username)")
            Button {
                call(false)
            } label: {
                Image(systemName: "phone.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!canCall)
            .accessibilityLabel("Аудиозвонок: \(contact.username)")
        }
    }
}
