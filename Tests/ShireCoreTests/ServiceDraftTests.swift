import Foundation
import Testing
@testable import ShireCore

@Suite("Adding a service")
struct ServiceDraftTests {
    func draft() -> ServiceDraft {
        var draft = ServiceDraft()
        draft.name = "rivendell"
        draft.command = "pnpm"
        draft.arguments = #"preview --port 5300 --host "0.0.0.0""#
        draft.cwd = "~/Code/rivendell"
        draft.build = "pnpm build"
        draft.dependsOn = ["postgres"]
        draft.healthKind = .http
        draft.healthURL = "http://localhost:5300"
        return draft
    }

    @Test func splitsArgumentsLikeAShell() {
        #expect(draft().argumentList == ["preview", "--port", "5300", "--host", "0.0.0.0"])
        var draft = ServiceDraft()
        draft.arguments = #"-c "echo hi there"  x"#
        #expect(draft.argumentList == ["-c", "echo hi there", "x"])
    }

    @Test func producesYAMLThatParsesBackToTheSameService() throws {
        let yaml = "services:\n  postgres: { external: homebrew.mxcl.postgresql@16, health: { type: tcp, port: 5432 } }\n" + draft().yaml()
        let service = try #require(try ConfigLoader.parse(yaml).services["rivendell"])
        #expect(service.command == "pnpm")
        #expect(service.args == ["preview", "--port", "5300", "--host", "0.0.0.0"])
        #expect(service.cwd == "~/Code/rivendell")
        #expect(service.build == "pnpm build")
        #expect(service.dependsOn == ["postgres"])
        #expect(service.health?.url == "http://localhost:5300")
        #expect(service.restart == .always)
    }

    @Test func quotesOnlyWhatNeedsIt() {
        #expect(YAMLScalar.quote("pnpm") == "pnpm")
        #expect(YAMLScalar.quote("--port") == "\"--port\"")
        #expect(YAMLScalar.quote("5300") == "\"5300\"")
        #expect(YAMLScalar.quote("yes") == "\"yes\"")
        #expect(YAMLScalar.quote("http://x:1") == "\"http://x:1\"")
        #expect(YAMLScalar.quote(#"say "hi""#) == #""say \"hi\"""#)
        #expect(YAMLScalar.quote("/Applications/Red Book.app/Contents/MacOS/Red Book") == "/Applications/Red Book.app/Contents/MacOS/Red Book")
    }

    @Test func appendsWithoutTouchingTheRestOfTheFile() throws {
        let original = """
        # My Mac server
        serverMode: { keepAwake: true }

        services:
          # the database
          postgres:
            external: homebrew.mxcl.postgresql@16
            health: { type: tcp, port: 5432 }

          bagend-api:
            command: node   # the API

        alerts: { macos: true }
        """
        let updated = try #require(ConfigEditing.adding(draft().yaml(), to: original))
        #expect(updated.hasPrefix(original.components(separatedBy: "\n\nalerts:")[0]))
        #expect(updated.contains("    command: node   # the API\n\n  rivendell:\n    command: pnpm\n"))
        #expect(updated.hasSuffix("\nalerts: { macos: true }\n"))
        let config = try ConfigLoader.parse(updated)
        #expect(config.services.keys.sorted() == ["bagend-api", "postgres", "rivendell"])
        #expect(config.alerts.macos)
    }

    @Test func matchesTheFilesIndentation() throws {
        let original = "services:\n    web:\n        command: node\n"
        let updated = try #require(ConfigEditing.adding(draft().yaml(), to: original))
        #expect(updated.contains("\n    rivendell:\n        command: pnpm\n"))
        #expect(try ConfigLoader.parse(updated).services["rivendell"]?.command == "pnpm")
    }

    @Test func expandsAnEmptyServicesMapAndCreatesAMissingOne() throws {
        let empty = try #require(ConfigEditing.adding(draft().yaml(), to: "logs: { keep: 3 }\nservices: {}   # nothing yet\n"))
        #expect(empty.contains("services:   # nothing yet\n  rivendell:"))
        #expect(try ConfigLoader.parse(empty).services.count == 1)

        let missing = try #require(ConfigEditing.adding(draft().yaml(), to: "serverMode: { keepAwake: true }\n"))
        #expect(missing == "serverMode: { keepAwake: true }\n\nservices:\n" + draft().yaml())
        #expect(try ConfigLoader.parse(missing).services.count == 1)

        #expect(try ConfigLoader.parse(try #require(ConfigEditing.adding(draft().yaml(), to: ""))).services.count == 1)
        #expect(ConfigEditing.adding(draft().yaml(), to: "services: { web: { command: node } }\n") == nil) // inline: refuse
    }

    @Test func formIssues() {
        var draft = ServiceDraft()
        #expect(draft.formIssues(existing: []) == ["Give the service a name.", "Choose a command or an app."])
        draft.name = "Bag End"
        draft.command = "node"
        #expect(draft.formIssues(existing: []) == ["Names use lowercase letters, digits and dashes, like my-app."])
        draft.name = "bagend-api"
        #expect(draft.formIssues(existing: ["bagend-api"]) == ["There’s already a service called bagend-api."])
        draft.name = "new"
        draft.adoptRunning = true
        #expect(draft.formIssues(existing: []).last?.contains("needs a health check") == true)
        draft.healthKind = .tcp
        draft.healthPort = "99999"
        #expect(draft.formIssues(existing: []) == ["The health check needs a port between 1 and 65535."])
    }

    @Test func findsTheExecutableInsideAnApp() {
        #expect(ServiceDraft.executable(inApp: URL(fileURLWithPath: "/System/Applications/Calculator.app")) == "/System/Applications/Calculator.app/Contents/MacOS/Calculator")
    }
}
