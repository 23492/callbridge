# LaunchAgent Templates

## Purpose

This directory contains checked-in templates for the two macOS LaunchAgents that run CallBridge
automatically at login. Previously these plists lived only on the developer's machine; they are
now versioned here under a unified `com.welisa.*` identifier namespace (BUILD-04).

| File | Label | What it launches |
|------|-------|-----------------|
| `com.welisa.callbridge.plist` | `com.welisa.callbridge` | `/Applications/CallBridge.app` (GUI app) |
| `com.welisa.callbridge-server.plist` | `com.welisa.callbridge-server` | uvicorn FastAPI backend on port 8765 |

## Install

Copy both templates into your personal LaunchAgents directory and load them:

```bash
cp launchagents/com.welisa.callbridge.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.welisa.callbridge.plist

cp launchagents/com.welisa.callbridge-server.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.welisa.callbridge-server.plist
```

To reload after making changes:

```bash
launchctl unload ~/Library/LaunchAgents/com.welisa.callbridge-server.plist
launchctl load ~/Library/LaunchAgents/com.welisa.callbridge-server.plist
```

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.welisa.callbridge.plist
rm ~/Library/LaunchAgents/com.welisa.callbridge.plist

launchctl unload ~/Library/LaunchAgents/com.welisa.callbridge-server.plist
rm ~/Library/LaunchAgents/com.welisa.callbridge-server.plist
```

## Migration from Legacy `com.autologger.server.plist`

If you have the old `com.autologger.server.plist` installed, unload and remove it before
installing the new server plist:

```bash
launchctl unload ~/Library/LaunchAgents/com.autologger.server.plist
rm ~/Library/LaunchAgents/com.autologger.server.plist
```

Then install the new plist:

```bash
cp launchagents/com.welisa.callbridge-server.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.welisa.callbridge-server.plist
```

## Customization

The server plist `com.welisa.callbridge-server.plist` has two hardcoded values that may need
adjusting for your machine:

- **`WorkingDirectory`** — defaults to `/Users/kiranknoppert/dev/callbridge`. Change this to
  wherever you have cloned the repository.
- **`python3.13` path** — defaults to `/opt/homebrew/Caskroom/miniconda/base/bin/python3.13`
  (the conda-managed interpreter). Change this if your Python 3.13 lives elsewhere.

**Note:** Phase 2 (BACK-02) will eliminate the hardcoded conda path by introducing a
self-contained Python environment, after which this plist will no longer need customization.
