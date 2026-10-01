# Auto Logger - Call Logger & Salesforce Integration

## Architecture

Three-tier system: macOS app (Swift) → Python backend (FastAPI) → Salesforce

### CallBridge (Swift macOS app)

- **Source**: `CallBridge/CallBridge/main.swift`
- **Installed at**: `/Applications/CallBridge.app`
- Intercepts `tel://` URLs, starts Audio Hijack recording, detects call end, shows save dialog
- Dialog options: "Niet opslaan" (discard), "NNO" (log no-answer + follow-up), "Opslaan" (full processing)
- Communicates with backend at `http://localhost:8765`

### Python Backend (FastAPI)

- **Entry**: `main.py` — runs via uvicorn on port 8765
- **Services**: `services/salesforce.py`, `services/transcription.py` (AssemblyAI), `services/summarizer.py` (Gemini)
- **Endpoints**: `/health`, `/contact-search`, `/process`, `/process-manual`, `/log-nno`
- **Dashboard**: `dashboard/index.html` for manual uploads

### Salesforce Integration

- Uses `simple_salesforce` library via conda Python (`/opt/homebrew/Caskroom/miniconda/base/bin/python3.13`)
- Domain: `login` (production org: welisa)
- Creates Tasks (call logs), ContentNotes (transcripts), action item Tasks
- NNO flow: completed "NNO" task (today) + "Call back" follow-up task (tomorrow)

## Build & Deploy

```bash

# Build the Swift app

cd CallBridge && swiftc -o CallBridge.app/Contents/MacOS/CallBridge CallBridge/main.swift -framework Cocoa -framework SwiftUI

# Deploy: kill running instance, remove old app, copy fresh (cp -R alone won't overwrite the binary)

pkill -f "CallBridge.app"; sleep 1; rm -rf /Applications/CallBridge.app && cp -R CallBridge/CallBridge.app /Applications/CallBridge.app
```

## Auto-Start (LaunchAgents)

Both services start on login via `~/Library/LaunchAgents/`:

- `com.welisa.callbridge.plist` — launches `/Applications/CallBridge.app`
- `com.welisa.callbridge-server.plist` — launches uvicorn (KeepAlive: true), logs to `logs/`

Reload after changes:

```bash
launchctl unload ~/Library/LaunchAgents/com.welisa.callbridge-server.plist
launchctl load ~/Library/LaunchAgents/com.welisa.callbridge-server.plist
```

Plist templates live in `launchagents/` — see `launchagents/README.md` for install instructions.

## Releasing CallBridge Updates

CallBridge has a built-in auto-updater. Running instances check `callbridge-update.json` every 60 min and auto-update via Ed25519-signed GitHub Releases.

```bash

# Build, sign, and prepare a release:

./build-release.sh 1.2.0

# Commit, push, and create GitHub release:

git add -A && git commit -m "Release v1.2.0" && git push
gh release create v1.2.0 CallBridge.app.zip --title "v1.2.0" --notes "..."
```

### Beta channel

Two release channels, each with its own manifest:

- **stable**: `callbridge-update.json` on `main`, versions like `2.0.9`
- **beta**: `callbridge-update.json` on `beta`, versions like `2.1.0-beta.1` (GitHub pre-release)

