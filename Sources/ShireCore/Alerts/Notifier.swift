import Foundation

public protocol Notifying: Sendable {
    func deliver(_ alert: AlertMessage)
}

/// Posts a macOS notification through `osascript`. A command-line tool can't use the notification framework
/// directly (it needs an app bundle), so until the menu bar app exists these show as coming from Script Editor.
public struct OsascriptNotifier: Notifying {
    public var runner: CommandRunning

    public init(runner: CommandRunning = SystemCommandRunner()) {
        self.runner = runner
    }

    public func deliver(_ alert: AlertMessage) {
        let script = "display notification \(Self.quote(alert.body)) with title \(Self.quote("Shire")) subtitle \(Self.quote(alert.title))"
        _ = try? runner.run("/usr/bin/osascript", ["-e", script], environment: nil, timeout: 10)
    }

    /// An AppleScript string literal.
    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Every alert, delivered or not, as JSON lines. `shire alerts` reads it; the phone page will too.
public struct AlertLog: Sendable {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    public func append(_ alert: AlertMessage) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(alert) else { return }
        data.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    public func recent(_ count: Int) -> [AlertMessage] {
        LogReader.tail(url, lines: count).compactMap { try? JSONCoding.decoder.decode(AlertMessage.self, from: Data($0.utf8)) }
    }
}
