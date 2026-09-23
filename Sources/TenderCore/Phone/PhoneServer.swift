import Foundation

/// What the phone page shows, as JSON.
struct PhoneStatus: Encodable {
    struct Service: Encodable {
        var name: String
        var tone: String
        var state: String
        var detail: String
        var external: Bool
        var canRestart: Bool
        var process: String
        var health: String?
        var healthNote: String?
        var cause: String?
        var lastExit: Int32?
        var failures: Int?
        var window: String?
        var command: String?
    }

    struct Row: Encodable {
        var name: String
        var value: String
        var level: String
    }

    struct Check: Encodable {
        var title: String
        var detail: String
        var fix: String?
    }

    struct Incident: Encodable {
        var title: String
        var since: Date
    }

    struct Alert: Encodable {
        var time: Date
        var title: String
        var body: String
        var kind: String
    }

    struct Viewer: Encodable {
        var login: String?
        var canRestart: Bool
        var reason: String?
    }

    struct Push: Encodable {
        var enabled: Bool
        var publicKey: String?
        var subscriptions: Int
    }

    var host: String
    var updated: Date
    var headline: String
    var tone: String
    var summary: String
    var services: [Service]
    var system: [Row]
    var readiness: [Check]
    var incidents: [Incident]
    var alerts: [Alert]
    var viewer: Viewer
    var push: Push
}

/// The phone page's server, run inside tender-agent. It listens on 127.0.0.1 only; `tailscale serve` puts it on your
/// tailnet over HTTPS and tells it who is asking (the `Tailscale-User-Login` header).
public final class PhoneServer: @unchecked Sendable {
    public typealias ConfigProvider = @Sendable () -> TenderConfig?
    public typealias FactsProvider = @Sendable () -> SystemFacts?

    private let paths: TenderPaths
    private let owner: String?
    private let config: ConfigProvider
    private let facts: FactsProvider
    private let launchControl: LaunchControl
    private let onPushTest: @Sendable (AlertMessage) async -> Void
    private var server: HTTPServer?

    public init(paths: TenderPaths, owner: String?, launchControl: LaunchControl = SystemLaunchControl(),
                config: @escaping ConfigProvider, facts: @escaping FactsProvider,
                onPushTest: @escaping @Sendable (AlertMessage) async -> Void = { _ in }) {
        self.paths = paths
        self.owner = owner
        self.launchControl = launchControl
        self.config = config
        self.facts = facts
        self.onPushTest = onPushTest
    }

    public var port: UInt16 { server?.port ?? 0 }

    public func start(port: Int) throws {
        let server = HTTPServer(port: UInt16(port)) { [weak self] request in
            guard let self else { return .text("Stopping", status: 503) }
            return await self.handle(request)
        }
        try server.start()
        self.server = server
    }

    public func stop() {
        server?.stop()
        server = nil
    }

    // MARK: Routing

    func handle(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        let parts = request.path.split(separator: "/").map(String.init)
        let get = request.method == "GET", post = request.method == "POST"

        if get, parts.isEmpty || parts == ["index.html"] {
            return .text(PhonePage.html, type: "text/html; charset=utf-8")
        }
        if get, parts == ["manifest.webmanifest"] { return .text(PhonePage.manifest, type: "application/manifest+json") }
        if get, parts == ["sw.js"] {
            var response = HTTPServer.Response.text(PhonePage.serviceWorker, type: "text/javascript")
            response.headers["Service-Worker-Allowed"] = "/"
            return response
        }
        if get, parts == ["icon.svg"] { return .text(PhonePage.iconSVG, type: "image/svg+xml") }
        if get, parts == ["apple-touch-icon.png"] {
            return HTTPServer.Response(headers: ["Content-Type": "image/png", "Cache-Control": "max-age=86400"], body: PhonePage.iconPNG)
        }
        if get, parts == ["api", "status"] { return .json(await status(viewer: viewer(request))) }
        if parts.count == 4, parts[0] == "api", parts[1] == "services" {
            let name = parts[2]
            if get, parts[3] == "logs" { return logs(name, lines: Int(request.query["lines"] ?? "") ?? 20) }
            if post, parts[3] == "restart" { return restart(name, request: request) }
        }
        if post, parts == ["api", "push", "subscribe"] { return subscribe(request) }
        if post, parts == ["api", "push", "unsubscribe"] { return unsubscribe(request) }
        if post, parts == ["api", "push", "test"] {
            guard isOwner(request), request.headers["x-tender"] == "1" else { return forbidden("Only this Mac’s owner can do that.") }
            await onPushTest(AlertMessage(time: Date(), kind: .info, title: "Test alert", body: "Tender’s alerts reach this phone."))
            return .json(["ok": true])
        }
        return .text("Not found", status: 404)
    }

