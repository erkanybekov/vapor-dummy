import SwiftUI

struct CallsView: View {
    @Environment(AppModel.self) private var model
    let calls: CallManager

    @State private var email = ""
    @State private var history: [CallHistoryItem] = []
    @State private var historyError: String?

    private var canCall: Bool {
        calls.connection == .online && calls.call == nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Email собеседника", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack(spacing: 12) {
                        Button {
                            call(video: true)
                        } label: {
                            Label("Видео", systemImage: "video.fill")
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            call(video: false)
                        } label: {
                            Label("Аудио", systemImage: "phone.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                    .disabled(!canCall || email.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Новый звонок")
                } footer: {
                    Text("Свой email — звонок на ваши другие устройства.")
                }

                Section("Мои устройства онлайн") {
                    if calls.connection != .online {
                        Label("Подключаемся к серверу звонков…", systemImage: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(calls.devices) { device in
                            HStack {
                                Image(systemName: device.deviceName.contains("iPhone") || device.deviceName.contains("Android") ? "iphone" : "desktopcomputer")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                Text(device.deviceName)
                                Spacer()
                                if device.deviceId == DeviceIdentity.id {
                                    Text("это устройство").font(.caption).foregroundStyle(.green)
                                }
                            }
                        }
                        if calls.devices.count < 2 {
                            Text("Откройте приложение или сайт на другом устройстве под этим аккаунтом — и позвоните себе.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Недавние") {
                    if let historyError {
                        Text(historyError).foregroundStyle(.red)
                    } else if history.isEmpty {
                        Text("Звонков пока не было.").foregroundStyle(.secondary)
                    }
                    ForEach(history) { item in
                        HistoryRow(item: item, canCall: canCall) {
                            Task { await calls.startCall(to: .user(id: item.peerUserId, name: item.peerUsername ?? "Собеседник"), video: item.video) }
                        }
                    }
                }
            }
            .navigationTitle("Звонки")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ConnectionBadge(state: calls.connection)
                }
            }
            .refreshable { await loadHistory() }
            .task(id: calls.endedCalls) { await loadHistory() }
            .onAppear {
                if email.isEmpty { email = model.user?.email ?? "" }
            }
        }
    }

    private func call(video: Bool) {
        let target = email.trimmingCharacters(in: .whitespaces)
        Task { await calls.startCall(to: .email(target), video: video) }
    }

    private func loadHistory() async {
        do {
            history = try await model.api.callHistory()
            historyError = nil
        } catch {
            historyError = error.localizedDescription
        }
    }
}

private struct HistoryRow: View {
    let item: CallHistoryItem
    let canCall: Bool
    let callBack: () -> Void

    private var failed: Bool { item.status != .completed }

    private var title: String {
        item.direction == .selfCall ? "Себе" : (item.peerUsername ?? "Удалённый пользователь")
    }

    private var icon: String {
        switch item.direction {
        case .selfCall: "arrow.triangle.2.circlepath"
        case .incoming: "arrow.down.left"
        case .outgoing: "arrow.up.right"
        }
    }

    private var subtitle: String {
        let status = switch item.status {
        case .completed: "Состоялся"
        case .missed: "Пропущен"
        case .declined: "Отклонён"
        case .busy: "Занято"
        case .unavailable: "Недоступен"
        case .ringing: "Звонит"
        case .active: "Идёт"
        }
        var parts = [item.video ? "Видео" : "Аудио", status]
        if let duration = item.duration { parts.append(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(failed ? .red : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(failed && item.direction != .outgoing ? .red : .primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(item.startedAt, format: .dateTime.hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(action: callBack) {
                Image(systemName: item.video ? "video.fill" : "phone.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!canCall)
            .accessibilityLabel("Перезвонить: \(title)")
        }
    }
}

struct ConnectionBadge: View {
    let state: SignalingClient.State

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch state {
        case .online: .green
        case .connecting: .orange
        case .offline: .red
        }
    }

    private var label: String {
        switch state {
        case .online: "Онлайн"
        case .connecting: "Подключение"
        case .offline: "Нет связи"
        }
    }
}
