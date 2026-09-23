import Foundation
import Testing
@testable import ShireCore

@Suite("Units")
struct UnitsTests {
    @Test(arguments: [("500ms", 0.5), ("30s", 30), ("2m", 120), ("1h", 3600), ("45", 45), (" 3s ", 3)])
    func durations(text: String, seconds: Double) {
        #expect(DurationValue(parsing: text)?.seconds == seconds)
    }

    @Test(arguments: ["", "fast", "-3s", "2x"])
    func badDurations(text: String) {
        #expect(DurationValue(parsing: text) == nil)
    }

    @Test func durationDescriptionRoundTrips() {
        #expect(DurationValue(seconds: 300).description == "5m")
        #expect(DurationValue(seconds: 30).description == "30s")
        #expect(DurationValue(seconds: 0.25).description == "250ms")
    }

    @Test func sizes() {
        #expect(ByteSize(parsing: "10MB")?.bytes == 10 << 20)
        #expect(ByteSize(parsing: "512kb")?.bytes == 512 << 10)
        #expect(ByteSize(parsing: "1GB")?.bytes == 1 << 30)
        #expect(ByteSize(parsing: "2048")?.bytes == 2048)
        #expect(ByteSize(parsing: "lots") == nil)
        #expect(ByteSize(bytes: 10 << 20).description == "10MB")
    }

    @Test func crashLoopRule() {
        let rule = CrashLoopRule(parsing: "3 in 5m")
        #expect(rule?.count == 3)
        #expect(rule?.window.seconds == 300)
        #expect(CrashLoopRule(parsing: "3 per 5m") == nil)
        #expect(CrashLoopRule(parsing: "0 in 5m") == nil)
    }
}

@Suite("Config loading")
struct ConfigLoaderTests {
    @Test func parsesThePlanConfig() throws {
        let config = try ConfigLoader.parse(planConfigYAML)
        #expect(config.serverMode.keepAwake)
        #expect(config.presets.tailscale.enabled)
        #expect(config.remote.statusPage == .tailnet)
        #expect(config.remote.actions == .restart)
        #expect(config.alerts.crashLoop == CrashLoopRule(count: 3, window: DurationValue(seconds: 300)))
        #expect(config.logs.maxSize.bytes == 10 << 20)
        #expect(config.services.count == 4)

        let web = try #require(config.services["bagend-web"])
        #expect(web.command == "pnpm")
        #expect(web.args == ["preview", "--port", "5174"])
        #expect(web.serve == 443)
        #expect(web.dependsOn == ["bagend-api"])
        #expect(web.restart == .always)
        #expect(web.health?.endpoint == HostPort(host: "localhost", port: 5174))

        let postgres = try #require(config.services["postgres"])
        #expect(postgres.isExternal)
        #expect(postgres.health?.endpoint == HostPort(host: "127.0.0.1", port: 5432))

        #expect(config.managedServiceNames == ["bagend-api", "bagend-web", "redbook"])
    }

    @Test func defaultsWhenSectionsAreMissing() throws {
        let config = try ConfigLoader.parse("services:\n  a:\n    command: /bin/echo\n")
        #expect(config.alerts.macos)
        #expect(!config.alerts.phone)
        #expect(config.remote.actions == .restart)
        #expect(config.logs.keep == 3)
        #expect(config.services["a"]?.args == [])
    }

    @Test func emptyFileIsAnEmptyConfig() throws {
        #expect(try ConfigLoader.parse("").services.isEmpty)
    }

    @Test func unknownServiceKeySuggestsTheRightOne() {
        let yaml = "services:\n  api:\n    command: node\n    dependOn: [db]\n"
        #expect(throws: ConfigError.unknownKey(path: "services.api", key: "dependOn", suggestion: "dependsOn")) {
            try ConfigLoader.parse(yaml)
        }
    }

    @Test func unknownTopLevelKey() {
        #expect(throws: ConfigError.unknownKey(path: "", key: "servics", suggestion: "services")) {
            try ConfigLoader.parse("servics:\n  a:\n    command: x\n")
        }
    }

    @Test func unknownHealthKey() {
        let yaml = "services:\n  a:\n    command: x\n    health: { type: tcp, prot: 80 }\n"
        #expect(throws: ConfigError.unknownKey(path: "services.a.health", key: "prot", suggestion: "port")) {
            try ConfigLoader.parse(yaml)
        }
    }

    @Test func badDurationExplainsItself() throws {
        let yaml = "services:\n  a:\n    command: x\n    health: { type: tcp, port: 1, interval: soon }\n"
        let error = try #require(throws: ConfigError.self) { try ConfigLoader.parse(yaml) }
        #expect(error.description.contains("services.a.health.interval"))
        #expect(error.description.contains("isn’t a duration"))
    }

    @Test func badRestartPolicy() throws {
        let yaml = "services:\n  a:\n    command: x\n    restart: sometimes\n"
        let error = try #require(throws: ConfigError.self) { try ConfigLoader.parse(yaml) }
        #expect(error.description.contains("services.a.restart"))
    }

    @Test func invalidYAML() {
        #expect(throws: ConfigError.self) { try ConfigLoader.parse("services: [unclosed") }
    }
}

