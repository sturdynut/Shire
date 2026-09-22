import Foundation
import Testing
@testable import UpliftCore

@Suite("Reconciler")
struct ReconcilerTests {
    func setUp(_ yaml: String = planConfigYAML) throws -> (TempHome, UpliftConfig, FakeLaunchControl) {
        (try TempHome(), try ConfigLoader.parse(yaml), FakeLaunchControl())
    }

    func actions(_ plan: ApplyPlan) -> [String: PlannedChange.Action] {
        Dictionary(uniqueKeysWithValues: plan.changes.map { ($0.name, $0.action) })
    }

    @Test func firstApplyInstallsEverythingInDependencyOrder() throws {
        let (home, config, control) = try setUp()
        let builder = FakeBuilder(succeeds: true)
        let reconciler = Reconciler(paths: home.paths, launchControl: control, builder: builder)
        let desired = reconciler.desiredPlists(config: config, resolved: planResolution(), upliftExecutable: "/u")
        let plan = reconciler.plan(config: config, desired: desired)

        #expect(actions(plan)["postgres"] == .watch(label: "homebrew.mxcl.postgresql@16"))
        #expect(actions(plan)["doulasimply-api"] == .install)
        #expect(actions(plan)["doulasimply-web"] == .install)
        #expect(actions(plan)["tradingview"] == .install)

        let outcomes = reconciler.apply(plan, config: config, resolved: planResolution(), build: true)
        #expect(outcomes.allSatisfy { if case .done = $0.result { return true } else { return false } })
        // Services with no dependencies go first; the API waits on postgres, the web app on the API.
        #expect(control.calls == ["bootstrap com.uplift.tradingview", "bootstrap com.uplift.doulasimply-api", "bootstrap com.uplift.doulasimply-web"])
        #expect(builder.log.all == ["doulasimply-api: pnpm build", "doulasimply-web: pnpm build"])
        #expect(FileManager.default.fileExists(atPath: home.paths.plist(forLabel: "com.uplift.tradingview").path))
    }

    @Test func secondApplyChangesNothing() throws {
        let (home, config, control) = try setUp()
        let reconciler = Reconciler(paths: home.paths, launchControl: control, builder: FakeBuilder(succeeds: true))
        let desired = reconciler.desiredPlists(config: config, resolved: planResolution(), upliftExecutable: "/u")
        _ = reconciler.apply(reconciler.plan(config: config, desired: desired), config: config, resolved: planResolution(), build: true)

        let again = reconciler.plan(config: config, desired: desired)
        #expect(!again.hasChanges)
    }

    @Test func nvmSwitchRestartsOnlyTheServicesThatUseIt() throws {
        let (home, config, control) = try setUp()
        let reconciler = Reconciler(paths: home.paths, launchControl: control, builder: FakeBuilder(succeeds: true))
        let first = reconciler.desiredPlists(config: config, resolved: planResolution(), upliftExecutable: "/u")
        _ = reconciler.apply(reconciler.plan(config: config, desired: first), config: config, resolved: planResolution(), build: true)

        var moved = planResolution()
        let nvm22_20 = "/Users/me/.nvm/versions/node/v22.20.0/bin"
        moved.commands["node"] = CommandResolution(command: "node", path: "\(nvm22_20)/node")
        moved.commands["pnpm"] = CommandResolution(command: "pnpm", path: "\(nvm22_20)/pnpm")
        moved.loginPath = "\(nvm22_20):/opt/homebrew/bin:/usr/bin:/bin"
        let second = reconciler.desiredPlists(config: config, resolved: moved, upliftExecutable: "/u")
        let plan = reconciler.plan(config: config, desired: second)

        guard case .update(let reasons) = actions(plan)["doulasimply-web"] else {
            Issue.record("web should restart")
            return
        }
        #expect(reasons.contains("command now \(nvm22_20)/pnpm"))
        if case .update = actions(plan)["doulasimply-api"] {} else { Issue.record("api should restart") }
        // TradingView doesn't use Node, so switching Node versions must not restart it.
        #expect(actions(plan)["tradingview"] == .unchanged)
    }

