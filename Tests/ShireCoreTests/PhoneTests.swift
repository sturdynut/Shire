import CryptoKit
import Foundation
import Testing
@testable import ShireCore

@Suite("Web push")
struct WebPushTests {
    /// Decrypts an aes128gcm body the way a browser does (RFC 8291), to check `encrypt` end to end.
    func decrypt(_ body: Data, uaKey: P256.KeyAgreement.PrivateKey, auth: Data) throws -> Data {
        let salt = body.prefix(16)
        let idLength = Int(body[body.startIndex + 20])
        let asPublicData = body.subdata(in: (body.startIndex + 21)..<(body.startIndex + 21 + idLength))
        let ciphertext = body.suffix(from: body.startIndex + 21 + idLength)
        let asPublic = try P256.KeyAgreement.PublicKey(x963Representation: asPublicData)
        let shared = try uaKey.sharedSecretFromKeyAgreement(with: asPublic).withUnsafeBytes { Data($0) }
        var info = Data("WebPush: info".utf8); info.append(0)
        info.append(uaKey.publicKey.x963Representation); info.append(asPublicData)
        let ikm = WebPush.hkdf(salt: auth, ikm: shared, info: info, length: 32)
        let cek = WebPush.hkdf(salt: Data(salt), ikm: ikm, info: Data("Content-Encoding: aes128gcm".utf8) + Data([0]), length: 16)
        let nonce = WebPush.hkdf(salt: Data(salt), ikm: ikm, info: Data("Content-Encoding: nonce".utf8) + Data([0]), length: 12)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
        var plain = try AES.GCM.open(box, using: SymmetricKey(data: cek))
        #expect(plain.last == 0x02)
        plain.removeLast()
        return plain
    }

