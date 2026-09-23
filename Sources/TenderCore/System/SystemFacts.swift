import CoreGraphics
import Foundation

/// Everything readiness checks look at, gathered once. Kept as plain data so the checks themselves are pure and testable.
public struct SystemFacts: Equatable, Sendable {
    public var fileVaultOn: Bool?
    public var autoLoginUser: String?
    public var autoInstallMacOSUpdates: Bool?
    public var pendingUpdates: [String]
    /// nil when this Mac doesn't offer the setting (most laptops).
    public var autoRestartAfterPowerLoss: Bool?
    public var power: PowerInfo
    public var externalDisplays: Int
    public var diskFreeBytes: Int64?
    public var bootTime: Date?
    public var tailscale: TailscaleState
    public var agentLoaded: Bool
    public var agentState: AgentState?

    public init(fileVaultOn: Bool? = nil, autoLoginUser: String? = nil, autoInstallMacOSUpdates: Bool? = nil, pendingUpdates: [String] = [],
                autoRestartAfterPowerLoss: Bool? = nil, power: PowerInfo = PowerInfo(hasBattery: false, onACPower: true),
                externalDisplays: Int = 0, diskFreeBytes: Int64? = nil, bootTime: Date? = nil,
                tailscale: TailscaleState = .notInstalled, agentLoaded: Bool = false, agentState: AgentState? = nil) {
        self.fileVaultOn = fileVaultOn
        self.autoLoginUser = autoLoginUser
        self.autoInstallMacOSUpdates = autoInstallMacOSUpdates
        self.pendingUpdates = pendingUpdates
        self.autoRestartAfterPowerLoss = autoRestartAfterPowerLoss
        self.power = power
        self.externalDisplays = externalDisplays
        self.diskFreeBytes = diskFreeBytes
        self.bootTime = bootTime
        self.tailscale = tailscale
        self.agentLoaded = agentLoaded
        self.agentState = agentState
    }
}

/// Collects `SystemFacts` from the running Mac. Every source is read-only and needs no admin rights.
public struct SystemProbe: Sendable {
    public var runner: CommandRunning
    public var paths: TenderPaths
    public var launchControl: LaunchControl

    public init(paths: TenderPaths, runner: CommandRunning = SystemCommandRunner(), launchControl: LaunchControl = SystemLaunchControl()) {
        self.paths = paths
        self.runner = runner
        self.launchControl = launchControl
    }

    public func gather() -> SystemFacts {
        var facts = SystemFacts()
        if let result = try? runner.run("/usr/bin/fdesetup", ["status"], environment: nil, timeout: 5) {
            facts.fileVaultOn = Self.parseFileVault(result.stdout)
        }
        if let loginwindow = readPreferences("/Library/Preferences/com.apple.loginwindow") {
            facts.autoLoginUser = loginwindow["autoLoginUser"] as? String
        }
        if let updates = readPreferences("/Library/Preferences/com.apple.SoftwareUpdate") {
            (facts.autoInstallMacOSUpdates, facts.pendingUpdates) = Self.parseSoftwareUpdate(updates)
        }
        if let result = try? runner.run("/usr/bin/pmset", ["-g"], environment: nil, timeout: 5) {
            facts.autoRestartAfterPowerLoss = Self.parsePmset(result.stdout)["autorestart"].map { $0.hasPrefix("1") }
        }
        facts.power = PowerInfo.current()
        facts.externalDisplays = Self.externalDisplayCount()
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) {
            facts.diskFreeBytes = values.volumeAvailableCapacityForImportantUsage
        }
        facts.bootTime = Self.bootTime()
        facts.tailscale = Tailscale.status(runner: runner)
        facts.agentLoaded = launchControl.isLoaded(LaunchAgentBuilder.agentLabel)
        facts.agentState = AgentState.read(from: paths.agentStateFile)
        return facts
    }

    private func readPreferences(_ domainPath: String) -> [String: Any]? {
        guard let result = try? runner.run("/usr/bin/defaults", ["export", domainPath, "-"], environment: nil, timeout: 5),
              result.status == 0, let data = result.stdout.data(using: .utf8)
        else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    // MARK: Parsers (static so tests can feed them real output)

    static func parseFileVault(_ output: String) -> Bool? {
        if output.contains("FileVault is On") { return true }
        if output.contains("FileVault is Off") { return false }
        return nil
    }

    /// `pmset -g` lines look like ` sleep                1 (sleep prevented by …)`.
    static func parsePmset(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") where line.hasPrefix(" ") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Keys can contain spaces ("Sleep On Power Button"); the value starts after a run of 2+ spaces.
            guard let gap = trimmed.range(of: "  ") else { continue }
            let key = String(trimmed[..<gap.lowerBound])
            let value = trimmed[gap.upperBound...].trimmingCharacters(in: .whitespaces)
            values[key] = value
        }
        return values
    }

    static func parseSoftwareUpdate(_ prefs: [String: Any]) -> (Bool?, [String]) {
        let autoInstall = (prefs["AutomaticallyInstallMacOSUpdates"] as? NSNumber)?.boolValue
        let pending = (prefs["RecommendedUpdates"] as? [[String: Any]] ?? []).compactMap { $0["Display Name"] as? String }
        return (autoInstall, pending)
    }

    static func externalDisplayCount() -> Int {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return 0 }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return 0 }
        return displays.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.count
    }

    public static func bootTime() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &time, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }
}
