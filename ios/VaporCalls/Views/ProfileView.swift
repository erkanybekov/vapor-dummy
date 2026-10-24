import PulseUI
import SwiftUI

struct ProfileView: View {
    @Environment(AppModel.self) private var model
    let calls: CallManager

    var body: some View {
        NavigationStack {
            List {
                if let user = model.user {
                    Section {
                        LabeledContent("Имя", value: user.username)
                        LabeledContent("Email", value: user.email)
                    }
                }
                Section("Это устройство") {
                    LabeledContent("Имя", value: DeviceIdentity.name)
                    LabeledContent("Сервер", value: ServerEnvironment.baseURL.host() ?? "—")
                    LabeledContent("Звонки") {
                        HStack(spacing: 6) {
                            ConnectionBadge(state: calls.connection)
                            Text(calls.connection == .online ? "онлайн" : calls.connection == .connecting ? "подключение" : "нет связи")
                        }
                    }
                    LabeledContent("Входящие", value: calls.usesCallKit ? "CallKit" : "экран приложения")
                }
                Section {
                    NavigationLink {
                        ConsoleView()
                    } label: {
                        Label("Логи", systemImage: "list.bullet.rectangle.portrait")
                    }
                } footer: {
                    Text("Консоль Pulse: сообщения, сетевые запросы, поиск и экспорт. Открывается и встряхиванием телефона.")
                }
                Section {
                    Button("Выйти", role: .destructive) {
                        Task { await model.signOut() }
                    }
                } footer: {
                    Text("Звонки приходят, пока приложение открыто. Чтобы будить закрытое приложение, нужны VoIP-пуши — для них нужен платный аккаунт разработчика.")
                }
            }
            .navigationTitle("Профиль")
        }
    }
}
