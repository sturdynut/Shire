import Foundation

/// Where Shire reads and writes things. Everything is injectable so tests never touch the real home folder.
public struct ShirePaths: Sendable, Equatable {
    public var home: URL
    public var configFile: URL
    public var launchAgentsDir: URL
    public var logsDir: URL
    public var stateDir: URL

    public init(home: URL, configFile: URL? = nil) {
        self.home = home
        self.configFile = configFile ?? home.appending(path: ".config/shire/config.yaml")
        self.launchAgentsDir = home.appending(path: "Library/LaunchAgents")
        self.logsDir = home.appending(path: "Library/Logs/shire")
        self.stateDir = home.appending(path: "Library/Application Support/Shire")
    }

    /// The real locations for the current user. `SHIRE_CONFIG` overrides the config file.
    public static func current(configOverride: String? = nil) -> ShirePaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let override = configOverride ?? ProcessInfo.processInfo.environment["SHIRE_CONFIG"]
        let config = override.map { URL(fileURLWithPath: PathExpander.expand($0, home: home.path)) }
        return ShirePaths(home: home, configFile: config)
    }

    public var eventsDir: URL { stateDir.appending(path: "events") }
    public var agentStateFile: URL { stateDir.appending(path: "agent.json") }
    public var agentLog: URL { logsDir.appending(path: "shire-agent.log") }
    public var incidentsFile: URL { stateDir.appending(path: "incidents.json") }
    public var alertsFile: URL { stateDir.appending(path: "alerts.jsonl") }
    /// Touched by the menu bar app while it runs.
    public var appHeartbeatFile: URL { stateDir.appending(path: "app-heartbeat") }
    public var vapidKeyFile: URL { stateDir.appending(path: "vapid-key") }
    public var pushSubscriptionsFile: URL { stateDir.appending(path: "push-subscriptions.json") }

    public func stdoutLog(for service: String) -> URL { logsDir.appending(path: "\(service).stdout.log") }
    public func stderrLog(for service: String) -> URL { logsDir.appending(path: "\(service).stderr.log") }
    /// Where launchd writes anything the wrapper itself prints before it can open the service logs.
    public func wrapperLog(for service: String) -> URL { logsDir.appending(path: "\(service).shire.log") }
    public func events(for service: String) -> URL { eventsDir.appending(path: "\(service).jsonl") }
    public func plist(forLabel label: String) -> URL { launchAgentsDir.appending(path: "\(label).plist") }
}

public enum PathExpander {
    /// Expands a leading `~` and makes relative paths absolute against `base`.
    public static func expand(_ path: String, home: String, base: String? = nil) -> String {
        var result = path
        if result == "~" {
            result = home
        } else if result.hasPrefix("~/") {
            result = home + result.dropFirst(1)
        }
        if !result.hasPrefix("/"), let base {
            result = (base as NSString).appendingPathComponent(result)
        }
        return (result as NSString).standardizingPath
    }
}
