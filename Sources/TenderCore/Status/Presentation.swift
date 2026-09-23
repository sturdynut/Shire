import Foundation

extension ProcessState {
    /// Short word for menus and the phone page: Running / Crash-looping / Stopped…
    public var menuLabel: String {
        switch self {
        case .running: return "Running"
        case .crashLooping: return "Crash-looping"
        case .exited(let code): return code == 0 ? "Exited" : "Exited \(code)"
        case .stopped: return "Stopped"
        case .notInstalled: return "Not applied"
        case .external(let running, _): return running ? "Running" : "Stopped"
        case .externalMissing: return "Not found"
        }
    }
}

extension TenderSnapshot.Service {
    public enum Tone: String, Sendable { case good, warn, bad, off }

    public var tone: Tone {
        switch process {
        case .crashLooping: return .bad
        case .exited(let code) where code != 0: return .bad
        case .stopped, .notInstalled, .externalMissing, .external(false, _): return .off
        default: break
        }
        if health?.isHealthy == false { return .warn }
        return .good
    }

    public var stateText: String {
        if case .crashLooping = process { return "Crash-looping" }
        switch health {
        case .healthy?: return "Healthy"
        case .unhealthy?: return process.isProblem ? process.menuLabel : "Unhealthy"
        case nil: return process.menuLabel
        }
    }

    /// One line under the name: the cause if there is one, else the health detail.
    public var detailText: String {
        if let cause { return cause }
        if case .crashLooping(let code, let exits, let window) = process { return "Exit \(code) · \(exits) failures in \(window)" }
        var text = health?.detail ?? config.external.map { "watched · \($0)" } ?? "no health check"
        if let note = healthNote, health?.isHealthy == false { text += " · \(note)" }
        return text
    }
}
