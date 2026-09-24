import AppKit
import Foundation
import Observation
import ShireCore

enum SidebarItem: Hashable {
    case readiness
    case alerts
    case service(String)
    case config
}

/// Result of running the `shire` command line on the app's behalf.
struct CommandOutcome: Identifiable {
    let id = UUID()
    var title: String
    var succeeded: Bool
    var output: String
}

/// The app's view of Shire, refreshed in the background. Actions go through the `shire` CLI so they behave exactly
/// as they do in Terminal (same builds, same launchctl calls, same messages).
@MainActor
@Observable
final class ShireModel {
    let paths = ShirePaths.current()

    var snapshot: ShireSnapshot?
    var selection: SidebarItem? = .readiness
    var busy: Set<String> = []
    var lastOutcome: CommandOutcome?
    /// Shows the "Add service…" sheet in the main window.
    var addingService = false
    /// Bumped when the app writes config.yaml, so an open editor reloads it.
    var configRevision = 0
    @ObservationIgnored var showWindow: (() -> Void)?

    @ObservationIgnored private var facts: SystemFacts?
    @ObservationIgnored private var factsGatheredAt: Date?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored let notifications = AppNotifications()

    init() {
        start()
    }

    func start() {
        guard timer == nil else { return }
        refresh(forceSystem: true)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Services every 5 seconds; readiness facts (a few shell calls) every minute or on demand.
    func refresh(forceSystem: Bool = false) {
        guard !refreshing else { return }
        refreshing = true
        AppPresence.touch(paths)
        let paths = self.paths
        let needFacts = forceSystem || factsGatheredAt.map { Date().timeIntervalSince($0) > 60 } ?? true
        let cached = needFacts ? nil : facts
        Task.detached {
            let gathered = needFacts ? SystemProbe(paths: paths).gather() : cached
            let snapshot = await ShireSnapshot.build(paths: paths, includeSystem: gathered != nil, facts: gathered)
            await MainActor.run {
                if needFacts {
                    self.facts = gathered
                    self.factsGatheredAt = Date()
                }
                self.snapshot = snapshot
                self.refreshing = false
                self.notifications.deliverNew(from: paths)
            }
        }
    }

    // MARK: Derived

    var overall: ShireSnapshot.Overall { snapshot?.overall ?? .notRunning(reason: "Loading…") }

    var headline: String {
        switch overall {
        case .healthy: return "All good"
        case .attention: return "Needs attention"
        case .notRunning: return "Shire isn’t running"
        }
    }

    var subtitle: String {
        guard let snapshot else { return "Checking…" }
        if case .notRunning(let reason) = overall { return reason }
        var parts: [String] = [Host.current().localizedName ?? "This Mac"]
        if !snapshot.services.isEmpty { parts.append("\(snapshot.healthyCount) of \(snapshot.services.count) healthy") }
        if let boot = snapshot.facts?.bootTime { parts.append("up \(Readiness.describe(Date().timeIntervalSince(boot)))") }
        return parts.joined(separator: " · ")
    }

    var readinessWarnings: [ReadinessCheck] { Readiness.warnings(snapshot?.readiness ?? []) }

    func service(_ name: String) -> ShireSnapshot.Service? {
        snapshot?.services.first { $0.name == name }
    }

    // MARK: Actions

    func restart(_ name: String) { runShire(["restart", name], title: "Restart \(name)", key: name) }
    func stop(_ name: String) { runShire(["stop", name], title: "Stop \(name)", key: name) }
    func start(_ name: String) { runShire(["start", name], title: "Start \(name)", key: name) }
    func apply() { runShire(["apply"], title: "Apply changes", key: "apply") }

    func addService() {
        addingService = true
        showWindow?()
    }

    func openConfig() {
        NSWorkspace.shared.open(paths.configFile)
    }

    func revealLogs(_ name: String) {
        NSWorkspace.shared.activateFileViewerSelecting([paths.stderrLog(for: name)])
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func runShire(_ arguments: [String], title: String, key: String) {
        guard !busy.contains(key) else { return }
        busy.insert(key)
        Task.detached {
            let outcome = ShireCLI.run(arguments, title: title)
            await MainActor.run {
                self.busy.remove(key)
                self.lastOutcome = outcome
                self.refresh(forceSystem: key == "apply")
            }
        }
    }
}

/// Finds and runs the installed `shire` command.
enum ShireCLI {
    static let candidates = [
        "\(NSHomeDirectory())/.local/bin/shire",
        "/opt/homebrew/bin/shire",
        "/usr/local/bin/shire",
    ]

    static var path: String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    static func run(_ arguments: [String], title: String) -> CommandOutcome {
        guard let path else {
            return CommandOutcome(title: title, succeeded: false, output: "The shire command isn’t installed. Run `make install` in the Shire repo.")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        // Builds run `pnpm` and friends; give them the login PATH the CLI resolves anyway.
        environment["PATH"] = (environment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
        let result = (try? SystemCommandRunner().run(path, arguments, environment: environment, timeout: 900))
            ?? ShellResult(status: 1, stdout: "", stderr: "Couldn’t run \(path)")
        let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return CommandOutcome(title: title, succeeded: result.status == 0, output: output)
    }
}
