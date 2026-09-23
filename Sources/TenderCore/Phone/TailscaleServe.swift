import Foundation

/// Shares the phone page on your tailnet with `tailscale serve`, touching only Tender's own HTTPS port.
public struct TailscaleServe: Sendable {
    public var runner: CommandRunning
    public var cli: String?

    public init(runner: CommandRunning = SystemCommandRunner(), cli: String? = Tailscale.locateCLI()) {
        self.runner = runner
        self.cli = cli
    }

    public enum Outcome: Equatable, Sendable {
        case alreadyServing(url: String)
        case started(url: String)
        case stopped
        case notNeeded
        case portTaken(by: String)
        case failed(String)
    }

    /// What the tailnet port currently proxies to, from `tailscale serve status --json`.
    static func currentProxy(json: String, port: Int) -> String? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = root["Web"] as? [String: Any] else { return nil }
        for (hostPort, value) in web where hostPort.hasSuffix(":\(port)") {
            let handlers = (value as? [String: Any])?["Handlers"] as? [String: Any]
            let root = handlers?["/"] as? [String: Any]
            return root?["Proxy"] as? String ?? "something else"
        }
        return nil
    }

    public func ensure(port: Int, localPort: Int, dnsName: String?) -> Outcome {
        guard let cli else { return .failed("Tailscale isn’t installed") }
        let target = "http://127.0.0.1:\(localPort)"
        let url = "https://\(dnsName ?? "this-mac")\(port == 443 ? "" : ":\(port)")"
        let status = (try? runner.run(cli, ["serve", "status", "--json"], environment: nil, timeout: 10))?.stdout ?? ""
        if let current = Self.currentProxy(json: status, port: port) {
            return current == target ? .alreadyServing(url: url) : .portTaken(by: current)
        }
        guard let result = try? runner.run(cli, ["serve", "--bg", "--https=\(port)", target], environment: nil, timeout: 20) else {
            return .failed("couldn’t run tailscale serve")
        }
        if result.status != 0 {
            return .failed((result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .started(url: url)
    }

    /// Stops sharing Tender's port, only if it still points at Tender.
    public func remove(port: Int, localPort: Int) -> Outcome {
        guard let cli else { return .notNeeded }
        let status = (try? runner.run(cli, ["serve", "status", "--json"], environment: nil, timeout: 10))?.stdout ?? ""
        guard Self.currentProxy(json: status, port: port) == "http://127.0.0.1:\(localPort)" else { return .notNeeded }
        let result = try? runner.run(cli, ["serve", "--https=\(port)", "off"], environment: nil, timeout: 20)
        return result?.status == 0 ? .stopped : .failed((result?.stderr ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The tailnet login that owns this Mac: the only one allowed to press Restart on the phone page.
    public func ownerLogin() -> String? {
        guard let cli, let result = try? runner.run(cli, ["status", "--json"], environment: nil, timeout: 5),
              let data = result.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let me = root["Self"] as? [String: Any],
              let users = root["User"] as? [String: Any]
        else { return nil }
        let id = (me["UserID"] as? NSNumber)?.stringValue ?? "\(me["UserID"] ?? "")"
        return (users[id] as? [String: Any])?["LoginName"] as? String
    }
}
