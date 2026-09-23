import Foundation

public enum TailscaleState: Equatable, Sendable {
    case notInstalled
    /// Installed, but `tailscale status` couldn't reach the daemon.
    case daemonNotRunning(detail: String)
    /// The daemon answered but isn't connected (`Stopped`, `NeedsLogin`, `Starting`, …).
    case notConnected(backendState: String)
    case connected(hostName: String, dnsName: String?, ipv4: String?)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

public enum Tailscale {
    /// Where the CLI lives for the App Store / standalone app and for Homebrew.
    public static let candidatePaths = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    public static func locateCLI(fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        candidatePaths.first(where: fileExists)
    }

    public static func status(runner: CommandRunning = SystemCommandRunner(), cli: String? = locateCLI()) -> TailscaleState {
        guard let cli else { return .notInstalled }
        guard let result = try? runner.run(cli, ["status", "--json"], environment: nil, timeout: 5) else {
            return .daemonNotRunning(detail: "couldn’t run \(cli)")
        }
        if result.timedOut { return .daemonNotRunning(detail: "no answer from tailscaled") }
        return parse(json: result.stdout, stderr: result.stderr)
    }

    static func parse(json: String, stderr: String = "") -> TailscaleState {
        struct Status: Decodable {
            struct Peer: Decodable {
                var HostName: String?
                var DNSName: String?
                var TailscaleIPs: [String]?
            }
            var BackendState: String?
            var Self_: Peer?

            enum CodingKeys: String, CodingKey {
                case BackendState
                case Self_ = "Self"
            }
        }
        guard let data = json.data(using: .utf8), let status = try? JSONDecoder().decode(Status.self, from: data), let backend = status.BackendState else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .daemonNotRunning(detail: detail.isEmpty ? "tailscaled isn’t running" : detail)
        }
        guard backend == "Running", let me = status.Self_ else {
            return .notConnected(backendState: backend)
        }
        let dns = me.DNSName.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        let ipv4 = me.TailscaleIPs?.first { $0.contains(".") }
        return .connected(hostName: me.HostName ?? "this Mac", dnsName: dns, ipv4: ipv4)
    }
}
