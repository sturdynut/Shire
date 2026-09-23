import CryptoKit
import Foundation

/// A browser's push subscription, as `PushSubscription.toJSON()` gives it.
public struct PushSubscription: Codable, Equatable, Sendable {
    public struct Keys: Codable, Equatable, Sendable {
        public var p256dh: String
        public var auth: String
    }

    public var endpoint: String
    public var keys: Keys
    /// Who subscribed (their tailnet login) and when, for the Alerts screen.
    public var login: String?
    public var addedAt: Date?

    public init(endpoint: String, keys: Keys, login: String? = nil, addedAt: Date? = nil) {
        self.endpoint = endpoint
        self.keys = keys
        self.login = login
        self.addedAt = addedAt
    }
}

public enum WebPushError: Error, Equatable {
    case badKey
}

/// Web push without a third party in between: payloads are encrypted here (RFC 8291, aes128gcm) and signed with this
/// Mac's own VAPID key (RFC 8292), then handed to the browser's push service (Apple's, for an iPhone).
public enum WebPush {
    // MARK: VAPID

    /// The Mac's VAPID key, created once and kept in the state folder.
    public static func vapidKey(at url: URL) throws -> P256.Signing.PrivateKey {
        if let data = try? Data(contentsOf: url), let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = P256.Signing.PrivateKey()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try key.rawRepresentation.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return key
    }

    /// The `applicationServerKey` a page passes to `pushManager.subscribe`.
    public static func publicKeyBase64URL(_ key: P256.Signing.PrivateKey) -> String {
        base64URL(key.publicKey.x963Representation)
    }

    /// `Authorization: vapid t=<jwt>, k=<public key>` for a push endpoint.
    public static func authorization(endpoint: URL, key: P256.Signing.PrivateKey, subject: String, now: Date = Date()) throws -> String {
        guard let scheme = endpoint.scheme, let host = endpoint.host else { throw WebPushError.badKey }
        let audience = "\(scheme)://\(host)"
        let header = base64URL(Data(#"{"typ":"JWT","alg":"ES256"}"#.utf8))
        let expiry = Int(now.timeIntervalSince1970) + 12 * 3600
        let claims = base64URL(Data(#"{"aud":"\#(audience)","exp":\#(expiry),"sub":"\#(subject)"}"#.utf8))
        let signingInput = "\(header).\(claims)"
        let signature = try key.signature(for: Data(signingInput.utf8))
        return "vapid t=\(signingInput).\(base64URL(signature.rawRepresentation)), k=\(publicKeyBase64URL(key))"
    }

    // MARK: Encryption (RFC 8291)

    /// Encrypts `payload` for one subscription. `salt` and `serverKey` are parameters only so tests can be exact.
    public static func encrypt(_ payload: Data, for subscription: PushSubscription,
                               salt: Data = randomBytes(16), serverKey: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey()) throws -> Data {
        guard let uaPublicData = fromBase64URL(subscription.keys.p256dh), let authSecret = fromBase64URL(subscription.keys.auth),
              let uaPublic = try? P256.KeyAgreement.PublicKey(x963Representation: uaPublicData) else { throw WebPushError.badKey }
        let asPublicData = serverKey.publicKey.x963Representation
        let shared = try serverKey.sharedSecretFromKeyAgreement(with: uaPublic)
        let sharedData = shared.withUnsafeBytes { Data($0) }

        // IKM = HKDF(auth_secret, ecdh_secret, "WebPush: info" || 0x00 || ua_public || as_public, 32)
        var keyInfo = Data("WebPush: info".utf8)
        keyInfo.append(0)
        keyInfo.append(uaPublicData)
        keyInfo.append(asPublicData)
        let ikm = hkdf(salt: authSecret, ikm: sharedData, info: keyInfo, length: 32)

        let cek = hkdf(salt: salt, ikm: ikm, info: Data("Content-Encoding: aes128gcm".utf8) + Data([0]), length: 16)
        let nonce = hkdf(salt: salt, ikm: ikm, info: Data("Content-Encoding: nonce".utf8) + Data([0]), length: 12)

        var plaintext = payload
        plaintext.append(0x02) // last (and only) record, no padding
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: cek), nonce: AES.GCM.Nonce(data: nonce))

        var body = salt
        body.append(contentsOf: withUnsafeBytes(of: UInt32(4096).bigEndian) { Array($0) }) // record size
        body.append(UInt8(asPublicData.count))
        body.append(asPublicData)
        body.append(sealed.ciphertext)
        body.append(sealed.tag)
        return body
    }

    static func hkdf(salt: Data, ikm: Data, info: Data, length: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: length)
        return key.withUnsafeBytes { Data($0) }
    }

    public static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    // MARK: Base64URL

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func fromBase64URL(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}

/// Phones subscribed to alerts, kept in the state folder.
public struct PushSubscriptionStore: Sendable {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    public func all() -> [PushSubscription] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONCoding.decoder.decode([PushSubscription].self, from: data)) ?? []
    }

    public func add(_ subscription: PushSubscription) throws {
        var list = all().filter { $0.endpoint != subscription.endpoint }
        list.append(subscription)
        try save(list)
    }

    public func remove(endpoint: String) throws {
        try save(all().filter { $0.endpoint != endpoint })
    }

    private func save(_ list: [PushSubscription]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(list).write(to: url, options: .atomic)
    }
}

/// Sends alerts to every subscribed phone. Subscriptions the push service says are gone (404/410) are dropped.
public struct WebPushSender: Sendable {
    public var paths: TenderPaths
    public var subject: String

    public init(paths: TenderPaths, subject: String = "mailto:tender@example.com") {
        self.paths = paths
        self.subject = subject
    }

    public func send(_ alert: AlertMessage) async {
        let store = PushSubscriptionStore(url: paths.pushSubscriptionsFile)
        let subscriptions = store.all()
        guard !subscriptions.isEmpty, let key = try? WebPush.vapidKey(at: paths.vapidKeyFile) else { return }
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "title": alert.title, "body": alert.body, "service": alert.service ?? "", "kind": alert.kind.rawValue,
        ])) ?? Data()

        for subscription in subscriptions {
            guard let endpoint = URL(string: subscription.endpoint),
                  let body = try? WebPush.encrypt(payload, for: subscription),
                  let authorization = try? WebPush.authorization(endpoint: endpoint, key: key, subject: subject) else { continue }
            var request = URLRequest(url: endpoint, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue("86400", forHTTPHeaderField: "TTL")
            request.setValue(alert.kind == .problem ? "high" : "normal", forHTTPHeaderField: "Urgency")
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            let status = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode
            if status == 404 || status == 410 {
                try? store.remove(endpoint: subscription.endpoint)
            }
        }
    }
}
