import Foundation

/// Whether the menu bar app is running. It posts notifications itself (as Shire, not Script Editor), so shire-agent
/// only falls back to osascript when the app isn't there.
public enum AppPresence {
    public static let staleAfter: TimeInterval = 20

    public static func touch(_ paths: ShirePaths, now: Date = Date()) {
        let url = paths.appHeartbeatFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    }

    public static func clear(_ paths: ShirePaths) {
        try? FileManager.default.removeItem(at: paths.appHeartbeatFile)
    }

    public static func isRunning(_ paths: ShirePaths, now: Date = Date()) -> Bool {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: paths.appHeartbeatFile.path))?[.modificationDate] as? Date else {
            return false
        }
        return now.timeIntervalSince(modified) < staleAfter
    }
}