    // MARK: Identity

    private func viewer(_ request: HTTPServer.Request) -> String? {
        request.headers["tailscale-user-login"]
    }

    private func isOwner(_ request: HTTPServer.Request) -> Bool {
        guard let login = viewer(request), let owner else { return false }
        return login.caseInsensitiveCompare(owner) == .orderedSame
    }

    private func forbidden(_ message: String) -> HTTPServer.Response {
        .json(["ok": AnyEncodable(false), "message": AnyEncodable(message)], status: 403)
    }

    /// Restart needs: actions allowed in config, the owner's tailnet login, and our own header (so another site
    /// can't make your browser post here: custom headers need a CORS preflight this server never approves).
    private func restartPermission(_ request: HTTPServer.Request) -> String? {
        guard config()?.remote.actions == .restart else { return "Restart is off (remote.actions: read-only)." }
        guard viewer(request) != nil else { return "Open this page through Tailscale to restart services." }
        guard isOwner(request) else { return "Only \(owner ?? "this Mac’s owner") can restart services." }
        return nil
    }

    // MARK: Endpoints

    func status(viewer login: String?) async -> PhoneStatus {
        let snapshot = await TenderSnapshot.build(paths: paths, launchControl: launchControl, includeSystem: false, facts: facts())
        let request = HTTPServer.Request(method: "GET", path: "/", headers: login.map { ["tailscale-user-login": $0] } ?? [:])
        let denial = restartPermission(request)
        let config = snapshot.config

        let services = snapshot.services.map { service -> PhoneStatus.Service in
            var loop: (Int32, Int, String)?
            if case .crashLooping(let code, let exits, let window) = service.process { loop = (code, exits, window.description) }
            let command = service.config.external.map { "external · \($0)" }
                ?? ([service.config.command ?? ""] + service.config.args).joined(separator: " ")
            return PhoneStatus.Service(
                name: service.name, tone: service.tone.rawValue, state: service.stateText, detail: service.detailText,
                external: service.config.isExternal, canRestart: denial == nil && !service.config.isExternal,
                process: service.process.menuLabel, health: service.health?.detail, healthNote: service.healthNote,
                cause: service.cause, lastExit: loop?.0, failures: loop?.1, window: loop?.2, command: command)
        }

        let headline: String, tone: String
        switch snapshot.overall {
        case .healthy: (headline, tone) = ("All good", "good")
        case .attention: (headline, tone) = ("Needs attention", "warn")
        case .notRunning: (headline, tone) = ("Tender isn’t running", "off")
        }
        let broken = snapshot.services.filter(\.needsAttention)
        let summary: String
        if case .notRunning(let reason) = snapshot.overall {
            summary = reason
        } else if broken.isEmpty {
            summary = "\(snapshot.services.count) of \(snapshot.services.count) healthy."
        } else if broken.count == 1, let first = broken.first {
            summary = "\(first.name): \(first.detailText). Everything else is fine."
        } else {
            summary = "\(broken.map(\.name).joined(separator: ", ")) need attention."
        }

        let key = try? WebPush.vapidKey(at: paths.vapidKeyFile)
        return PhoneStatus(
            host: Host.current().localizedName ?? "This Mac",
            updated: snapshot.time,
            headline: headline, tone: tone, summary: summary,
            services: services,
            system: (snapshot.system?.rows ?? []).filter { $0.name != "readiness" }.map { PhoneStatus.Row(name: $0.name, value: $0.value, level: $0.level.rawValue) },
            readiness: Readiness.warnings(snapshot.readiness).map { PhoneStatus.Check(title: $0.title, detail: $0.detail, fix: $0.fix) },
            incidents: snapshot.incidents.map { PhoneStatus.Incident(title: $0.title, since: $0.openedAt) },
            alerts: snapshot.recentAlerts.prefix(10).map { PhoneStatus.Alert(time: $0.time, title: $0.title, body: $0.body, kind: $0.kind.rawValue) },
            viewer: PhoneStatus.Viewer(login: login, canRestart: denial == nil, reason: denial),
            push: PhoneStatus.Push(enabled: config?.alerts.phone ?? false, publicKey: key.map(WebPush.publicKeyBase64URL),
                                   subscriptions: PushSubscriptionStore(url: paths.pushSubscriptionsFile).all().count)
        )
    }

