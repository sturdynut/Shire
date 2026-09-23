import Foundation

public struct ReadinessCheck: Equatable, Sendable {
    public enum Level: String, Sendable {
        case ok
        /// A known, accepted trade-off (FileVault on). Shown, never counted as a warning.
        case info
        case warn
    }

    public var id: String
    public var level: Level
    public var title: String
    public var detail: String
    public var fix: String?

    public init(_ id: String, _ level: Level, _ title: String, _ detail: String, fix: String? = nil) {
        self.id = id
        self.level = level
        self.title = title
        self.detail = detail
        self.fix = fix
    }
}

/// Answers "will this Mac keep serving without you?" from gathered facts. Pure, so every branch is testable.
public enum Readiness {
    public static let lowDiskBytes: Int64 = 10 * 1_000_000_000

    public static func evaluate(_ facts: SystemFacts, config: TenderConfig, now: Date = Date()) -> [ReadinessCheck] {
        var checks: [ReadinessCheck] = []
        checks.append(updates(facts))
        checks.append(login(facts))
        if let check = powerLoss(facts) { checks.append(check) }
        checks.append(agent(facts, now: now))
        checks.append(keepAwake(facts, config: config, now: now))
        if let check = lid(facts) { checks.append(check) }
        if let check = battery(facts) { checks.append(check) }
        if let check = disk(facts) { checks.append(check) }
        if config.presets.tailscale.enabled { checks.append(tailscale(facts)) }
        if let boot = facts.bootTime {
            checks.append(ReadinessCheck("uptime", .info, "Up \(describe(now.timeIntervalSince(boot)))", "since the last restart"))
        }
        return checks
    }

    public static func warnings(_ checks: [ReadinessCheck]) -> [ReadinessCheck] {
        checks.filter { $0.level == .warn }
    }

    // MARK: Individual checks

    static func updates(_ facts: SystemFacts) -> ReadinessCheck {
        let waiting = facts.pendingUpdates.isEmpty ? "" : " \(facts.pendingUpdates.count) waiting: \(facts.pendingUpdates.prefix(3).joined(separator: ", "))."
        switch facts.autoInstallMacOSUpdates {
        case true?:
            let after = facts.fileVaultOn == true ? " With FileVault on, it then waits at the login screen and nothing runs until you log in." : ""
            return ReadinessCheck("updates", .warn, "macOS installs updates and restarts on its own",
                                  "An overnight update can restart this Mac.\(after)\(waiting)",
                                  fix: "System Settings → General → Software Update → Automatic Updates: turn off “Install macOS updates”. Install them when you’re around.")
        case false?:
            return ReadinessCheck("updates", .ok, "macOS updates wait for you", "Updates won’t restart this Mac on their own.\(waiting)")
        case nil:
            return ReadinessCheck("updates", .info, "Couldn’t read the automatic update setting", "Check System Settings → General → Software Update.")
        }
    }

    static func login(_ facts: SystemFacts) -> ReadinessCheck {
        if facts.fileVaultOn == true {
            return ReadinessCheck("login", .info, "FileVault is on: you log in after restarts",
                                  "Your choice: disk encryption stays on, so services and Tailscale start only after you log in. While the Mac waits at the login screen nothing can alert you.")
        }
        if let user = facts.autoLoginUser {
            return ReadinessCheck("login", .ok, "Logs in automatically after restarts", "as \(user), so services come back on their own.")
        }
        return ReadinessCheck("login", .warn, "After a restart, services wait until someone logs in",
                              "Automatic login is off.", fix: "System Settings → Users & Groups → Automatically log in as…")
    }

    static func powerLoss(_ facts: SystemFacts) -> ReadinessCheck? {
        switch facts.autoRestartAfterPowerLoss {
        case true?:
            return ReadinessCheck("power-loss", .ok, "Restarts after a power cut", "The Mac turns back on when power returns.")
        case false?:
            return ReadinessCheck("power-loss", .warn, "Stays off after a power cut", "When power returns, this Mac won’t turn itself back on.",
                                  fix: "System Settings → Energy → “Start up automatically after a power failure”, or `sudo pmset -a autorestart 1`.")
        case nil:
            return facts.power.hasBattery ? nil : ReadinessCheck("power-loss", .info, "Couldn’t read the power-failure restart setting", "Check System Settings → Energy.")
        }
    }

