import Foundation
import os
import Pulse

/// App-wide logging, Talker-style: one call writes to
/// - Pulse — the in-app console (Профиль → Логи, or shake the phone): search,
///   filters, network inspector, export/share;
/// - os.Logger — Xcode's console and Console.app on the Mac.
///
/// ```swift
/// Log.info("Call ringing", .call, ["devices": "2"])
/// Log.error(error, .api)
/// ```
nonisolated enum Log {
    enum Category: String, CaseIterable, Sendable {
        case app, api, auth, signaling, webrtc, callkit, call, quality
    }

    private static let subsystem = Bundle.main.bundleIdentifier ?? "VaporCalls"
    private static let osLoggers = Dictionary(uniqueKeysWithValues: Category.allCases.map {
        ($0, Logger(subsystem: subsystem, category: $0.rawValue))
    })

    /// URLSession that records every request in Pulse's network inspector.
    /// Secrets are redacted before anything is stored.
    static let session: URLSessionProxy = {
        var configuration = NetworkLogger.Configuration()
        configuration.sensitiveHeaders = ["Authorization"]
        configuration.sensitiveQueryItems = ["token"]
        configuration.sensitiveDataFields = ["password", "accessToken", "refreshToken"]
        var options = URLSessionProxy.Options()
        options.isMockingEnabled = false
        return URLSessionProxy(configuration: .default, logger: NetworkLogger(configuration: configuration), options: options)
    }()

    static func debug(_ message: @autoclosure () -> String, _ category: Category = .app, _ metadata: [String: String] = [:],
                      file: String = #fileID, function: String = #function, line: UInt = #line) {
        write(.debug, message(), category, metadata, file, function, line)
    }

    static func info(_ message: @autoclosure () -> String, _ category: Category = .app, _ metadata: [String: String] = [:],
                     file: String = #fileID, function: String = #function, line: UInt = #line) {
        write(.info, message(), category, metadata, file, function, line)
    }

    static func notice(_ message: @autoclosure () -> String, _ category: Category = .app, _ metadata: [String: String] = [:],
                       file: String = #fileID, function: String = #function, line: UInt = #line) {
        write(.notice, message(), category, metadata, file, function, line)
    }

    static func warning(_ message: @autoclosure () -> String, _ category: Category = .app, _ metadata: [String: String] = [:],
                        file: String = #fileID, function: String = #function, line: UInt = #line) {
        write(.warning, message(), category, metadata, file, function, line)
    }

    static func error(_ message: @autoclosure () -> String, _ category: Category = .app, _ metadata: [String: String] = [:],
                      file: String = #fileID, function: String = #function, line: UInt = #line) {
        write(.error, message(), category, metadata, file, function, line)
    }

    static func error(_ error: any Error, _ category: Category = .app, _ context: String? = nil,
                      file: String = #fileID, function: String = #function, line: UInt = #line) {
        let text = context.map { "\($0): \(error.localizedDescription)" } ?? error.localizedDescription
        write(.error, text, category, ["type": String(describing: type(of: error))], file, function, line)
    }

    private static func write(_ level: LoggerStore.Level, _ message: String, _ category: Category, _ metadata: [String: String],
                              _ file: String, _ function: String, _ line: UInt) {
        LoggerStore.shared.storeMessage(
            label: category.rawValue,
            level: level,
            message: message,
            metadata: metadata.isEmpty ? nil : metadata.mapValues { .string($0) },
            file: file,
            function: function,
            line: line
        )
        let details = metadata.isEmpty ? "" : " " + metadata.sorted { $0.key < $1.key }.map { "\($0)=\($1)" }.joined(separator: " ")
        osLoggers[category]?.log(level: level.osLogType, "\(message, privacy: .public)\(details, privacy: .public)")
    }
}

private extension LoggerStore.Level {
    nonisolated var osLogType: OSLogType {
        switch self {
        case .trace, .debug: .debug
        case .info, .notice: .info
        case .warning, .error: .error
        case .critical: .fault
        }
    }
}