    private func logs(_ name: String, lines: Int) -> HTTPServer.Response {
        guard let service = config()?.services[name], !service.isExternal else { return .text("Not found", status: 404) }
        let count = min(max(lines, 1), 200)
        return .json(["lines": LogReader.tail(paths.stderrLog(for: name), lines: count)])
    }

    private func restart(_ name: String, request: HTTPServer.Request) -> HTTPServer.Response {
        guard request.headers["x-tender"] == "1" else { return forbidden("Missing X-Tender header.") }
        if let denial = restartPermission(request) { return forbidden(denial) }
        guard let service = config()?.services[name], !service.isExternal else { return .text("Not found", status: 404) }
        _ = service
        let label = LaunchAgentBuilder.label(for: name)
        do {
            if launchControl.isLoaded(label) {
                try launchControl.kickstart(label, kill: true)
            } else {
                try launchControl.bootstrap(plist: paths.plist(forLabel: label), label: label)
            }
        } catch {
            return .json(["ok": AnyEncodable(false), "message": AnyEncodable(String(describing: error))], status: 500)
        }
        AlertLog(url: paths.alertsFile).append(AlertMessage(time: Date(), kind: .info, title: "\(name) restarted from your phone",
                                                            body: "By \(viewer(request) ?? "you") over Tailscale.", service: name))
        return .json(["ok": AnyEncodable(true), "message": AnyEncodable("Restarting \(name).")])
    }

    private func subscribe(_ request: HTTPServer.Request) -> HTTPServer.Response {
        guard request.headers["x-tender"] == "1", isOwner(request) else { return forbidden("Only this Mac’s owner can turn on alerts.") }
        guard var subscription = try? JSONDecoder().decode(PushSubscription.self, from: request.body),
              subscription.endpoint.hasPrefix("https://") else { return .text("Bad subscription", status: 400) }
        subscription.login = viewer(request)
        subscription.addedAt = Date()
        do {
            try PushSubscriptionStore(url: paths.pushSubscriptionsFile).add(subscription)
        } catch {
            return .text("Couldn’t save", status: 500)
        }
        return .json(["ok": true])
    }

    private func unsubscribe(_ request: HTTPServer.Request) -> HTTPServer.Response {
        guard request.headers["x-tender"] == "1", isOwner(request) else { return forbidden("Only this Mac’s owner can change alerts.") }
        struct Body: Decodable { var endpoint: String }
        guard let body = try? JSONDecoder().decode(Body.self, from: request.body) else { return .text("Bad request", status: 400) }
        try? PushSubscriptionStore(url: paths.pushSubscriptionsFile).remove(endpoint: body.endpoint)
        return .json(["ok": true])
    }
}

/// Lets small JSON replies mix value types.
struct AnyEncodable: Encodable, ExpressibleByStringLiteral, ExpressibleByBooleanLiteral {
    private let encodeValue: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        encodeValue = { try value.encode(to: $0) }
    }

    init(stringLiteral value: String) { self.init(value) }
    init(booleanLiteral value: Bool) { self.init(value) }

    func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
}