    static func agent(_ facts: SystemFacts, now: Date) -> ReadinessCheck {
        guard facts.agentLoaded else {
            return ReadinessCheck("agent", .warn, "tender-agent isn’t installed", "Keep-awake (and later, health checks and alerts) need it.",
                                  fix: "Run `tender apply`.")
        }
        guard let state = facts.agentState, state.isFresh(now: now) else {
            return ReadinessCheck("agent", .warn, "tender-agent isn’t responding", "It’s loaded but hasn’t reported in the last \(Int(AgentState.staleAfter)) seconds.",
                                  fix: "Check `~/Library/Logs/tender/tender-agent.log`, then `tender apply`.")
        }
        if let error = state.configError {
            return ReadinessCheck("agent", .warn, "tender-agent can’t read config.yaml", "\(error) It keeps the last good settings.", fix: "Run `tender validate`.")
        }
        return ReadinessCheck("agent", .ok, "tender-agent is running", "pid \(state.pid), approved as a background item.")
    }

    static func keepAwake(_ facts: SystemFacts, config: TenderConfig, now: Date) -> ReadinessCheck {
        guard config.serverMode.keepAwake else {
            return ReadinessCheck("keep-awake", .info, "Keep-awake is off", "serverMode.keepAwake is false, so macOS may sleep when idle.")
        }
        guard let state = facts.agentState, state.isFresh(now: now) else {
            return ReadinessCheck("keep-awake", .warn, "Nothing is keeping the Mac awake", "tender-agent holds the keep-awake, and it isn’t running.", fix: "Run `tender apply`.")
        }
        if state.keepAwake.held {
            return ReadinessCheck("keep-awake", .ok, "Idle sleep is blocked", "tender-agent holds a power assertion (\(state.keepAwake.reason)). The display can still sleep.")
        }
        return ReadinessCheck("keep-awake", .warn, "Keep-awake is released", state.keepAwake.reason)
    }

    static func lid(_ facts: SystemFacts) -> ReadinessCheck? {
        guard facts.power.hasBattery else { return nil }
        if facts.power.onACPower, facts.externalDisplays > 0 {
            return ReadinessCheck("lid", .ok, "The lid can close", "On power with an external display, so a closed lid won’t sleep the Mac. Unplug either and it will.")
        }
        let missing = facts.power.onACPower ? "no external display is connected" : "it’s on battery"
        return ReadinessCheck("lid", .warn, "Closing the lid will sleep this Mac",
                              "A MacBook stays awake with the lid closed only on power with an external display, and \(missing).",
                              fix: "Keep the lid open, or connect power and a display.")
    }

    static func battery(_ facts: SystemFacts) -> ReadinessCheck? {
        guard facts.power.hasBattery else { return nil }
        let percent = facts.power.batteryPercent.map { "\($0)%" } ?? "battery"
        if facts.power.onACPower {
            return ReadinessCheck("power", .ok, "On power", "Battery at \(percent).")
        }
        return ReadinessCheck("power", .warn, "Running on battery (\(percent))", "Keep-awake is released on battery, and the Mac will sleep when the battery runs low.",
                              fix: "Plug in the power adapter.")
    }

    static func disk(_ facts: SystemFacts) -> ReadinessCheck? {
        guard let free = facts.diskFreeBytes else { return nil }
        let text = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        if free < lowDiskBytes {
            return ReadinessCheck("disk", .warn, "Low on disk space: \(text) free", "Logs, builds and databases fail in confusing ways when the disk fills.",
                                  fix: "Free some space; `tender logs` files rotate, but other apps’ may not.")
        }
        return ReadinessCheck("disk", .ok, "\(text) free on disk", "Warns below \(ByteCountFormatter.string(fromByteCount: lowDiskBytes, countStyle: .file)).")
    }

    static func tailscale(_ facts: SystemFacts) -> ReadinessCheck {
        switch facts.tailscale {
        case .connected(let host, let dns, let ip):
            let address = [dns, ip].compactMap { $0 }.joined(separator: " · ")
            return ReadinessCheck("tailscale", .ok, "Tailscale is connected", "\(host)\(address.isEmpty ? "" : " — \(address)")")
        case .notConnected(let backend):
            return ReadinessCheck("tailscale", .warn, "Tailscale isn’t connected", "State: \(backend). You can’t reach this Mac from your phone.",
                                  fix: backend == "NeedsLogin" ? "Run `tailscale up` and log in." : "Open Tailscale, or run `tailscale up`.")
        case .daemonNotRunning(let detail):
            return ReadinessCheck("tailscale", .warn, "Tailscale isn’t running", detail, fix: "Start the Tailscale app, or `sudo brew services start tailscale`.")
        case .notInstalled:
            return ReadinessCheck("tailscale", .warn, "Tailscale isn’t installed", "presets.tailscale is on, but no Tailscale CLI was found.",
                                  fix: "Install Tailscale from tailscale.com or with `brew install tailscale`.")
        }
    }

    static func describe(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }
}