    @Test func encryptsSoTheBrowserCanDecrypt() throws {
        let ua = P256.KeyAgreement.PrivateKey()
        let auth = WebPush.randomBytes(16)
        let subscription = PushSubscription(endpoint: "https://web.push.apple.com/abc",
                                            keys: .init(p256dh: WebPush.base64URL(ua.publicKey.x963Representation), auth: WebPush.base64URL(auth)))
        let payload = Data(#"{"title":"bagend-web is crash-looping"}"#.utf8)
        let body = try WebPush.encrypt(payload, for: subscription)
        #expect(try decrypt(body, uaKey: ua, auth: auth) == payload)
        #expect(body.count == 16 + 4 + 1 + 65 + payload.count + 1 + 16)

        // Optionally hand the same message to an independent implementation (see README: web push check).
        if let out = ProcessInfo.processInfo.environment["SHIRE_WEBPUSH_VECTOR"] {
            let vector: [String: String] = [
                "uaPrivate": WebPush.base64URL(ua.rawRepresentation), "auth": WebPush.base64URL(auth),
                "body": WebPush.base64URL(body), "payload": String(decoding: payload, as: UTF8.self),
            ]
            try JSONSerialization.data(withJSONObject: vector).write(to: URL(fileURLWithPath: out))
        }
    }

    @Test func vapidAuthorizationIsASignedJWT() throws {
        let key = P256.Signing.PrivateKey()
        let header = try WebPush.authorization(endpoint: URL(string: "https://web.push.apple.com/QK4-abc")!, key: key,
                                               subject: "mailto:shire@example.com", now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(header.hasPrefix("vapid t="))
        let parts = header.dropFirst("vapid t=".count).split(separator: ",")[0].split(separator: ".")
        #expect(parts.count == 3)
        let claims = try JSONSerialization.jsonObject(with: WebPush.fromBase64URL(String(parts[1]))!) as! [String: Any]
        #expect(claims["aud"] as? String == "https://web.push.apple.com")
        #expect(claims["exp"] as? Int == 1_800_000_000 + 12 * 3600)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: WebPush.fromBase64URL(String(parts[2]))!)
        #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
        #expect(header.hasSuffix("k=\(WebPush.publicKeyBase64URL(key))"))
    }

    @Test func vapidKeyIsCreatedOnceAndPrivate() throws {
        let home = try TempHome()
        let first = try WebPush.vapidKey(at: home.paths.vapidKeyFile)
        let second = try WebPush.vapidKey(at: home.paths.vapidKeyFile)
        #expect(first.rawRepresentation == second.rawRepresentation)
        let permissions = try FileManager.default.attributesOfItem(atPath: home.paths.vapidKeyFile.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func base64URLRoundTrips() {
        let data = Data([0xfb, 0xff, 0x00, 0x10, 0x3e])
        #expect(WebPush.base64URL(data) == "-_8AED4")
        #expect(WebPush.fromBase64URL("-_8AED4") == data)
    }
}

@Suite("tailscale serve")
struct TailscaleServeTests {
    let json = """
    {"TCP":{"443":{"HTTPS":true},"7777":{"HTTPS":true}},
     "Web":{"mbp.tail.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:7878"}}},
            "mbp.tail.ts.net:7777":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:7780"}}}}}
    """

    @Test func readsWhatEachPortServes() {
        #expect(TailscaleServe.currentProxy(json: json, port: 443) == "http://127.0.0.1:7878")
        #expect(TailscaleServe.currentProxy(json: json, port: 7777) == "http://127.0.0.1:7780")
        #expect(TailscaleServe.currentProxy(json: json, port: 8443) == nil)
    }

    @Test func neverTakesAPortServingSomethingElse() {
        let serve = TailscaleServe(runner: FakeRunner(stdout: json), cli: "/opt/homebrew/bin/tailscale")
        #expect(serve.ensure(port: 443, localPort: 7780, dnsName: "mbp.tail.ts.net") == .portTaken(by: "http://127.0.0.1:7878"))
        #expect(serve.ensure(port: 7777, localPort: 7780, dnsName: "mbp.tail.ts.net") == .alreadyServing(url: "https://mbp.tail.ts.net:7777"))
        #expect(serve.remove(port: 443, localPort: 7780) == .notNeeded)
    }
}

@Suite("Phone page", .serialized)
struct PhoneServerTests {
    let owner = "matti.salokangas@gmail.com"

    func setUp(actions: String = "restart") throws -> (TempHome, PhoneServer, FakeLaunchControl) {
        let home = try TempHome()
        let yaml = """
        remote: { statusPage: tailnet, actions: \(actions) }
        alerts: { phone: true }
        services:
          web: { command: /bin/sleep, args: ["60"] }
          db: { external: homebrew.mxcl.postgresql@16 }
        """
        try home.write(".config/shire/config.yaml", yaml)
        let config = try ConfigLoader.parse(yaml)
        try home.write("Library/LaunchAgents/com.shire.web.plist", "<plist/>")
        try home.write("Library/Logs/shire/web.stderr.log", "one\ntwo\nthree\n")
        let control = FakeLaunchControl(loaded: ["com.shire.web": LaunchJobInfo(state: "running", pid: 9)])
        let server = PhoneServer(paths: home.paths, owner: owner, launchControl: control, config: { config }, facts: { nil })
        return (home, server, control)
    }

    func request(_ method: String, _ path: String, login: String? = nil, shireHeader: Bool = false, body: Data = Data()) -> HTTPServer.Request {
        var headers: [String: String] = [:]
        if let login { headers["tailscale-user-login"] = login }
        if shireHeader { headers["x-shire"] = "1" }
        let parts = path.split(separator: "?", maxSplits: 1)
        var query: [String: String] = [:]
        if parts.count == 2, let pair = parts[1].split(separator: "=").map(String.init) as [String]?, pair.count == 2 { query[pair[0]] = pair[1] }
        return HTTPServer.Request(method: method, path: String(parts[0]), query: query, headers: headers, body: body)
    }

    func json(_ response: HTTPServer.Response) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
    }

    @Test func servesThePageAndHomeScreenFiles() async throws {
        let (home, server, _) = try setUp()
        defer { withExtendedLifetime(home) {} }
        let page = await server.handle(request("GET", "/"))
        #expect(page.status == 200)
        #expect(page.headers["Content-Type"] == "text/html; charset=utf-8")
        #expect(String(decoding: page.body, as: UTF8.self).contains("apple-mobile-web-app-capable"))
        #expect(await server.handle(request("GET", "/manifest.webmanifest")).status == 200)
        #expect(await server.handle(request("GET", "/sw.js")).headers["Service-Worker-Allowed"] == "/")
        let icon = await server.handle(request("GET", "/apple-touch-icon.png"))
        #expect(icon.body.starts(with: [0x89, 0x50, 0x4E, 0x47])) // PNG signature
        #expect(await server.handle(request("GET", "/icon-512.png")).body.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(await server.handle(request("GET", "/nope")).status == 404)
    }

    @Test func statusKnowsWhoIsLooking() async throws {
        let (home, server, _) = try setUp()
        defer { withExtendedLifetime(home) {} }
        let asOwner = try json(await server.handle(request("GET", "/api/status", login: owner)))
        #expect((asOwner["viewer"] as? [String: Any])?["canRestart"] as? Bool == true)
        let services = try #require(asOwner["services"] as? [[String: Any]])
        #expect(services.map { $0["name"] as? String } == ["db", "web"])
        #expect(services.first { $0["name"] as? String == "db" }?["canRestart"] as? Bool == false)
        #expect((asOwner["push"] as? [String: Any])?["publicKey"] as? String != nil)

        let stranger = try json(await server.handle(request("GET", "/api/status", login: "someone@else.com")))
        #expect((stranger["viewer"] as? [String: Any])?["canRestart"] as? Bool == false)
        #expect((stranger["viewer"] as? [String: Any])?["reason"] as? String == "Only \(owner) can restart services.")
        let local = try json(await server.handle(request("GET", "/api/status")))
        #expect((local["viewer"] as? [String: Any])?["canRestart"] as? Bool == false)
    }

    @Test func restartOnlyForTheOwnerWithTheHeader() async throws {
        let (home, server, control) = try setUp()
        #expect(await server.handle(request("POST", "/api/services/web/restart", login: owner)).status == 403) // no X-Shire
        #expect(await server.handle(request("POST", "/api/services/web/restart", shireHeader: true)).status == 403) // not via Tailscale
        #expect(await server.handle(request("POST", "/api/services/web/restart", login: "eve@x.com", shireHeader: true)).status == 403)
        #expect(await server.handle(request("POST", "/api/services/db/restart", login: owner, shireHeader: true)).status == 404) // external
        #expect(control.calls.isEmpty)

        let ok = await server.handle(request("POST", "/api/services/web/restart", login: owner, shireHeader: true))
        #expect(ok.status == 200)
        #expect(control.calls == ["kickstart -k com.shire.web"])
        #expect(AlertLog(url: home.paths.alertsFile).recent(5).first?.title == "web restarted from your phone")
    }

    @Test func readOnlyModeRefusesRestart() async throws {
        let (home, server, control) = try setUp(actions: "read-only")
        defer { withExtendedLifetime(home) {} }
        let response = await server.handle(request("POST", "/api/services/web/restart", login: owner, shireHeader: true))
        #expect(response.status == 403)
        #expect(control.calls.isEmpty)
    }

    @Test func logsAndSubscriptions() async throws {
        let (home, server, _) = try setUp()
        let logs = try json(await server.handle(request("GET", "/api/services/web/logs?lines=2")))
        #expect(logs["lines"] as? [String] == ["two", "three"])
        #expect(await server.handle(request("GET", "/api/services/db/logs")).status == 404)

        let subscription = Data(#"{"endpoint":"https://web.push.apple.com/xyz","keys":{"p256dh":"BAAA","auth":"AAAA"}}"#.utf8)
        #expect(await server.handle(request("POST", "/api/push/subscribe", login: "eve@x.com", shireHeader: true, body: subscription)).status == 403)
        #expect(await server.handle(request("POST", "/api/push/subscribe", login: owner, shireHeader: true, body: subscription)).status == 200)
        let stored = PushSubscriptionStore(url: home.paths.pushSubscriptionsFile).all()
        #expect(stored.map(\.endpoint) == ["https://web.push.apple.com/xyz"])
        #expect(stored.first?.login == owner)
        let unsubscribe = Data(#"{"endpoint":"https://web.push.apple.com/xyz"}"#.utf8)
        #expect(await server.handle(request("POST", "/api/push/unsubscribe", login: owner, shireHeader: true, body: unsubscribe)).status == 200)
        #expect(PushSubscriptionStore(url: home.paths.pushSubscriptionsFile).all().isEmpty)
    }

    @Test func realSocketEndToEnd() async throws {
        let (home, server, _) = try setUp()
        defer { withExtendedLifetime(home) {} }
        try server.start(port: 0)
        defer { server.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/api/status")!)
        request.setValue(owner, forHTTPHeaderField: "Tailscale-User-Login")
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect((body["services"] as? [Any])?.count == 2)
    }

    @Test func httpParsing() {
        let raw = Data("POST /api/x?lines=3 HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\nX-Shire: 1\r\n\r\nhello".utf8)
        guard case .complete(let request) = HTTPServer.parse(raw) else { Issue.record("should parse"); return }
        #expect(request.method == "POST")
        #expect(request.path == "/api/x")
        #expect(request.query["lines"] == "3")
        #expect(request.headers["x-shire"] == "1")
        #expect(String(decoding: request.body, as: UTF8.self) == "hello")
        if case .incomplete = HTTPServer.parse(Data("GET / HTTP/1.1\r\nContent-Length: 9\r\n\r\nabc".utf8)) {} else { Issue.record("should wait for body") }
    }
}
