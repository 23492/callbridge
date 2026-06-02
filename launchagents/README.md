# LaunchAgent Templates

## Purpose

This directory contains the checked-in template for the macOS LaunchAgent that auto-starts
CallBridge at login. Only the app launcher plist remains; the server plist has been deprecated
as of Phase 2 — the Python backend is now managed by CallBridge.app as a supervised child
process (BackendSupervisor class).

| File | Label | What it launches |
|------|-------|-----------------|
| `com.welisa.callbridge.plist` | `com.welisa.callbridge` | `/Applications/CallBridge.app` (GUI app) |

## Phase 2 Change

As of Phase 2 (BACK-03), the FastAPI backend is no longer started by a separate launchd
service. Instead, CallBridge.app spawns the backend as a child process when the app launches
and terminates it when the app quits. The `BackendSupervisor` class inside the app handles
spawn, health-checking, crash-restart with exponential backoff, and clean shutdown.

`com.welisa.callbridge-server.plist` has been removed from this repository and must not be
re-added.

## Install

Copy the app launcher template into your personal LaunchAgents directory and load it:

```bash
cp launchagents/com.welisa.callbridge.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.welisa.callbridge.plist
```

Once loaded, CallBridge.app starts on login and automatically starts the backend server.

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.welisa.callbridge.plist
rm ~/Library/LaunchAgents/com.welisa.callbridge.plist
```

## Migration from Older Installations

### Remove `com.welisa.callbridge-server.plist` (Phase 2 migration)

If you have `com.welisa.callbridge-server.plist` installed from an earlier version, unload
and remove it — the backend is now started automatically by the app:

```bash
launchctl unload ~/Library/LaunchAgents/com.welisa.callbridge-server.plist && rm ~/Library/LaunchAgents/com.welisa.callbridge-server.plist
```

### Remove `com.autologger.server.plist` (legacy migration)

If you have the old `com.autologger.server.plist` installed, remove it as well:

```bash
launchctl unload ~/Library/LaunchAgents/com.autologger.server.plist
rm ~/Library/LaunchAgents/com.autologger.server.plist
```