@Suite("Validation")
struct ValidatorTests {
    let validator = Validator(home: "/Users/me", directoryExists: { _ in true }, fileExists: { _ in true })

    func issues(_ yaml: String, resolved: ResolvedEnvironment? = nil, validator: Validator? = nil) throws -> [ValidationIssue] {
        (validator ?? self.validator).validate(try ConfigLoader.parse(yaml), resolved: resolved)
    }

    @Test func planConfigHasOnlyVersionManagerWarnings() throws {
        let found = try issues(planConfigYAML, resolved: planResolution())
        #expect(found.allSatisfy { $0.severity == .warning })
        #expect(Set(found.compactMap(\.service)) == ["bagend-api", "bagend-web"])
        #expect(found.allSatisfy { $0.message.contains("nvm") })
    }

    @Test func managedServiceNeedsACommand() throws {
        let found = try issues("services:\n  a:\n    args: [x]\n")
        #expect(found == [ValidationIssue(.error, "a", "needs a “command” (or “external:” to watch a launchd job Shire doesn’t own).")])
    }

    @Test func externalServiceCantHaveACommand() throws {
        let found = try issues("services:\n  db:\n    external: homebrew.mxcl.postgresql@16\n    command: postgres\n")
        #expect(found.contains { $0.severity == .error && $0.message.contains("“command” doesn’t apply") })
    }

    @Test func unknownDependency() throws {
        let found = try issues("services:\n  a:\n    command: x\n    dependsOn: [ghost]\n")
        #expect(found.contains { $0.message.contains("“ghost”, which isn’t a service") })
    }

    @Test func dependencyLoop() throws {
        let yaml = """
        services:
          a: { command: x, dependsOn: [b], health: { type: tcp, port: 1 } }
          b: { command: x, dependsOn: [a], health: { type: tcp, port: 2 } }
        """
        let found = try issues(yaml)
        #expect(found.contains { $0.message == "dependencies form a loop: a → b → a." })
    }

    @Test func dependencyWithoutHealthCheckWarns() throws {
        let found = try issues("services:\n  a: { command: x }\n  b: { command: x, dependsOn: [a] }\n")
        #expect(found.contains { $0.severity == .warning && $0.message.contains("no health check") })
    }

    @Test func missingWorkingFolderAndEnvFile() throws {
        let strict = Validator(home: "/Users/me", directoryExists: { _ in false }, fileExists: { _ in false })
        let found = try issues("services:\n  a: { command: x, cwd: ~/gone, envFile: .env }\n", validator: strict)
        #expect(found.contains { $0.message == "working folder /Users/me/gone doesn’t exist." })
        #expect(found.contains { $0.message == "env file /Users/me/gone/.env doesn’t exist." })
    }

    @Test func commandNotFound() throws {
        let resolved = ResolvedEnvironment(commands: ["pnpm": CommandResolution(command: "pnpm", path: nil)], loginPath: "")
        let found = try issues("services:\n  a: { command: pnpm }\n", resolved: resolved)
        #expect(found.contains { $0.severity == .error && $0.message.contains("login shell can’t find “pnpm”") })
    }

    @Test func servePortClash() throws {
        let found = try issues("services:\n  a: { command: x, serve: 443 }\n  b: { command: x, serve: 443 }\n")
        #expect(found.contains { $0.severity == .error && $0.message.contains("tailnet port 443") })
    }

    @Test func healthPortClashWarns() throws {
        let yaml = "services:\n  a: { command: x, health: { type: tcp, port: 80 } }\n  b: { command: x, health: { type: http, url: http://localhost:80 } }\n"
        let found = try issues(yaml)
        #expect(found.contains { $0.severity == .warning && $0.message.contains("port 80") })
    }

    @Test func httpCheckNeedsAURL() throws {
        let found = try issues("services:\n  a: { command: x, health: { type: http } }\n")
        #expect(found.contains { $0.message == "an http health check needs a “url”." })
    }

    @Test(arguments: [("api", true), ("bagend-web", true), ("2fa", true), ("Api", false), ("-x", false), ("a_b", false), ("", false)])
    func serviceNames(name: String, valid: Bool) {
        #expect(Validator.isValidName(name) == valid)
    }
}

@Suite("Dependency order")
struct DependencyOrderTests {
    @Test func dependenciesComeFirst() throws {
        let config = try ConfigLoader.parse(planConfigYAML)
        let order = DependencyOrder.sorted(config)
        #expect(order.firstIndex(of: "postgres")! < order.firstIndex(of: "bagend-api")!)
        #expect(order.firstIndex(of: "bagend-api")! < order.firstIndex(of: "bagend-web")!)
        #expect(order.count == 4)
    }

    @Test func noCycleInPlanConfig() throws {
        #expect(DependencyOrder.cycle(in: try ConfigLoader.parse(planConfigYAML)) == nil)
    }
}
