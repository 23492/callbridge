# CallBridge

A macOS menu-bar app that automatically logs phone calls to Salesforce. It intercepts `tel://` calls, records them through Audio Hijack, transcribes (AssemblyAI), summarizes + extracts action items (Google Gemini), and writes a Call Log task + transcript note back to Salesforce.

The app **bundles and supervises its own Python backend** (nothing separate to install or keep running) and stores **all credentials in the macOS Keychain**.

## Architecture

- **CallBridge.app** — Swift/SwiftUI menu-bar app. Intercepts `tel://`, drives Audio Hijack, shows the end-of-call save dialog, and launches + health-checks + restarts the backend.
- **Embedded backend** — a self-contained Python (FastAPI) binary bundled inside the app at `Contents/Resources/callbridge-server` (built with PyInstaller). Listens on `localhost:8765`. **No conda / system Python needed at runtime.**
- **Salesforce** — username / password / security-token auth. Credentials are entered on first launch and kept in the Keychain.

## Prerequisites

- **macOS 13** or later
- **[Audio Hijack](https://rogueamoeba.com/audiohijack/)** (Rogue Amoeba) with a session named **`Voice Chat`** that records to `~/Auto Logger Recordings`
- To build from source: **Xcode Command Line Tools** (`xcode-select --install`) and **Python 3.10+**
- Credentials: a Salesforce username + password + security token, an **AssemblyAI** API key, and a **Google Gemini** API key

## Install (DMG — recommended)

When a signed release is published, installing takes under a minute and no terminal:

1. Download **`CallBridge-<version>.dmg`** from the [latest release](https://github.com/23492/callbridge/releases/latest).
2. Open the `.dmg` and **drag `CallBridge` onto the `Applications` shortcut**.
3. Open **CallBridge** from Applications. Because the build is signed with a Developer ID and notarized by Apple, it launches without a Gatekeeper warning.
4. Continue with [First launch](#first-launch) below (enter credentials, start Audio Hijack).

> Producing that signed/notarized `.dmg` is a maintainer step — see [`docs/SIGNING-AND-DISTRIBUTION.md`](docs/SIGNING-AND-DISTRIBUTION.md). Until a signed release exists, build from source below.

## Install (build from source)

```bash
git clone https://github.com/23492/callbridge.git
cd callbridge/CallBridge

# 1 — Build the Swift app
swift build -c release
mkdir -p CallBridge.app/Contents/MacOS
cp .build/release/CallBridge CallBridge.app/Contents/MacOS/CallBridge
cp CallBridge/Info.plist CallBridge.app/Contents/Info.plist
cd ..

# 2 — Bundle the Python backend (self-contained, no conda)
VENV=$(mktemp -d); python3 -m venv "$VENV"
"$VENV/bin/pip" install -q -r requirements.txt pyinstaller
"$VENV/bin/pyinstaller" callbridge-server.spec --noconfirm \
  --distpath CallBridge/CallBridge.app/Contents/Resources
rm -rf "$VENV"

# 3 — Install to /Applications
rm -rf /Applications/CallBridge.app
cp -R CallBridge/CallBridge.app /Applications/CallBridge.app
open /Applications/CallBridge.app
```

*(Tip: instead of building on each Mac, you can build once and copy `CallBridge.app` over — then run `xattr -dr com.apple.quarantine /Applications/CallBridge.app` on the target Mac before opening.)*

## First launch

1. **Gatekeeper** — the app isn't notarized yet, so macOS will warn. Right-click it in `/Applications` → **Open** (once), or go to System Settings → Privacy & Security → **Open Anyway**.
2. **Enter credentials** — a Settings window opens automatically whenever credentials are missing or the Salesforce login fails. Enter your Salesforce username/password/token + AssemblyAI key + Gemini key, then click **Valideer**. They're validated against Salesforce (read-only) and saved to the Keychain. You can reopen it any time from the menu-bar **Instellingen…** item.
3. **Audio Hijack** — make sure Audio Hijack is running with the `Voice Chat` session.

The backend starts automatically with the app — there is nothing else to launch.

## Auto-start on login (optional)

```bash
cp launchagents/com.welisa.callbridge.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.welisa.callbridge.plist
```

## Updating

Once signed releases are published, installed copies **auto-update** within the hour: CallBridge checks `callbridge-update.json`, downloads the new `CallBridge.app.zip`, verifies its Ed25519 signature, and replaces itself. To update manually, download the latest `.dmg` and drag the new app over the old one (or, from source, re-run the build/install steps above).

## Roadmap

Done: SwiftPM build, self-contained PyInstaller backend embedded in the app, Keychain credential storage with a first-run/auth-failure Settings prompt, Audio Hijack `Voice Chat` session template shipped in releases, **Developer ID signing + notarization + a drag-to-Applications `.dmg` installer** (build automation in `build-release.sh` / `build-dmg.sh`; see [`docs/SIGNING-AND-DISTRIBUTION.md`](docs/SIGNING-AND-DISTRIBUTION.md)).

Planned: publish the first signed `.dmg` release once the Apple Developer ID is provisioned · enable auto-update releases on a public download host.
