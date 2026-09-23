# Tender

Keep a Mac in the state `config.yaml` describes: services running, healthy, and explained when they aren't.
See [PLAN.md](PLAN.md) for the product plan.

## Status

- **Phase 1 (core):** the `tender` command line, config validation, LaunchAgent management, logging with rotation,
  crash-loop detection and likely-cause messages.
- **Phase 2 (server mode):** tender-agent keeps the Mac awake while on power, `tender doctor` checks whether the Mac
  will keep serving without you, and `tender status` shows tender-agent, keep-awake, Tailscale and readiness.

Health checks running continuously, alerts, the phone page and the menu bar app come in later phases.

## Install

Requires macOS 14 or later and Swift 6.

```bash
make test
make install          # installs to ~/.local/bin/tender (PREFIX=… to change)
```

LaunchAgents point at the installed binary, so install before running `tender apply`.

## Use

```bash
mkdir -p ~/.config/tender
cp examples/config.yaml ~/.config/tender/config.yaml   # then edit it

tender validate           # schema, resolved commands, folders, dependencies, ports
tender apply --dry-run    # what would change
tender apply              # make it so; only changed services restart
tender status             # process state, health, likely cause
tender logs <service> -f
tender restart <service>  # runs the build step first; --no-build to skip
tender stop|start <service>
tender doctor             # updates, login, power, lid, disk, Tailscale, tender-agent
tender uninstall          # remove every Tender LaunchAgent (config and logs stay)
```

## How it works

- Each managed service becomes `~/Library/LaunchAgents/com.tender.<service>.plist`. Tender never touches other agents.
- The plist runs `tender run <service>`, which waits for dependencies, loads `envFile`, runs the real command,
  writes `~/Library/Logs/tender/<service>.{stdout,stderr}.log` with rotation, and records starts and exits for
  crash-loop detection.
- Commands are resolved through your login shell on every `apply`, because launchd doesn't know about nvm or
  Homebrew. A service's PATH is its command's folder plus Homebrew and the system, so switching Node versions only
  restarts the services that use Node.
- `external:` services (like Homebrew's Postgres) are watched, never managed.
- `build:` runs on `apply` (for new or changed services) and on `restart`, never on launchd's automatic respawns.
- `apply` also installs tender-agent (`com.tender.agent`). It re-reads config.yaml when it changes and holds a
  `PreventUserIdleSystemSleep` assertion while `serverMode.keepAwake` is on and the Mac is on power; on battery it
  lets go so the Mac can sleep. State is written to `~/Library/Application Support/Tender/agent.json`.