Users switch in Instellingen → Updates → "Bètaversies ontvangen" (stored in UserDefaults key `updateChannel`; default follows the build's `appBuildChannel`). Beta users also get a stable release once it is newer than the newest beta. Switching back to stable offers "↩ Terug naar stabiel" even when that is an older version.

Release a beta: run the Release workflow on the `beta` branch with a `-beta.N` version. Promote: merge `beta` into `main`, then release the final version from `main`. The channel rules are tested by `scripts/test-update-channel.sh`.

Key files:

- `callbridge-update.json` — version manifest (committed to repo, fetched by running instances)
- `sign-update.swift` — Ed25519 signing tool (reads `SIGNING_PRIVATE_KEY` from `.env`)
- `build-release.sh` — automates build, sign, and manifest update

## Config

- `.env` — API keys, Salesforce credentials, and `SIGNING_PRIVATE_KEY` (gitignored)
- `config.py` — reads env vars
- Audio Hijack session name: "Voice Chat"
- Recordings dir: `~/Auto Logger Recordings`

<!-- GSD:project-start source:PROJECT.md -->

## Project

**Autologger (CallBridge v3)**

CallBridge is Kiran's macOS menu-bar app that records sales conversations and logs them to the Welisa Salesforce production org. Today it only handles phone calls: it intercepts `tel:` links, records through Audio Hijack, transcribes with AssemblyAI, summarises with Gemini and writes a call Task, transcript and action items to Salesforce. Autologger turns it into one logger for every conversation: phone calls and online meetings (Google Meet in the browser, Slack huddles) are recorded natively, transcribed through the Welisa transcribe app (app.welisa.dev/transcribe) and logged in the right place in Salesforce without manual steps.

**Core Value:** Every sales conversation Kiran has, by phone or in a meeting, ends up correctly logged in Salesforce without him having to start, upload or file anything by hand.

### Constraints

- **Tech stack**: Swift (macOS app) + Python FastAPI backend — keep; no language change.
- **Platform**: macOS 14.4+ (Kiran and colleagues are all on 14.4 or newer); raise `LSMinimumSystemVersion` from 13.0. Native capture uses a Core Audio global process tap, not ScreenCaptureKit.
- **Permissions**: microphone, system audio recording and Automation (browser tab probing) are TCC permissions tied to the code signature. With ad-hoc signing (kept for now, by decision) every update drops them, so the app must detect a missing grant (silent all-zero tap buffers) and guide the user to re-grant.
- **Salesforce**: production org `welisa`. Any end-to-end test that writes to production needs Kiran's manual approval, even in YOLO mode.
- **Transcribe app**: behind Cloudflare Access; unauthenticated calls redirect to an HTML login page. Its API can change without notice because it is internal.
- **Rollout**: beta channel to Kiran first; stable for colleagues only after it has been used for real.

<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->

## Technology Stack

## Languages

- Swift (swift-tools-version 5.9) - The macOS menu-bar app, all in one file: `CallBridge/CallBridge/main.swift` (~2,690 lines). Also the release signing script `sign-update.swift` and the test harness `tests/UpdateChannelTests.swift`.
- Python 3.10+ - FastAPI backend: `main.py`, `config.py`, `services/salesforce.py`, `services/summarizer.py`, `services/transcription.py`. PEP 604 unions (`str | None`) and builtin generics (`dict[str, dict]`, `list[dict]`) in `main.py` and `services/*.py` set the 3.10 floor. README states "Python 3.10+" (`README.md`).
- Bash - Build/release and test scripts: `build-release.sh`, `scripts/test-backend-bundle.sh`, `scripts/test-update-channel.sh`. The app also writes and runs a bash relaunch trampoline at update time (`replaceAndRelaunch` in `CallBridge/CallBridge/main.swift`).
- HTML/vanilla JavaScript - Manual-upload dashboard, no framework or CDN: `dashboard/index.html` (calls `fetch('/health')` and `fetch('/process-manual')`).
- JavaScript (Node, no dependencies) - Offline NNO detection prototype, not shipped: `docs/beta/nno-prototype.js`.
- AppleScript (via `/usr/bin/osascript`) - User notifications from both Swift (`showNotification`) and Python (`_notify` in `main.py`).
- Audio Hijack JavaScript - Scripting commands written to `.ahcommand` files (`runAudioHijackScript` in `CallBridge/CallBridge/main.swift`).
- XML plist - `CallBridge/CallBridge/Info.plist`, `launchagents/com.welisa.callbridge.plist`; binary plist `audio-hijack/Voice Chat.ah4session`.

## Runtime

- macOS 13.0+ (`LSMinimumSystemVersion` in `CallBridge/CallBridge/Info.plist`; `.macOS(.v13)` in `CallBridge/Package.swift`).
- The Swift app runs as an agent (`LSUIElement = true`, menu bar only), bundle id `com.welisa.callbridge`.
- The Python backend runs as a self-contained PyInstaller `--onedir` binary embedded at `CallBridge.app/Contents/Resources/callbridge-server/callbridge-server` (spec: `callbridge-server.spec`). No system Python, conda, or launchd service is used at runtime. `BackendSupervisor` in `CallBridge/CallBridge/main.swift` spawns it as a child process with `currentDirectoryURL` = `~/Library/Application Support/com.welisa.CallBridge`.
- Backend binds `127.0.0.1:8765` via `uvicorn.run` (`main.py` bottom). Frozen-bundle detection uses `sys._MEIPASS` to locate the bundled `dashboard/` (`main.py` lines 49-53).
- pip (in a throwaway venv created by `build-release.sh` and `scripts/test-backend-bundle.sh`).
- Lockfile: missing. `requirements.txt` pins exact versions but there is no hash-locked file; transitive deps (pydantic, starlette) are unpinned.
- Swift Package Manager: `CallBridge/Package.swift`, zero external dependencies (`dependencies: []`). No `Package.resolved` needed.

## Frameworks

- FastAPI 0.115.0 - HTTP API (`main.py`): `/health`, `/validate-credentials`, `/status`, `/contact-search`, `/log-nno`, `/process`, `/process-manual`, static mount `/dashboard`.
- Starlette (transitive via FastAPI) - `TrustedHostMiddleware` and `StaticFiles` (`main.py` lines 13-14, 66, 118).
- Pydantic (transitive via FastAPI) - `CredentialValidationRequest` model (`main.py` line 169).
- Uvicorn 0.30.6 - ASGI server (`main.py` line 476-477).
- Cocoa / AppKit - `NSStatusItem` menu, `NSWorkspace` (tel: handler, opening Phone/FaceTime/Audio Hijack), `NSApplication` (`CallBridge/CallBridge/main.swift`).
- SwiftUI - Settings window, save dialog, manual-process window (`ObservableObject` view models such as `ManualProcessViewModel`).
- CryptoKit - `Curve25519.Signing` Ed25519 verification of update zips (`verifySignature`) and signing in `sign-update.swift`.
- Security framework - Keychain generic-password storage (`KeychainHelper`, service `com.welisa.CallBridge`).
- AVFoundation - `AVAudioPlayer` playback in the manual-process window (`ManualProcessViewModel`).
- No test framework (no XCTest, no pytest). Swift update-channel logic is tested by a custom assertion harness: `tests/UpdateChannelTests.swift`, compiled with `swiftc` by `scripts/test-update-channel.sh` (extracts the `// MARK: - Update Channel` section of `main.swift`; runs on macOS or Linux).
- Backend bundle integration test: `scripts/test-backend-bundle.sh` (builds the PyInstaller bundle, hits `/health`, `/contact-search`, `/process` with credentials stripped so nothing is written to Salesforce).
- SwiftPM `swift build -c release` (`build-release.sh`, `.github/workflows/build.yml`).
- PyInstaller (unpinned, installed at build time) with `callbridge-server.spec`: hidden imports for uvicorn runtime modules, `multipart`, `fastapi`, `simple_salesforce`, `dotenv`; excludes tkinter/matplotlib/numpy/PIL/scipy; `upx=True`; bundles `dashboard/`.
- `/usr/libexec/PlistBuddy` - version stamping of `Info.plist` (`build-release.sh`).
- `codesign --force --sign -` - ad-hoc code signing of the bundle (`build-release.sh` step 4b). No Developer ID, no notarization.
- `ditto` - zip creation (`build-release.sh`) and unzip during auto-update (`UpdateChecker` in `main.swift`).
- `gh` CLI - publishing GitHub Releases (`.github/workflows/release.yml`).

## Key Dependencies

- `simple-salesforce==1.12.6` - All Salesforce reads/writes (SOQL, SOSL, sObject create/update) in `services/salesforce.py`; credential check in `main.py` `/validate-credentials`.
- `requests==2.32.3` - Raw REST calls to AssemblyAI (`services/transcription.py`) and Google Gemini (`services/summarizer.py`). No vendor SDKs.
- `python-multipart==0.0.9` - Required by FastAPI for `UploadFile`/`Form` parsing on `/process`, `/process-manual`, `/log-nno`.
- `fastapi==0.115.0`, `uvicorn==0.30.6` - Backend server.
- `python-dotenv==1.0.1` - Listed in `requirements.txt` and as a PyInstaller hidden import, but no code calls `load_dotenv`. `config.py` reads `os.getenv` only; values arrive through the process environment set by `BackendSupervisor`. Treat it as an unused dependency.
- Audio Hijack (Rogue Amoeba, bundle id `com.rogueamoeba.audiohijack`) - Required third-party macOS app for recording; session template `audio-hijack/Voice Chat.ah4session`.

## Configuration

- Secrets live in the macOS Keychain (service `com.welisa.CallBridge`, one generic-password item per key) and are entered in the SwiftUI Settings window (`save()` in `CallBridge/CallBridge/main.swift`). On every spawn, `BackendSupervisor.spawnLocked()` reads them from the Keychain and injects them as environment variables of the backend process. `reloadCredentials()` restarts the backend after Settings saves.
- Keys (names only): `ASSEMBLYAI_API_KEY`, `GEMINI_API_KEY`, `SF_USERNAME`, `SF_PASSWORD`, `SF_SECURITY_TOKEN`, `SF_DOMAIN`.
- Backend reads them in `config.py` via `os.getenv`. `SF_DOMAIN` defaults to `"welisa"` in `config.py` and the Settings view; the launch-time credential gate defaults to `"login"`.
- Hard-coded config in `config.py`: `GEMINI_MODEL = "gemini-3-flash-preview"`.
- Hard-coded config in `CallBridge/CallBridge/main.swift`: `appVersion`, `appBuildChannel` (`"stable"` or `"beta"`, rewritten by `build-release.sh`), `updatePublicKey` (Ed25519 public key, base64), `serverURL = "http://localhost:8765"`, `audioHijackSessionName = "Voice Chat"`, `recordingsDir = ~/Auto Logger Recordings`, `phoneAppBundleID = "com.apple.mobilephone"`.
- User preference: update channel in `UserDefaults` key `updateChannel` (`UpdateChannel.current`); default follows `appBuildChannel`.
- `.env.example` present (template listing the six credential keys plus `SIGNING_PRIVATE_KEY`). `.env` is gitignored and used only by `sign-update.swift` for `SIGNING_PRIVATE_KEY` at release time; the CI release job writes it from a secret and deletes it afterwards.
- `CallBridge/Package.swift` - SwiftPM target `CallBridge`, path `CallBridge/CallBridge`.
- `CallBridge/CallBridge/Info.plist` - bundle metadata, `tel` URL scheme registration, version (numeric core only, e.g. `2.1.0`).
- `callbridge-server.spec` - PyInstaller spec.
- `build-release.sh` - accepts `MAJOR.MINOR.PATCH` or `MAJOR.MINOR.PATCH-beta.N`; derives channel from the suffix.
- `callbridge-update.json` - update manifest (`version`, `url`, `signature`, `notes`), regenerated by `build-release.sh`. One copy per branch: `main` = stable, `beta` = beta.
- `.gitignore` - excludes `.env`, `.signing-key`, `CallBridge/CallBridge.app/`, `.build/`, `build/`, `*.app.zip`, `.planning/`, `logs/`, `.venv/`.

## Platform Requirements

- macOS with Xcode Command Line Tools (Swift 5.9+), Python 3.10+ with `venv`.
- Audio Hijack installed with a `Voice Chat` session recording to `~/Auto Logger Recordings`.
- For releases: the Ed25519 private key as `SIGNING_PRIVATE_KEY` (CI secret or local `.env`), `gh` CLI.
- `scripts/test-update-channel.sh` needs only `swiftc` (override with `SWIFTC`).
- End-user Macs on macOS 13+, app installed at `/Applications/CallBridge.app` (the app only claims the `tel:` handler from an installed copy; see `claimTelHandler`).
- Distributed as an ad-hoc-signed, non-notarized `CallBridge.app.zip` on GitHub Releases (`github.com/23492/callbridge`); users clear quarantine or use right-click Open.
- Optional login auto-start via `launchagents/com.welisa.callbridge.plist` (runs `/usr/bin/open /Applications/CallBridge.app`).
- Runtime file locations: backend log `~/Library/Logs/CallBridge/backend.log` (rotated at 10 MB), Python log `~/Library/Logs/CallBridge/call_logger.log`, Swift debug log `/tmp/callbridge_debug.log`.

<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->

## Conventions

## Naming Patterns

- Swift app is a single file: `CallBridge/CallBridge/main.swift` (2689 lines). New Swift code goes into this file under a `// MARK: -` section, not into new files (the SwiftPM target in `CallBridge/Package.swift` and the `swiftc` one-liner in `CLAUDE.md` both assume one source file; `scripts/test-update-channel.sh` extracts sections from it by MARK name).
- Python modules: lowercase snake_case nouns: `main.py`, `config.py`, `services/salesforce.py`, `services/transcription.py`, `services/summarizer.py`.
- Shell scripts: kebab-case with a verb prefix: `build-release.sh`, `scripts/test-update-channel.sh`, `scripts/test-backend-bundle.sh`.
- Swift test files: PascalCase + `Tests` suffix: `tests/UpdateChannelTests.swift`.
- Python: snake_case verbs (`find_contact_by_phone`, `create_call_log`, `transcribe_audio`, `generate_summary`). Module-private helpers get a leading underscore (`_get_sf`, `_soql_str`, `_sanitize_phone`, `_normalize_record`, `_post_gemini`, `_extract_text`, `_notify_error` in `main.py`).
- Swift: lowerCamelCase verbs (`checkForUpdate`, `downloadAndApply`, `verifySignature`, `lookupContact`, `sendToBackend`, `contactSearchURL`). Pure logic is written as free functions so it can be tested without Cocoa: `decideUpdate(installed:buildChannel:selected:stableManifest:betaManifest:)` and `xmlEscape(_:)` in `main.swift`.
- Python: snake_case locals. Module-level constants UPPER_SNAKE (`ASSEMBLY_URL`, `MAX_RETRIES`, `GEMINI_TIMEOUT`, `FOLLOWUP_SUBJECTS`, `ALLOWED_RECORD_TYPES`). Private module constants and mutable singletons get a leading underscore (`_SF_IDLE_RELOGIN_SECONDS`, `_SF_ID_RE`, `_sf`, `_sf_lock`, `_jobs_lock`, `_processing_jobs`, `_completed_jobs`, `_ALLOWED_ORIGINS`).
- Swift: lowerCamelCase (`statusItem`, `recordingsDir`, `currentCallID`, `pendingRestart`). Top-level constants use `let` with lowerCamelCase (`appVersion`, `appBuildChannel`, `updatePublicKey`, `debugLogPath`).
- `let appVersion = "..."` and `let appBuildChannel = "..."` at the top of `main.swift` must keep that exact shape on one line: `build-release.sh` rewrites them with `sed`, and `scripts/test-update-channel.sh` extracts them with `grep -E '^let (appVersion|appBuildChannel) = '`.
- Swift structs/classes/enums: PascalCase (`ContactInfo`, `ProcessingJob`, `UpdateChecker`, `KeychainHelper`, `BackendSupervisor`, `SaveDialogViewModel`). Enum cases lowerCamelCase (`.idle`, `.recording(...)`, `.returnToStable(String)`).
- Swift `Codable` structs that mirror backend JSON keep the backend's snake_case property names (`account_name`, `job_id`, `task_id`, `future_tasks` in `ContactInfo`, `ProcessingJob`, `CompletedJob`); no `CodingKeys` are used. Keep JSON field names identical on both sides.
- View models: `<Feature>ViewModel` subclassing `ObservableObject` with `@Published` properties (`SettingsViewModel`, `SaveDialogViewModel`, `ManualProcessViewModel`); views: `<Feature>View` with `@ObservedObject var viewModel`.
- Python: plain `dict` for domain data. The only Pydantic model is `CredentialValidationRequest` in `main.py`. Type hints use PEP 604/585 syntax (`str | None`, `dict[str, dict]`, `list[dict]`, `tuple[str, str]`).

## Code Style

- No formatter configured (no `pyproject.toml`, `setup.cfg`, `.swift-format`, `.swiftlint.yml`, `.editorconfig`).
- 4-space indentation in Swift, Python and shell.
- Python strings: double quotes. Logging uses `%s` lazy formatting (`logger.info("Created %s", x)`), never f-strings in logger calls. f-strings are used for SOQL/SOSL and user messages.
- Swift aligns related dictionary/argument columns with spaces (Keychain queries in `KeychainHelper`, `KeychainHelper.save(...)` calls in `SettingsViewModel.save()`).
- None. No CI lint step in `.github/workflows/build.yml`. The only static check is the macOS `swift build -c release` compile.

## Import Organization

- None. Python imports resolve from the repo root (`from services.x import y`, `from config import Z`); `services/__init__.py` is empty.

## Error Handling

- Pipeline errors are caught once at the top of `process_pipeline()` in `main.py`: `except Exception as e: logger.error(..., exc_info=True); _fail_job(job_id); _notify_error(str(e))`, with temp-file cleanup in `finally`.
- Non-fatal steps get their own inner `try/except` that logs and continues (summary failure falls back to a Dutch placeholder summary; action-item extraction and per-action Task creation log a warning). Rule from the code: a paid-for transcript must never be thrown away because a later step failed.
- Validation errors from services raise `ValueError`; endpoints convert them to `HTTPException(status_code=400, detail=str(e))` (`/log-nno`). Input checks happen at the endpoint before work starts (`/process` checks `ALLOWED_RECORD_TYPES` and `is_valid_sf_id`).
- External HTTP: always pass an explicit `timeout=` tuple (`UPLOAD_TIMEOUT`, `REQUEST_TIMEOUT`, `GEMINI_TIMEOUT`), then `response.raise_for_status()`. Gemini retries via `_post_gemini()` in `services/summarizer.py`: exponential backoff `2 ** attempt * 5`, retries on 5xx/429/connection/timeout, honours `Retry-After` capped at `MAX_RETRY_AFTER`, and stops immediately on a daily-quota 429.
- Unusable API responses raise `RuntimeError` with a Dutch message that ends up in the user notification (`"Gemini gaf een leeg antwoord (finishReason: ...)"`).
- Anything interpolated into SOQL/SOSL is validated or escaped first (`_soql_str`, `is_valid_sf_id`, `ALLOWED_RECORD_TYPES`). Anything interpolated into AppleScript goes through `_osa_str()` and `subprocess.run([...])` without a shell.
- Swallowing is reserved for best-effort side effects: `_notify()` and `os.remove` cleanup (`except OSError: pass`).
- `guard let ... else { debugLog(...); return }` for early exit; network callbacks combine `data`, `error == nil` and `try? JSONDecoder().decode` in one guard and fall back to `nil`/`[]` via the completion handler (`lookupContact`, `searchContacts`).
- `do/catch` around `Process.run()`, file writes and CryptoKit calls, each logging via `debugLog` and resetting state (`isUpdating = false`) on the main queue.
- `try?` for best-effort filesystem calls (`createDirectory`, `removeItem`).
- UI updates hop to `DispatchQueue.main.async`; closures capture `[weak self]` and start with `guard let self = self else { return }`.
- Stale async completions are rejected with generation/identity tokens: `currentCallID: UUID?` on `AppDelegate`, `generation` counter in `BackendSupervisor`, and query-equality checks in `SaveDialogViewModel.search()`.
- Shared mutable state is confined to one serial queue (`BackendSupervisor.queue`) or protected by `NSLock` (`UpdateChecker.checkForUpdate`).
- User-facing failures are shown as macOS notifications (`showNotification` via `osascript`) or inline status text, in Dutch.

## Logging

- Python: one `logger = logging.getLogger(__name__)` per module. Root config lives only in `main.py` (`logging.basicConfig`, format `"%(asctime)s [%(levelname)s] %(name)s: %(message)s"`, file `~/Library/Logs/CallBridge/call_logger.log` plus stderr).
- Swift: `debugLog("<Component>: message")` appends ISO8601-stamped lines to `/tmp/callbridge_debug.log` (55 call sites). Prefix messages with the component name (`"UpdateChecker: ..."`, `"KeychainHelper: ..."`, `"BackendSupervisor: ..."`, `"Settings: ..."`). `NSLog` (17 call sites) is used for a few major events.
- Never log secret values. Keychain helpers log key names and `OSStatus` only.

## Comments

- Explain *why*, especially the bug or failure a line prevents. This is the dominant style:
- Security rationale is written next to the guard (`_ALLOWED_ORIGINS` and `TrustedHostMiddleware` in `main.py`).
- Numbered step comments inside long pipelines (`# 1. Find contact ...` through `# 9. Clean up temp file` in `process_pipeline`).
- Write comments in English. UI strings, notifications, Gemini prompts and user-facing error messages are Dutch.
- Python: triple-quoted docstrings on public functions and non-obvious helpers, describing purpose, return shape and edge rules (`transcribe_audio`, `_normalize_due_date`, `_post_gemini`). No parameter-by-parameter sections.
- Swift: `///` doc comments on types and properties whose purpose is not obvious (`UpdateChannel`, `AppVersion`, `UpdateDecision`, `AppDelegate.currentCallID`, `appBuildChannel`).
- Organize Swift with `// MARK: - Section` headers (Version & Update Config, Debug Logging, Data Models, Status Models, Update Channel, Update Manifest, Update Checker, Keychain, Backend Supervisor, Call State Machine, Settings, App Delegate, SwiftUI View Model, SwiftUI Views, Manual Process View Model, Manual Process View, App Entry Point). Nested `// MARK: -` inside `AppDelegate` group methods (URL Handler, Audio Hijack Control, Polling, Server Communication, Save Dialog, Utilities).
- The `// MARK: - Update Channel` and `// MARK: - Update Manifest` headers are load-bearing: the test script extracts everything between them. Keep only pure, Foundation-only code in that section.

## Function Design

- Python: explicit typed parameters with defaults for optional fields (`direction: str = "Outbound"`, `salesforce_id: str | None = None`). FastAPI endpoints declare inputs with `Form(...)`, `File(...)`, `Query(None)`.
- Swift: labelled parameters, default values for optional behaviour (`checkForUpdate(notify: Bool = false, callback: (() -> Void)? = nil)`), `@escaping` completion closures for async work.
- Python: `dict | None` for lookups (`find_contact_by_phone`), `list[dict]` for searches, `tuple[str, str]` for paired Ids (`create_nno_log`), plain dicts from endpoints (`{"status": "processing", ...}`).
- Swift: optionals and failable initializers for parsing (`AppVersion.init?(_:)`), enums with associated values for decisions (`UpdateDecision`), completion handlers for network results.

## Module Design

<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->

## Architecture

## System Overview

```text

```
- Update manifests: `https://raw.githubusercontent.com/23492/callbridge/{main|beta}/callbridge-update.json` (fetched by `UpdateChecker`, `main.swift` L242-448).
- Salesforce SOAP login straight from Swift for credential validation (`main.swift` L896-956 and L1203-1257), bypassing the backend.
- Browser dashboard at `http://localhost:8765/dashboard` (`dashboard/index.html`) uploading to `/process-manual`.

## Component Responsibilities

| Component | Responsibility | File / lines |
|-----------|----------------|------|
| Version globals | `appVersion`, `appBuildChannel`, `updatePublicKey` (rewritten by `build-release.sh` via `sed`) | `CallBridge/CallBridge/main.swift` L8-13 |
| `debugLog` / `xmlEscape` | Append-only trace to `/tmp/callbridge_debug.log`; XML escape for SOAP | `main.swift` L15-40 |
| Data models | `ContactInfo`, `SearchResponse`, `ProcessingJob`, `FutureTask`, `CompletedJob`, `StatusResponse` (Codable mirrors of backend JSON, snake_case fields) | `main.swift` L42-138 |
| Update channel rules (pure) | `UpdateChannel`, `AppVersion`, `UpdateDecision`, `decideUpdate(...)` | `main.swift` L140-231 |
| `UpdateManifest` | Decodes `callbridge-update.json` | `main.swift` L233-240 |
| `UpdateChecker` | Fetch both manifests, decide, download, Ed25519 verify, unzip with `ditto`, trampoline relaunch | `main.swift` L242-448 |
| `KeychainHelper` | Generic-password items under service `com.welisa.CallBridge` | `main.swift` L450-519 |
| `BackendSupervisor` | Spawn/health-check/restart/stop embedded backend; port reclaim | `main.swift` L521-848 |
| `CallState` | `idle` / `recording` / `showingDialog` / `processing` | `main.swift` L850-857 |
| `SettingsViewModel` + `SettingsView` | Credential entry, SOAP validation, beta toggle | `main.swift` L859-1034 |
| `AppDelegate` | Everything else: lifecycle, menu, tel: handling, recording, polling, dialogs, HTTP to backend | `main.swift` L1036-2131 |
| `SaveDialogViewModel` + `SaveRecordingView` | Post-call "Opname opslaan?" panel (Opslaan / NNO / Niet opslaan) | `main.swift` L2133-2356 |
| `ManualProcessViewModel` + `ManualProcessView` | Process an existing file with playback (AVAudioPlayer) | `main.swift` L2358-2681 |
| App entry | `NSApplication.shared` + `AppDelegate` + `app.run()` | `main.swift` L2683-2689 |
| FastAPI app | Routes, origin/host guards, job tracker, pipeline, notifications | `main.py` L1-477 |
| Transcription | AssemblyAI upload + poll, diarized transcript | `services/transcription.py` |
| Summarizer | Gemini summary + action-item extraction with retries | `services/summarizer.py` |
| Salesforce | Lazy SF session, lookup/search, Task/Note creation, NNO, follow-up completion | `services/salesforce.py` |
| Config | Env var reads (`ASSEMBLYAI_API_KEY`, `GEMINI_API_KEY`, `GEMINI_MODEL`, `SF_*`) | `config.py` |

## Pattern Overview

- Client logic lives in one Swift file organized by `// MARK: -` sections. Some MARK markers are load-bearing (see Architectural Constraints).
- The app talks to the backend only over HTTP on `localhost:8765`; credentials pass via environment variables at spawn time, read from the Keychain (`main.swift` L615-623).
- Recording is delegated to a third-party app (Audio Hijack) controlled by writing JavaScript `.ahcommand` files and opening them with Audio Hijack. Call end is inferred by polling a folder plus a state file Audio Hijack writes back.
- Backend processing is fire-and-forget: `/process` returns immediately and runs `process_pipeline` as a FastAPI `BackgroundTasks` job; the app learns results only through `/status` when the menu opens, and through `osascript` notifications posted by the backend.
- All UI strings are Dutch.

## Layers

- Purpose: Menu-bar status item, menu, Settings window, save dialog, manual-process panel.
- Location: `CallBridge/CallBridge/main.swift` L971-1034 (SettingsView), L1263-1431 (status icon + menu), L1933-2009 (dialog windows), L2213-2681 (SwiftUI views).
- Contains: `NSStatusItem`, `NSMenu`, `NSPanel` + `NSHostingView`, SwiftUI `View` structs, `ObservableObject` view models.
- Depends on: `AppDelegate` methods (`searchContacts`, `sendToBackend`, `sendNNO`, `dialogFinished`, `dismissDialog`, `trashRecording`).
- Used by: User.
- Purpose: Receive `tel:` URLs, forward to Phone.app, drive Audio Hijack, detect call end, hand the file to the dialog.
- Location: `main.swift` L1546-1827.
- Depends on: Audio Hijack (`com.rogueamoeba.audiohijack`), Phone.app (`com.apple.mobilephone`) or FaceTime fallback, file system at `~/Auto Logger Recordings`.
- Used by: Apple Event `kAEGetURL` handler registered in `applicationWillFinishLaunching` (L1073-1086).
- Purpose: Backend process lifecycle, updates, Keychain, notifications.
- Location: `main.swift` L242-848.
- Depends on: Foundation `Process`, CryptoKit, Security framework, `/usr/bin/ditto`, `/usr/bin/osascript`, `/usr/sbin/lsof`.
- Used by: `AppDelegate`.
- Purpose: Local API for the app and dashboard.
- Location: `main.py` L55-336.
- Contains: `TrustedHostMiddleware` (L66), origin rejection middleware (L69-75), routes `/health` L163, `/validate-credentials` L176, `/status` L194, `/contact-search` L202, `/log-nno` L236, `/process` L275, `/process-manual` L314, static mount `/dashboard` L118.
- Depends on: `services/*`.
- Used by: `AppDelegate` (Swift) and `dashboard/index.html`.
- Purpose: Transcribe, summarize, extract actions, write to Salesforce.
- Location: `main.py` L339-447 (`process_pipeline`), `services/transcription.py`, `services/summarizer.py`, `services/salesforce.py`.
- Depends on: `requests`, `simple_salesforce`, `config.py`.

## Data Flow

### Primary Path: tel: click to Salesforce Task

### Restart Flow (new number while recording)

### Manual Processing Flow

### Backend Supervision Flow (`BackendSupervisor`, `main.swift` L521-848)

### Update Flow (`main.swift` L140-448, L1138-1146, L1415-1425, L1446-1458, L1475-1483)

- Swift: `AppDelegate.state: CallState` (L1046) plus `currentCallID: UUID?` (L1057) as the idempotency token for every async completion in the recording flow. Dialog state lives in `dialogWindow`/`dialogAudioPath` (L1048-1049) and separately `manualWindow`/`manualViewModel` (L1052-1053). `stabilityCheckInFlight` and `noFileCheckScheduled` (L1058-1059) throttle polling side-work. `lastStatus`/`serverReachable` (L1063-1064) cache backend status for the menu.
- Supervisor state is private and owned by its serial queue (L524-543).
- Python: module-level `_processing_jobs` dict and `_completed_jobs` deque (maxlen 3) under `_jobs_lock` (`main.py` L77-114), seeded at startup from Salesforce in a daemon thread (L121-160). Salesforce session cached in `services/salesforce.py` `_sf` with 30 min idle re-login.

## Key Abstractions

- Purpose: Drives the menu-bar icon (📞 / 🔴 / 💬 / ⏳, `updateStatusIcon` L1263-1276) and guards transitions.
- `.recording` carries `phoneNumber`, `startTime`, `existingFiles` (folder snapshot). Any replacement recorder must still produce an audio file path for `onRecordingComplete(phoneNumber:audioPath:)`.
- `.processing` is only entered from `.idle` (`beginBackendWork`, L2012-2018); a live recording wins over it.
- `startAudioHijack()` / `stopAudioHijack()` / `runAudioHijackScript(_:)` / `queryAudioHijackState()`.
- Mechanism: write JS (`app.sessionWithName("Voice Chat").start();`) to a unique `NSTemporaryDirectory()/callbridge_cmd_<UUID>.ahcommand`, open it with Audio Hijack (`activates = false`), delete after 60 s. State query makes Audio Hijack run `app.runShellCommand` to echo `{running, recordingCount}` into `NSTemporaryDirectory()/callbridge_ah_state.json` (`ahStatePath`, L1060).
- Session config: `audio-hijack/Voice Chat.ah4session` (binary plist; per `docs/beta/nno-autodetect.md` it records Phone.app, captures inputs, split channels, 128 kbps MP3; stereo L = local mic, R = remote).
- Callers: `beginRecording` (L1610), `handleURL` restart (L1583), `pollForCallEnd` timeout (L1730) and every tick (L1796), `finishRecording` (L1810).
- `recordingsDir = ~/Auto Logger Recordings` (L1043), created at launch (L1102).
- Readers: `snapshotRecordingsFolder` L1664, `findNewRecording` L1670, `listRecentRecordings` L1485, `showManualProcessDialog` default dir L1510, `checkForOrphanedRecordings` L2112-2130 (log-only stub).
- Audio extensions list is duplicated: `["mp3","wav","m4a","aiff","caf"]` at L1488 and L1673; `["mp3","wav","m4a","aiff"]` at L2115. MIME mapping at L1904-1910.
- Heuristic composed of: new file in folder, size stable over 2 s, and (Audio Hijack session reports stopped OR file mtime idle ≥ 5 s). 10 s grace after start for the state file. 2 h hard timeout. Completion always funnels through `finishRecording`.
- There is no signal from Phone.app; end of call is inferred purely from recorder output.
- The seam between "a call produced a file" and "ask the user what to do". `docs/beta/nno-autodetect.md` plans to insert an NNO classifier here (new file `CallBridge/CallBridge/NNODetector.swift`, Cocoa-free).
- Generation-numbered child-process supervisor on a private serial queue. Public API: `start()`, `reloadCredentials()`, `ensureRunning()`, `stop()`. Calls back into `AppDelegate` via `NSApp.delegate as? AppDelegate` to set `serverReachable` and `rebuildMenu()` (L699-716).
- Pure, Foundation-only; versions `MAJOR.MINOR.PATCH` with optional `-beta.N`, beta sorts below its final release. Tested by `tests/UpdateChannelTests.swift` via `scripts/test-update-channel.sh`.
- Shape returned by `/contact-search` (`id, name, type, phone, account_name, account_id`), `type` in `Contact | Account | Lead` (`ALLOWED_RECORD_TYPES`, `services/salesforce.py`).

## Entry Points

- Location: `CallBridge/CallBridge/main.swift` L2683-2689 (top-level code, no `@main`).
- Triggers: Login (`launchagents/com.welisa.callbridge.plist`), Finder, or a `tel:` URL (Info.plist `CFBundleURLTypes` → `tel`, `CallBridge/CallBridge/Info.plist`).
- Responsibilities: Single-instance check (L1073-1099), Edit menu (L1152-1163), claim default `tel:` handler only when installed in `/Applications` or `~/Applications` (L1170-1194), status item, credential gate, backend start, update timer.
- Location: `AppDelegate.handleURL` (`main.swift` L1548-1599), registered L1080-1085.
- Location: `main.py` L475-477 (`uvicorn.run(app, host="127.0.0.1", port=8765)`); frozen by `callbridge-server.spec` into `CallBridge.app/Contents/Resources/callbridge-server/`.
- Triggers: `BackendSupervisor.spawnLocked` (`main.swift` L593-667).
- `build-release.sh <version>`: rewrites `appVersion`/`appBuildChannel`, Info.plist, `swift build -c release`, PyInstaller, ad-hoc codesign, zip, `swift sign-update.swift`, writes `callbridge-update.json`.
- `.github/workflows/release.yml`: `workflow_dispatch`, stable only from `main`, `-beta.N` only from `beta`; publishes GitHub Release (beta as prerelease) including `audio-hijack/Voice Chat.ah4session`.
- `.github/workflows/build.yml`: on push to `beta` and PRs: `scripts/test-update-channel.sh` then `swift build -c release`.

## Architectural Constraints

- **Threading (Swift):** `AppDelegate` state is main-thread only; network completions hop back with `DispatchQueue.main.async`. Blocking work is pushed to global queues: Keychain reads (L1198), file stability check (L1757), multipart body build (L1879). `BackendSupervisor` serializes everything on its own queue and asserts with `dispatchPrecondition` (L594, L724). `stop()` blocks the main thread up to 3 s during quit (L747-748).
- **Threading (Python):** sync route handlers run in the FastAPI threadpool; `/log-nno` is sync on purpose so Salesforce calls do not block the event loop (`main.py` L245-247). `/process` and `/process-manual` are `async` only to read the upload, then schedule the sync pipeline as a background task.
- **Global state:** Swift globals `appVersion`, `appBuildChannel`, `updatePublicKey`, `debugLogPath` (L10-17), `app`/`delegate` (L2686-2687). Python: `_processing_jobs`, `_completed_jobs`, `_jobs_lock` (`main.py` L78-80); `_sf`, `_sf_last_used`, `_user_id` (`services/salesforce.py`).
- **Load-bearing text markers:** `build-release.sh` rewrites lines matching `^let appVersion = ".*"` and `^let appBuildChannel = ".*"`. `scripts/test-update-channel.sh` extracts the code between `// MARK: - Update Channel` and `// MARK: - Update Manifest` with `awk` and compiles it without Cocoa. Keep those two declarations at column 0 and keep everything between those markers Foundation-only.
- **Fixed port and paths:** backend `127.0.0.1:8765` (hard-coded in `AppDelegate.serverURL` L1040, supervisor health URL L827, `main.py` L61 and L477); recordings `~/Auto Logger Recordings`; logs `~/Library/Logs/CallBridge/{backend.log,call_logger.log}`; debug log `/tmp/callbridge_debug.log`.
- **Bundle layout:** executable must be at `Contents/Resources/callbridge-server/callbridge-server` (PyInstaller `--onedir`, `main.swift` L557-562).
- **Platform:** macOS 13+ (`CallBridge/Package.swift`, Info.plist `LSMinimumSystemVersion`), `LSUIElement = true`, not sandboxed, ad-hoc signed.
- **Circular imports:** None in Python (`main.py` → `services/*` → `config.py`). Swift view models hold `weak var appDelegate` and call back into it.

## Anti-Patterns

### God-object AppDelegate

### Duplicated helpers

### Inferring call end from recorder side effects

## Replacement Boundaries

### Recorder (Audio Hijack → native audio capture)

- **Code to replace:** `main.swift` L1619-1660 (Audio Hijack Control), L1662-1704 (Recording Detection), and the detection body of `pollForCallEnd` L1720-1797 plus `fileIdle` L1800-1803. Property `ahStatePath` (L1060), `audioHijackSessionName` (L1042), `stabilityCheckInFlight`/`noFileCheckScheduled` (L1058-1059).
- **Call sites that must switch to the new recorder:** `beginRecording` L1607 (delete state file) and L1610 (start), `handleURL` restart L1583 (stop), `pollForCallEnd` timeout L1730 (stop) and L1796 (state query), `finishRecording` L1810 (stop when `stopAH`).
- **Contract to keep:** the recorder must hand back one finished audio file path. Everything downstream starts at `finishRecording(callID:phoneNumber:audioPath:stopAH:)` (L1806-1812), which is idempotent per `currentCallID` and is the only transition out of `.recording`. `CallState.recording.existingFiles` (L854) exists only for folder diffing and can go once the recorder reports its own path.
- **File constraints:** write into `recordingsDir` (L1043) so "Recente opnames" (`listRecentRecordings` L1485-1497) and the manual window still find it; use an extension in the lists at L1488 and L1673 with a MIME case at L1904-1910. Stereo with L = local mic and R = remote keeps `docs/beta/nno-autodetect.md` valid.
- **Not part of the boundary:** `forwardCall` (L2096-2103) still opens Phone.app/FaceTime; the recorder does not place calls.

### Call trigger (tel: only → tel: + meeting detection)

- **Today:** one trigger, the `kAEGetURL` Apple Event → `handleURL` (L1548-1599) → `beginRecording(phoneNumber:callID:)` (L1604-1617). There is no call-start or call-end signal from Phone.app; the end is inferred from recorder output.
- **Seam for Google Meet / Slack huddles:** a detector calls a start entry equivalent to `beginRecording` (sets `currentCallID`, `state = .recording`, starts recorder) and, unlike tel:, can also emit an end event that should call `finishRecording` directly instead of waiting for polling.
- **Identity is phone-number-shaped:** `CallState.recording`/`.showingDialog` (L854-855), `onRecordingComplete(phoneNumber:audioPath:)` L1816, `lookupContact(phone:)` L1831, `SaveDialogViewModel.phoneNumber` L2136, `sendToBackend(... phoneNumber:)` L1874, and `/process` `phone_number: Form(...)` (`main.py` L279) all assume a number. A meeting source needs either an empty number (as `ManualProcessViewModel.process()` sends at L2485) or a generalized call-source field threaded through these points. `direction` is fixed at `"Outbound"` by default (L1874, `main.py` L280).
- **Concurrency rule:** only one `.recording` at a time; a new tel: while recording restarts the flow (L1578-1595). A meeting detector must follow the same rule or define precedence.

### Transcription (AssemblyAI → app.welisa.dev transcribe API)

- **Code to replace:** `services/transcription.py` (`transcribe_audio` L17, `_format_transcript` L110, `_format_time_ms` L140; constants L8-14).
- **Contract:** `transcribe_audio(file_path: str) -> dict` with keys `utterances`, `full_text` (speaker-labelled text fed to Gemini), `audio_duration` (seconds, written to the Task), `language_code`. Consumers: `process_pipeline` reads `result["full_text"]` (`main.py` L372) and `result["audio_duration"]` (L394). Empty `full_text` fails the job (L374-378).
- **Credential plumbing that names AssemblyAI:** `config.py` L4; `BackendSupervisor.spawnLocked` `credentialKeys` (`main.swift` L616-617); `runCredentialCheck` key list (L1204-1205); `showSettings` key list (L1439-1441); `SettingsViewModel` field/read/save (L877, L888, L960); `SettingsView` field (L978) and the "Opslaan" disable rule (L1019). A new key or token must be added at all of these, or the backend will not receive it and the credential gate will not pass.
- **Pipeline order is fixed** in `process_pipeline` (`main.py` L339-447): resolve record → transcribe → summarize → extract actions → `create_call_log` → `complete_due_followup_tasks` → `create_transcript_note` → action tasks → `_complete_job`; `finally` removes the temp file. Job steps reported to the menu are `starting`, `transcribing`, `summarizing`, `extracting_actions`, `saving_to_salesforce`; new step names also need a label in `ProcessingJob.stepLabel` (`main.swift` L80-89).

### Backend supervisor and updater (stable infrastructure)

- `BackendSupervisor` (L521-848) and `UpdateChecker` (L242-448) have no dependency on the recorder or trigger. They move to their own files unchanged; only the `NSApp.delegate as? AppDelegate` callback (L699-716) couples the supervisor to the app.
- `UpdateChannel`/`AppVersion`/`decideUpdate` (L140-231) must stay Foundation-only. If moved out of `main.swift`, update `scripts/test-update-channel.sh` (it `awk`s the MARK range from `main.swift`) in the same change.

## Error Handling

- Swift: `debugLog` / `NSLog` plus user-facing Dutch `osascript` notifications. `backendFailure` (L2046-2057) turns transport errors and non-2xx responses (including FastAPI `detail`) into a message; notifications append "opname bewaard".
- Recording files are only trashed after explicit discard or a successful NNO (L2086).
- `try?` is used widely for file operations; failures fall back to empty results.
- Python: `process_pipeline` wraps everything in one `try/except` (`main.py` L351-447), marks the job failed, notifies via `_notify_error`; summary failure is tolerated and the call is still logged with the transcript (L382-391); action-item failures are non-fatal. `HTTPException(400)` for invalid SF ids/types.

## Cross-Cutting Concerns

<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->

## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->

## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->

<!-- GSD:profile-start -->

## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
