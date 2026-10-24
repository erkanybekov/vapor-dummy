import PulseUI
import SwiftUI

@main
struct VaporCallsApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(.green)
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS drops the socket in the background; reconnect as soon as we are back.
            if phase == .active { model.calls?.wake() }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showsLogs = false

    var body: some View {
        Group {
            if model.user == nil {
                LoginView()
            } else if let calls = model.calls {
                MainView(calls: calls)
            } else {
                ProgressView()
            }
        }
        .onChange(of: model.user == nil) { _, signedOut in
            if signedOut { model.sessionEnded() }
        }
        .task { await model.validateSession() }
        // Shake the phone anywhere to open the log console (like Talker).
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
            showsLogs = true
        }
        .sheet(isPresented: $showsLogs) {
            NavigationStack {
                ConsoleView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Закрыть") { showsLogs = false }
                        }
                    }
            }
        }
    }
}

extension Notification.Name {
    static let deviceDidShake = Notification.Name("VaporCalls.deviceDidShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
    }
}

struct MainView: View {
    let calls: CallManager

    /// With CallKit the system shows the ringing screen; ours appears once answered.
    private var showsCallScreen: Bool {
        guard let call = calls.call else { return false }
        return !(calls.usesCallKit && call.phase == .incoming)
    }

    var body: some View {
        TabView {
            CallsView(calls: calls)
                .tabItem { Label("Звонки", systemImage: "phone.fill") }
            TodosView()
                .tabItem { Label("Задачи", systemImage: "checklist") }
            ProfileView(calls: calls)
                .tabItem { Label("Профиль", systemImage: "person.crop.circle") }
        }
        .fullScreenCover(isPresented: .constant(showsCallScreen)) {
            CallView(calls: calls)
        }
        .overlay(alignment: .top) {
            NoticeBanner(calls: calls)
        }
    }
}

/// Shows `calls.notice` for a few seconds.
struct NoticeBanner: View {
    @Bindable var calls: CallManager

    var body: some View {
        if let notice = calls.notice {
            Text(notice)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation { calls.notice = nil }
                }
        }
    }
}
