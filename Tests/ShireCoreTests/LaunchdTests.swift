import Foundation
import Testing
@testable import ShireCore

@Suite("Command resolution")
struct CommandResolverTests {
    @Test func ignoresNoiseFromRcFiles() {
        let output = """
        Welcome back!
        nvm: using v22.14.0
        __SHIRE__pnpm=\(nvm22_14)/pnpm
        __SHIRE__ghost=
        __SHIRE_PATH__=\(nvm22_14):/opt/homebrew/bin:/usr/bin
        """
        let answer = CommandResolver.parse(output)
        #expect(answer.commands["pnpm"] == "\(nvm22_14)/pnpm")
        #expect(answer.commands["ghost"] == "")
        #expect(answer.path == "\(nvm22_14):/opt/homebrew/bin:/usr/bin")
    }

    @Test func resolvesBareAndAbsoluteCommands() throws {
        let runner = FakeRunner(stdout: "__SHIRE__pnpm=\(nvm22_14)/pnpm\n__SHIRE__ghost=\n__SHIRE_PATH__=/opt/homebrew/bin\n")
        let resolver = CommandResolver(shell: "/bin/zsh", home: "/Users/me", runner: runner, fileExists: { $0 == "/Users/me/bin/tool" })
        let env = try resolver.resolve(["pnpm", "ghost", "~/bin/tool", "/missing/tool"])
        #expect(env.commands["pnpm"]?.path == "\(nvm22_14)/pnpm")
        #expect(env.commands["pnpm"]?.versionManager == "nvm")
        #expect(env.commands["ghost"]?.path == nil)
        #expect(env.commands["~/bin/tool"]?.path == "/Users/me/bin/tool")
        #expect(env.commands["/missing/tool"]?.path == nil)
        #expect(env.loginPath == "/opt/homebrew/bin")
    }

    @Test func servicePathPutsTheCommandFolderFirstWithoutDuplicates() {
        let path = CommandResolver.servicePath(
            for: [CommandResolution(command: "pnpm", path: "\(nvm22_14)/pnpm")],
            custom: "/Users/me/tools:/usr/bin"
        )
        #expect(path == "\(nvm22_14):/Users/me/tools:/usr/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func versionManagers() {
        #expect(CommandResolver.versionManager(forPath: "/Users/me/.nvm/versions/node/v22/bin/node") == "nvm")
        #expect(CommandResolver.versionManager(forPath: "/Users/me/.local/share/mise/installs/node/22/bin/node") == "mise")
        #expect(CommandResolver.versionManager(forPath: "/opt/homebrew/bin/node") == nil)
    }

    @Test func unsafeNamesAreNotSentToTheShell() {
        #expect(CommandResolver.isSafeCommandName("pnpm"))
        #expect(CommandResolver.isSafeCommandName("python3.12"))
        #expect(!CommandResolver.isSafeCommandName("x; rm -rf ~"))
        #expect(!CommandResolver.isSafeCommandName("$(whoami)"))
    }
}

@Suite("LaunchAgent plists")
struct LaunchAgentBuilderTests {
    func plist(for name: String, config: ShireConfig, home: URL = URL(fileURLWithPath: "/Users/me")) -> [String: Any] {
        let paths = ShirePaths(home: home)
        let reconciler = Reconciler(paths: paths, launchControl: FakeLaunchControl())
        return reconciler.desiredPlists(config: config, resolved: planResolution(), shireExecutable: "/Users/me/.local/bin/shire")[name]!
    }

    @Test func webServicePlist() throws {
        let config = try ConfigLoader.parse(planConfigYAML)
        let web = plist(for: "doulasimply-web", config: config)
        #expect(web["Label"] as? String == "com.shire.doulasimply-web")
        #expect(web["WorkingDirectory"] as? String == "/Users/me/Code/DoulaSimply/web")
        #expect(web["KeepAlive"] as? Bool == true)
        #expect(web["RunAtLoad"] as? Bool == true)
        let args = try #require(web["ProgramArguments"] as? [String])
        #expect(Array(args.prefix(3)) == ["/Users/me/.local/bin/shire", "run", "doulasimply-web"])
        #expect(Array(args.suffix(4)) == ["\(nvm22_14)/pnpm", "preview", "--port", "5174"])
        // Waits for its dependency's health endpoint before starting.
        let wait = try #require(args.firstIndex(of: "--wait-for"))
        #expect(args[wait + 1] == "127.0.0.1:3001")
        #expect(!args.contains("--env-file"))
        let env = try #require(web["EnvironmentVariables"] as? [String: String])
        #expect(env["PATH"]?.hasPrefix(nvm22_14) == true)
        #expect(env["SHIRE_SERVICE"] == "doulasimply-web")
    }

