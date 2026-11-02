import Foundation

let token = "ВСТАВЬ_ACCESS_TOKEN"

var request = URLRequest(url: URL(string: "ws://localhost:8080/api/v1/chat/ws?room=general")!)
request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

let task = URLSession.shared.webSocketTask(with: request)
task.resume()   // здесь уходит GET с Upgrade: websocket
print("подключаюсь…")

do {
    while true {
        let frame = try await task.receive()   // ждёт ОДИН кадр
        switch frame {
        case .string(let text):
            print("←", text)
        case .data(let data):
            print("← бинарный кадр,", data.count, "байт")
        @unknown default:
            break
        }
    }
} catch {
    // Сюда попадаем, когда соединение закрылось или так и не открылось.
    let status = (task.response as? HTTPURLResponse)?.statusCode
    print("соединение закрыто:", error.localizedDescription)
    print("HTTP-статус рукопожатия:", status.map(String.init) ?? "—", "· closeCode:", task.closeCode.rawValue)
}
