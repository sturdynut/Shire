# Uplift

Keep a Mac in the state `config.yaml` describes: services running, healthy, and explained when they aren't.
See [PLAN.md](PLAN.md) for the product plan.

## Status

Phase 1 (the core) is in place: the `uplift` command line, config validation, LaunchAgent management,
logging with rotation, crash-loop detection and likely-cause messages. The menu bar app, uplift-agent,
alerts and the phone page come in later phases.

## Install

Requires macOS 14 or later and Swift 6.

```bash
make test
make install          # installs to ~/.local/bin/uplift (PREFIX=… to change)
```

LaunchAgents point at the installed binary, so install before running `uplift apply`.

## Use

```bash
mkdir -p ~/.config/uplift
cp examples/config.yaml ~/.config/uplift/config.yaml   # then edit it

uplift validate           # schema, resolved commands, folders, dependencies, ports
uplift apply --dry-run    # what would change
uplift apply              # make it so; only changed services restart
uplift status             # process state, health, likely cause
uplift logs <service> -f
uplift restart <service>  # runs the build step first; --no-build to skip
uplift stop|start <service>
```

## How it works

- Each managed service becomes `~/Library/LaunchAgents/com.uplift.<service>.plist`. Uplift never touches other agents.
- The plist runs `uplift run <service>`, which waits for dependencies, loads `envFile`, runs the real command,
  writes `~/Library/Logs/uplift/<service>.{stdout,stderr}.log` with rotation, and records starts and exits for
  crash-loop detection.
- Commands are resolved through your login shell on every `apply`, because launchd doesn't know about nvm or
  Homebrew. A service's PATH is its command's folder plus Homebrew and the system, so switching Node versions only
  restarts the services that use Node.
- `external:` services (like Homebrew's Postgres) are watched, never managed.
- `build:` runs on `apply` (for new or changed services) and on `restart`, never on launchd's automatic respawns.