    @Test func envFileIsPassedAsAPathNeverAsValues() throws {
        let config = try ConfigLoader.parse(planConfigYAML)
        let api = plist(for: "doulasimply-api", config: config)
        let args = try #require(api["ProgramArguments"] as? [String])
        let index = try #require(args.firstIndex(of: "--env-file"))
        #expect(args[index + 1] == "/Users/me/Code/DoulaSimply/server/.env.demo")
        #expect(args[args.firstIndex(of: "--wait-for")! + 1] == "127.0.0.1:5432")
    }

    @Test func externalServicesGetNoPlist() throws {
        let config = try ConfigLoader.parse(planConfigYAML)
        let reconciler = Reconciler(paths: ShirePaths(home: URL(fileURLWithPath: "/Users/me")), launchControl: FakeLaunchControl())
        let all = reconciler.desiredPlists(config: config, resolved: planResolution(), shireExecutable: "/u")
        #expect(Set(all.keys) == ["doulasimply-api", "doulasimply-web", "tradingview"])
    }

    @Test func restartPolicies() throws {
        let yaml = """
        services:
          a: { command: /bin/echo, restart: on-failure }
          b: { command: /bin/echo, restart: never }
        """
        let config = try ConfigLoader.parse(yaml)
        let resolved = ResolvedEnvironment(commands: ["/bin/echo": CommandResolution(command: "/bin/echo", path: "/bin/echo")], loginPath: "")
        let reconciler = Reconciler(paths: ShirePaths(home: URL(fileURLWithPath: "/Users/me")), launchControl: FakeLaunchControl())
        let plists = reconciler.desiredPlists(config: config, resolved: resolved, shireExecutable: "/u")
        #expect((plists["a"]?["KeepAlive"] as? [String: Bool]) == ["SuccessfulExit": false])
        #expect(plists["b"]?["KeepAlive"] as? Bool == false)
    }

    @Test func differencesExplainThemselves() {
        let before: [String: Any] = [
            "ProgramArguments": ["/u", "run", "web", "--", "/old/pnpm", "preview"],
            "EnvironmentVariables": ["PATH": "/old", "NODE_ENV": "production"],
            "KeepAlive": true,
        ]
        let after: [String: Any] = [
            "ProgramArguments": ["/u", "run", "web", "--", "/new/pnpm", "preview"],
            "EnvironmentVariables": ["PATH": "/new", "NODE_ENV": "production"],
            "KeepAlive": true,
        ]
        #expect(LaunchAgentBuilder.differences(installed: before, desired: after) == ["PATH changed", "command now /new/pnpm"])
        #expect(LaunchAgentBuilder.differences(installed: after, desired: after).isEmpty)
    }

    @Test func plistRoundTripsThroughXML() throws {
        let config = try ConfigLoader.parse(planConfigYAML)
        let web = plist(for: "doulasimply-web", config: config)
        let data = try LaunchAgentBuilder.data(for: web)
        let back = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(LaunchAgentBuilder.differences(installed: back, desired: web).isEmpty)
    }
}

@Suite("launchctl print")
struct LaunchJobInfoTests {
    @Test func parsesARunningJob() {
        let output = """
        gui/501/com.shire.web = {
        \tactive count = 1
        \tpath = /Users/me/Library/LaunchAgents/com.shire.web.plist
        \tstate = running

        \tprogram = /Users/me/.local/bin/shire
        \targuments = {
        \t\t/Users/me/.local/bin/shire
        \t\trun
        \t\tweb
        \t}

        \tenvironment = {
        \t\tstate = not-this-one
        \t}
        \truns = 4
        \tpid = 739
        \tlast exit code = 127
        }
        """
        let info = LaunchJobInfo.parse(output)
        #expect(info.state == "running")
        #expect(info.pid == 739)
        #expect(info.runs == 4)
        #expect(info.lastExitCode == 127)
        #expect(info.program == "/Users/me/.local/bin/shire")
        #expect(info.arguments == ["/Users/me/.local/bin/shire", "run", "web"])
        #expect(info.isRunning)
    }

    @Test func parsesAWaitingJob() {
        let info = LaunchJobInfo.parse("gui/501/x = {\n\tstate = spawn scheduled\n\tlast exit code = 1: Operation not permitted\n}\n")
        #expect(info.state == "spawn scheduled")
        #expect(info.lastExitCode == 1)
        #expect(!info.isRunning)
    }
}
