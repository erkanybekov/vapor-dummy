import SwiftUI

struct LoginView: View {
    private enum Mode: Hashable {
        case login, register
    }

    private enum Server: Hashable {
        case render, mac
    }

    @Environment(AppModel.self) private var model
    @State private var mode = Mode.login
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    @State private var slow = false
    @State private var server = ServerEnvironment.baseURL == ServerEnvironment.local ? Server.mac : Server.render

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Режим", selection: $mode) {
                        Text("Вход").tag(Mode.login)
                        Text("Регистрация").tag(Mode.register)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if mode == .register {
                        TextField("Имя", text: $username)
                            .textContentType(.nickname)
                    }
                    SecureField("Пароль", text: $password)
                        .textContentType(mode == .login ? .password : .newPassword)
                } footer: {
                    if mode == .register { Text("8+ символов: заглавная и строчная латинские буквы и цифра.") }
                }

                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: submit) {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text(mode == .login ? "Войти" : "Создать аккаунт").bold() }
                            Spacer()
                        }
                    }
                    .disabled(busy || email.isEmpty || password.isEmpty)
                } footer: {
                    if slow { Text("Сервер на бесплатном тарифе просыпается — это может занять до минуты.") }
                }

                Section {
                    Picker("Сервер", selection: $server) {
                        Text("Render").tag(Server.render)
                        Text("Этот Mac").tag(Server.mac)
                    }
                    .onChange(of: server) { _, value in
                        ServerEnvironment.baseURL = value == .mac ? ServerEnvironment.local : ServerEnvironment.production
                    }
                } footer: {
                    Text("«Этот Mac» — локальный `swift run`, доступен только из симулятора.")
                }
            }
            .navigationTitle("Vapor Calls")
        }
    }

    private func submit() {
        error = nil
        busy = true
        let slowTimer = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { slow = true }
        }
        Task {
            defer {
                slowTimer.cancel()
                busy = false
                slow = false
            }
            do {
                let email = email.trimmingCharacters(in: .whitespaces)
                if mode == .login {
                    try await model.signIn(email: email, password: password)
                } else {
                    let name = username.trimmingCharacters(in: .whitespaces)
                    try await model.register(email: email, username: name.isEmpty ? String(email.prefix { $0 != "@" }) : name, password: password)
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