    @Test func failedBuildLeavesTheRunningVersionAlone() throws {
        let (home, config, control) = try setUp()
        let reconciler = Reconciler(paths: home.paths, launchControl: control, builder: FakeBuilder(succeeds: false))
        let desired = reconciler.desiredPlists(config: config, resolved: planResolution(), upliftExecutable: "/u")
        let outcomes = reconciler.apply(reconciler.plan(config: config, desired: desired), config: config, resolved: planResolution(), build: true)

        let api = try #require(outcomes.first { $0.name == "doulasimply-api" })
        #expect(api.result == .failed("build failed (pnpm build); left the running version alone"))
        #expect(!control.calls.contains("bootstrap com.uplift.doulasimply-api"))
        #expect(control.calls.contains("bootstrap com.uplift.tradingview"))
    }

    @Test func noBuildSkipsBuilds() throws {
        let (home, config, control) = try setUp()
        let builder = FakeBuilder(succeeds: false)
        let reconciler = Reconciler(paths: home.paths, launchControl: control, builder: builder)
        let desired = reconciler.desiredPlists(config: config, resolved: planResolution(), upliftExecutable: "/u")
        _ = reconciler.apply(reconciler.plan(config: config, desired: desired), config: config, resolved: planResolution(), build: false)
        #expect(builder.log.all.isEmpty)
        #expect(control.calls.count == 3)
    }

    @Test func servicesRemovedFromConfigAreStoppedAndRemoved() throws {
        let (home, config, control) = try setUp()
        let reconciler = Reconciler(paths: home.paths, launchControl: control, builder: FakeBuilder(succeeds: true))
        let desired = reconciler.desiredPlists(config: config, resolved: planResolution(), upliftExecutable: "/u")
        _ = reconciler.apply(reconciler.plan(config: config, desired: desired), config: config, resolved: planResolution(), build: true)

        var smaller = config
        smaller.services["tradingview"] = nil
        let plan = reconciler.plan(config: smaller, desired: reconciler.desiredPlists(config: smaller, resolved: planResolution(), upliftExecutable: "/u"))
        #expect(actions(plan)["tradingview"] == .remove)
        #expect(plan.changes.first?.name == "tradingview")

        _ = reconciler.apply(plan, config: smaller, resolved: planResolution(), build: true)
        #expect(control.calls.last == "bootout com.uplift.tradingview")
        #expect(!FileManager.default.fileExists(atPath: home.paths.plist(forLabel: "com.uplift.tradingview").path))
    }

    @Test func unrelatedLaunchAgentsAreIgnored() throws {
        let (home, config, control) = try setUp()
        try home.write("Library/LaunchAgents/homebrew.mxcl.postgresql@16.plist", "<plist/>")
        try home.write("Library/LaunchAgents/com.example.other.plist", "<plist/>")
        let reconciler = Reconciler(paths: home.paths, launchControl: control)
        #expect(reconciler.installedServices().isEmpty)
        let plan = reconciler.plan(config: config, desired: [:])
        #expect(!plan.changes.contains { $0.action == .remove })
    }

    @Test func stoppedServiceIsStartedAgainWithoutRebuilding() throws {
        let (home, config, control) = try setUp()
        let builder = FakeBuilder(succeeds: true)
        let reconciler = Reconciler(paths: home.paths, launchControl: control, builder: builder)
        let desired = reconciler.desiredPlists(config: config, resolved: planResolution(), upliftExecutable: "/u")
        _ = reconciler.apply(reconciler.plan(config: config, desired: desired), config: config, resolved: planResolution(), build: true)
        try control.bootout("com.uplift.doulasimply-web")

        let plan = reconciler.plan(config: config, desired: desired)
        #expect(actions(plan)["doulasimply-web"] == .start)
        let before = builder.log.all.count
        _ = reconciler.apply(plan, config: config, resolved: planResolution(), build: true)
        #expect(builder.log.all.count == before)
        #expect(control.isLoaded("com.uplift.doulasimply-web"))
    }
}
