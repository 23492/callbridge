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

**CallBridge — v2.0 Distributable**

CallBridge is a macOS menu-bar app that intercepts `tel://` URLs, records calls via Audio Hijack, transcribes them with AssemblyAI, summarises them with Gemini, and logs everything (call task, transcript, action items) to the Salesforce production org. The current repo (v1.1.0) is coach-free and fully functional on the developer's machine. This project is the effort to turn that dev-machine-bound setup into a **proper, signed, distributable macOS app** that Kiran and Welisa colleagues can install on a clean Mac without the manual conda / launchd / `.env` dance.

**Core Value:** Any Welisa colleague on the same Salesforce org can install CallBridge on a clean Mac in under 15 minutes and have a working call-logging pipeline — no terminal required.

### Constraints

- **Tech stack:** Swift (macOS app) + Python 3.x (FastAPI backend) — no language change
- **Target OS:** macOS 13.0+ (current LSMinimumSystemVersion)
- **Salesforce:** welisa domain, production org — same org for all Welisa users
- **Audio:** Audio Hijack is a prerequisite (Option A default) — end-user must have it installed
- **Apple Developer ID:** Required for signing + notarisation — $99/yr, must be set up before Phase 5
- **SF prod write gate:** Any end-to-end test that writes to the production Salesforce org requires a manual approval gate, even in yolo mode

<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->

## Technology Stack

## Languages

- Swift (macOS app) - CallBridge desktop application for tel:// URL interception and call recording
- Python 3.13 - Backend API and services for audio transcription, summarization, and Salesforce integration
- JavaScript/HTML - Dashboard UI for manual call log uploads
- Shell (Bash) - Build and deployment scripts
- XML (Plist format) - macOS app configuration and LaunchAgent definitions

## Runtime

- macOS 13.0+ (specified in `CallBridge/CallBridge/Info.plist` LSMinimumSystemVersion)
- Python 3.13 via conda: `/opt/homebrew/Caskroom/miniconda/base/bin/python3.13`
- pip (Python dependency management)
- Lockfile: `.planning/codebase/requirements.txt` present (frozen versions)
- Swift: standard library + Apple frameworks (Cocoa, SwiftUI, Foundation, CryptoKit, AVFoundation)

## Frameworks

- FastAPI 0.115.0 - Backend REST API framework for audio processing endpoints
- uvicorn 0.30.6 - ASGI application server (runs on port 8765)
- simple-salesforce 1.12.6 - Salesforce API client library for OAuth authentication and SOSL/SOQL queries
- requests 2.32.3 - HTTP library for AssemblyAI and Google Gemini API calls
- python-dotenv 1.0.1 - Environment variable loading from `.env`
- swiftc - Swift compiler (system standard)
- PlistBuddy - macOS utility for Info.plist version updates

## Key Dependencies

- simple-salesforce 1.12.6 - Core integration with Salesforce org; handles authentication, Contact/Account/Lead search, Task creation, ContentNote linking. See `services/salesforce.py`
- fastapi 0.115.0 - Serves `/process`, `/log-nno`, `/contact-search`, `/process-manual` endpoints for CallBridge and dashboard
- CryptoKit (Swift) - Ed25519 signature verification for auto-updater checksums
- AVFoundation (Swift) - Audio playback for call recording notifications

## Configuration

- `.env` file (gitignored) - Must contain:
- `.env.example` provided as reference template at project root
- `CallBridge/CallBridge/Info.plist` - macOS bundle metadata (CFBundleVersion, CFBundleIdentifier, URL schemes)
- `callbridge-update.json` - Auto-updater manifest with version, GitHub release URL, and Ed25519 signature
- `build-release.sh` - Automated build, sign, and release script

## Platform Requirements

- macOS 13.0 or later
- Swift compiler (Xcode Command Line Tools or Swift installed)
- Python 3.13 with conda/pip
- Audio Hijack (third-party app for audio recording; session name: "Voice Chat")
- macOS 13.0 or later
- Salesforce org (welisa domain, production environment)
- Internet connectivity for external API calls
- Deployment: `/Applications/CallBridge.app` (installed via build and deploy script)
- LaunchAgents for auto-start:

## External API Dependencies

- AssemblyAI v2 API (`https://api.assemblyai.com/v2`) - Speaker diarization, language detection, transcript polling
- Requires: `ASSEMBLYAI_API_KEY` env var
- Google Gemini API (`https://generativelanguage.googleapis.com/v1beta/models/`) - Call summary generation with thinking mode and action item extraction
- Model: `gemini-3-flash-preview` (configured in `config.py`)
- Requires: `GEMINI_API_KEY` env var
- Salesforce OAuth2 (login.salesforce.com) - Contact/Account/Lead search via SOSL, Task/ContentNote creation
- Requires: username, password, security token (env vars)
- Domain: `welisa` (production org)
- GitHub Releases API - Fetches manifest from `https://raw.githubusercontent.com/23492/callbridge/main/callbridge-update.json`
- Check frequency: every 60 minutes (from running CallBridge instances)

## Logging & Observability

- Python logging to file: `call_logger.log` (structured with timestamp, level, module)
- Console output (dual logging to file + stderr)
- CallBridge debug log: `/tmp/callbridge_debug.log` (ISO8601 timestamped entries)
- macOS system notifications via `osascript` (success/error alerts)

<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->

## Conventions

## Naming Patterns

- Python modules: lowercase with underscores (e.g., `transcription.py`, `summarizer.py`, `salesforce.py`)
- Swift files: PascalCase (e.g., `main.swift`)
- Test files: Not present in codebase (see TESTING.md)
- Python: snake_case throughout (e.g., `find_contact_by_phone()`, `create_call_log()`, `transcribe_audio()`)
- Swift: camelCase for methods (e.g., `fetchStatus()`, `rebuildMenu()`, `isFileSizeStable()`)
- Prefix private/internal functions with underscore in Python (e.g., `_sanitize_phone()`, `_normalize_record()`, `_get_sf()`, `_fetch_future_tasks()`)
- Python: snake_case for all local and module variables (e.g., `phone_number`, `audio_path`, `contact_name`)
- Swift: camelCase for properties and local variables (e.g., `phoneNumber`, `audioPath`, `statusItem`, `recordingsDir`)
- Module-level singletons prefixed with underscore in Python: `_sf` (Salesforce connection), `_jobs_lock`, `_processing_jobs`, `_completed_jobs`
- Python: Classes/dataclasses use PascalCase (none used, primarily function-based); type hints use native Python types (e.g., `dict[str, dict]`, `str | None`)
- Swift: Structs and Classes use PascalCase (e.g., `ContactInfo`, `ProcessingJob`, `SaveDialogViewModel`, `UpdateChecker`)
- Swift enums: PascalCase for enum name, lowercase for cases (e.g., `enum CallState { case idle, recording(...), showingDialog(...), processing }`)

## Code Style

- No explicit formatter configured (no `.prettierrc`, `biome.json`, or formatter config found)
- Python follows implicit PEP 8-like style: 4-space indentation, blank lines between functions
- Swift uses 4-space indentation, multiline formatting for readability
- Line continuations use natural Swift/Python syntax
- No linting config files detected (no `.eslintrc`, `setup.cfg`, `pyproject.toml`)
- Code style is self-enforced through conventions
- Function docstrings present in Python (e.g., `transcribe_audio()` at `services/transcription.py:11`)
- Logging statements consistent: `logger.info()`, `logger.warning()`, `logger.error()`
- No type hints on function signatures in Python (optional/not enforced)
- Swift uses MARK comments to organize code sections (e.g., `// MARK: - Version & Update Config`, `// MARK: - App Delegate`)

## Import Organization

- Standard library imports first (e.g., `import logging`, `import os`, `import tempfile`, `import threading`, `import uuid`)
- Third-party imports next (e.g., `from fastapi import ...`, `from simple_salesforce import Salesforce`)
- Local imports last (e.g., `from services.transcription import transcribe_audio`)
- Order in `main.py` follows this pattern (lines 1-21)
- Framework imports at top (e.g., `import Cocoa`, `import SwiftUI`, `import Foundation`, `import CryptoKit`, `import AVFoundation`)
- All imports grouped at file start before any code
- Python uses relative imports within package: `from services.transcription import ...`
- Swift uses direct imports with no aliases

## Error Handling

- Try-except with specific exception handling in critical paths (e.g., `services/salesforce.py` line 83: `except Exception as e: logger.warning(...)`)
- Silent failures on non-critical operations: `except Exception: pass` (e.g., `main.py` line 388, 397)
- Fallback returns for errors: `_notify_error()` sends system notifications on failure
- Raw exception strings logged and returned to caller (e.g., `main.py` line 378: `_notify_error(str(e))`)
- HTTP status code checking before raising: `response.raise_for_status()` in `services/transcription.py` and `services/summarizer.py`
- Retry logic with exponential backoff for Gemini API (lines 207-220 in `summarizer.py`): `wait = 2 ** attempt * 5` (5s, 10s, 20s, 40s)
- Guard statements for optional unwrapping (e.g., `main.swift:149`, `main.swift:183`)
- Try-catch for file operations: `try? FileManager.default.removeItem(atPath: audioPath)`
- Weak self captures in closures to prevent retain cycles (e.g., `[weak self] in`)
- Silent return on error: `guard let data = data, error == nil else { ... }`
- Logging with `NSLog()` for app-level events and `debugLog()` for detailed troubleshooting

## Logging

- Python: `logging` module with named loggers: `logger = logging.getLogger(__name__)`
- Swift: `NSLog()` for system log, `debugLog()` custom function for file-based debug trace
- `logger.info()`: Normal flow events (e.g., "Connected to Salesforce", "Created Task", "Extracted N action items")
- `logger.warning()`: Expected failure modes (e.g., "Failed to fetch future tasks", "Empty transcript")
- `logger.error(..., exc_info=True)`: Unexpected errors with full traceback
- `NSLog()`: Major events and errors (e.g., call started, recording complete, backend errors)
- `debugLog()`: Detailed trace for debugging (written to `/tmp/callbridge_debug.log`, lines 17-28)
- Log format: `[ISO8601 timestamp] message` with file appending
- Set up in `main.py` lines 24-31:

## Comments

- Brief explanations of non-obvious logic (e.g., `services/salesforce.py:45` — "Strip leading + for SOSL (causes bind variable error)")
- Constraints or gotchas (e.g., `main.py:154` — "find_contact_by_phone returns raw or semi-normalized records")
- Workflow descriptions at function start (e.g., `services/transcription.py:12-19`)
- Python uses basic docstrings with explanation (not extensive)
- Example: `services/transcription.py:11-19` shows function purpose and return dict structure
- Example: `services/salesforce.py:33-36` describes return type and search order
- No parameter-by-parameter documentation found
- Extensive use of `// MARK: - Section Name` for code organization (see `main.swift`)
- Sections: Version Config, Debug Logging, Data Models, Status Models, Update Manifest, Update Checker, Call State Machine, App Delegate, etc.

## Function Design

- Python functions: 15-50 lines typical (e.g., `_normalize_record()` is 19 lines, `create_call_log()` is 46 lines)
- Larger functions broken into logical steps with comments: `process_pipeline()` in `main.py` is 98 lines with 9 numbered steps
- Swift methods: 5-40 lines typical for single responsibility, longer for UI setup
- Python: Explicit named parameters (e.g., `contact: dict`, `summary: str`, `duration_seconds: int`)
- Optional parameters use type unions: `follow_up_date: str | None = None`
- Swift: Explicit naming with defaults (e.g., `timeoutInterval = 10`, `cachePolicy = .reloadIgnoringLocalCacheData`)
- Python: Explicit returns with None for failures (e.g., `find_contact_by_phone()` returns `dict | None`)
- Multiple returns via tuple: `create_nno_log()` returns `tuple[str, str]` (nno_task_id, follow_up_task_id)
- Dictionary returns for complex data: `transcribe_audio()` returns dict with `utterances`, `full_text`, `audio_duration`, `language_code`
- Swift: Optional unwrapping pattern throughout (e.g., `URL(string: ...)`, `try? JSONDecoder().decode(...)`)

## Module Design

- `services/salesforce.py` exports: `find_contact_by_phone()`, `search_contacts()`, `create_call_log()`, `create_transcript_note()`, `create_action_task()`, `create_nno_log()`
- Private helpers with underscore: `_get_sf()`, `_sanitize_phone()`, `_normalize_record()`, `_fetch_future_tasks()`
- `main.py` exports FastAPI routes: `/health`, `/status`, `/contact-search`, `/process`, `/process-manual`, `/log-nno`
- `services/transcription.py` exports: `transcribe_audio()` (private helper `_format_transcript()`, `_format_time_ms()`)
- `services/summarizer.py` exports: `generate_summary()`, `extract_action_items()` (private prompts in module constants)
- `services/__init__.py` is empty (no re-exports)
- Imports in `main.py` use explicit module imports: `from services.transcription import transcribe_audio`
- Salesforce connection singleton in `services/salesforce.py`: `_sf = None`, lazily initialized via `_get_sf()`
- Job tracking in `main.py`: `_processing_jobs`, `_completed_jobs`, `_jobs_lock` (thread-safe with threading.Lock)
- Configuration centralized in `config.py` (environment variables only)

## Language-Specific Conventions

- No dataclasses or Pydantic models (plain dicts used throughout)
- FastAPI endpoints decorated with `@app.get()`, `@app.post()`, `@app.on_event()`
- Query parameters via `Query()`, form data via `Form()`, file uploads via `File()`
- Background tasks: `background_tasks.add_task(process_pipeline, ...)`
- Structs with `Codable` for JSON serialization: `ContactInfo`, `ProcessingJob`, `StatusResponse`
- ViewModels as `ObservableObject` with `@Published` properties
- SwiftUI Views with `@ObservedObject` for binding
- MARK-based organization for 1500-line single file (no separate view files)
- Process execution via `Process()` for shell commands

<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->

## Architecture

## System Overview

```text

```

## Component Responsibilities

| Component | Responsibility | File |
|-----------|----------------|------|
| CallBridge App | Intercept tel:// URLs, control Audio Hijack recording, detect call end, present save/NNO dialog, poll backend, manage auto-updates | `CallBridge/CallBridge/main.swift` |
| FastAPI Server | HTTP endpoint dispatcher, job state tracking, background task orchestration, dashboard static file serving | `main.py` |
| Transcription Service | Upload audio to AssemblyAI, poll for completion, format transcript with speaker labels | `services/transcription.py` |
| Summarizer Service | Call Google Gemini to generate call summary and extract action items | `services/summarizer.py` |
| Salesforce Integration | Query Contact/Account/Lead, create Task (call log), ContentNote (transcript), action Tasks, handle NNO flow | `services/salesforce.py` |

## Pattern Overview

- **Swift frontend**: Native macOS app runs as menu bar agent, no persistent UI
- **Python backend**: FastAPI server runs continuously on localhost:8765
- **Background jobs**: Async pipeline for transcription → summarization → Salesforce logging
- **State-driven**: CallBridge uses enum-based state machine (idle/recording/showingDialog/processing)
- **Real-time polling**: Swift app polls `/status` every 5 seconds to show processing progress and completed calls
- **Lazy Salesforce connection**: Single module-level `_sf` instance reused across requests

## Layers

- Purpose: Capture call phone number, detect recording completion, show save/NNO decision dialogs, display processing status and recent calls
- Location: `CallBridge/CallBridge/main.swift`
- Contains: SwiftUI views (SaveRecordingView, ManualProcessView), AppDelegate with state machine, URL event handler, Audio Hijack control, update checker
- Depends on: FastAPI backend at `http://localhost:8765`, Audio Hijack (com.rogueamoeba.audiohijack), Salesforce Lightning URLs
- Used by: User's macOS system
- Purpose: Accept audio uploads, dispatch to async processing pipeline, provide contact search, track job status
- Location: `main.py`
- Contains: FastAPI route handlers (`/process`, `/process-manual`, `/log-nno`, `/contact-search`, `/status`, `/health`), job tracking using thread-safe dict + deque, request validation
- Depends on: Services (transcription, summarizer, salesforce)
- Used by: CallBridge macOS app, dashboard UI
- Purpose: Transcribe audio → summarize → extract actions → create Salesforce records → clean up temp files
- Location: `main.py::process_pipeline()` function
- Contains: Orchestration logic, step progress tracking via `_update_job()`, error handling and notification
- Depends on: Transcription, Summarizer, Salesforce services; temporary file system
- Used by: FastAPI background task executor
- Purpose: Encapsulate external API integrations and Salesforce domain logic
- Location: `services/transcription.py`, `services/summarizer.py`, `services/salesforce.py`
- Contains: Transcription (AssemblyAI polling), summarization (Gemini prompting), Salesforce SOSL/SOQL queries and record creation
- Depends on: External APIs (AssemblyAI, Gemini, Salesforce), config environment variables
- Used by: Processing pipeline and FastAPI endpoints
- Purpose: Read environment variables and provide constants
- Location: `config.py`
- Contains: API keys (ASSEMBLYAI_API_KEY, GEMINI_API_KEY), Salesforce credentials, model selection
- Depends on: `.env` file (gitignored)
- Used by: All services and main.py

## Data Flow

### Primary Request Path (Audio Upload → Salesforce Task)

### NNO (Niet Opgenomen / No Answer) Flow

- **AppDelegate.state**: Enum-based (idle, recording, showingDialog, processing) to prevent concurrent calls
- **_processing_jobs dict**: Thread-safe (protected by _jobs_lock), keyed by job_id, tracks step for each upload
- **_completed_jobs deque**: Most recent 3 completed jobs, shown in menu bar
- **Salesforce connection**: Module-level singleton _sf in services/salesforce.py, initialized on first access

## Key Abstractions

- Purpose: Enforce single-call-at-a-time and track user's progress through recording/save dialog
- Examples: `.idle`, `.recording(phoneNumber, startTime, existingFiles)`, `.showingDialog(phoneNumber, audioPath)`, `.processing`
- Pattern: Exhaustive switch in pollForCallEnd(), state transitions gated by guard statements
- Purpose: SwiftUI @ObservedObject to separate UI logic from AppDelegate state machine
- Pattern: Delegate to AppDelegate for network calls (searchContacts, sendToBackend), store UI state locally (selectedContact, isSearching)
- Purpose: Decompose recording upload into discrete, observable steps (transcribing → summarizing → extracting_actions → saving_to_salesforce)
- Pattern: _start_job → _update_job (multiple times) → _complete_job or _fail_job
- Benefit: Allows real-time UI updates showing "Transcribing..." → "Summarizing..." etc.
- Purpose: Unify Contact/Account/Lead into single SearchResponse format
- Examples: `_normalize_record()` in salesforce.py, SearchResponse struct in Swift
- Pattern: Type-specific field extraction (Account.Name → account_name, Contact.AccountId → account_id)

## Entry Points

- Location: `main.swift:603` (`AppDelegate.handleURL()`)
- Triggers: macOS system forwards tel:// URL to CallBridge (registered via LaunchAgent or URL scheme)
- Responsibilities: Validate not already recording, snapshot folder, start Audio Hijack, forward to Phone/FaceTime, set state to recording, start polling
- Location: `main.py:34` (app = FastAPI(...))
- Triggers: `uvicorn main:app --host localhost --port 8765` (via LaunchAgent com.welisa.callbridge-server.plist)
- Responsibilities: Mount dashboard static files, define routes, seed recent calls from Salesforce
- Location: `main.swift:562` (`showManualProcessDialog()`)
- Triggers: User selects "Kies bestand..." in menu or "Handmatig Verwerken"
- Responsibilities: Open NSOpenPanel, call showManualProcessWindow(audioPath), present ManualProcessView
- Location: `dashboard/index.html`, served from `/dashboard` route
- Triggers: User navigates to `http://localhost:8765/dashboard` in browser
- Responsibilities: File upload form, contact search, phone number input, manual processing

## Architectural Constraints

- **Threading:** Swift app runs on main thread for UI, uses DispatchQueue for background polling and file size checks. Python backend uses FastAPI's async event loop + sync background_tasks.
- **Global state:** 
- **Circular imports:** None detected. Config.py is leaf (no imports of other local modules). Services import config. main.py imports services.
- **Sync/Async boundary:** FastAPI handlers are sync (use requests library for external APIs). Background tasks are sync (process_pipeline is not async). This simplifies Salesforce polling and AssemblyAI upload but could block if many jobs run concurrently — currently single-threaded background executor.
- **File system dependency:** Recordings folder at `~/Auto Logger Recordings` must exist and be writable. Temp files created in `/tmp/` via tempfile.mkstemp(). No cleanup on server crash — manual intervention needed for orphaned /tmp files.
- **Audio Hijack scripting:** AppDelegate communicates via .ahcommand files written to /tmp, executed by Audio Hijack. No error handling if Audio Hijack is unresponsive or script is malformed.

## Anti-Patterns

### Module-Level Singleton Without Refresh

```python

```

### Threading Lock Misuse in Job Tracking

### Synchronous Processing Pipeline in FastAPI

## Error Handling

- **AssemblyAI/Gemini failures:** Exponential backoff with max 5 retries (see summarizer.py lines 209-220, 294-305)
- **Salesforce record not found:** Return 400 or log warning, skip record creation gracefully
- **Transcription empty:** Fail job, show error notification "Leeg transcript voor [contact]"
- **Contact lookup fails:** Show orange warning in dialog "Geen Salesforce record gevonden", allow save without selection
- **Audio file missing:** isFileSizeStable() returns false, wait 5 seconds, log warning if still missing
- **Backend unreachable:** Swift sets serverReachable = false, shows "Server niet bereikbaar" in menu, allows manual update check
- **Update signature invalid:** Skip update, show notification "Update handtekening ongeldig"

## Cross-Cutting Concerns

- Swift: debugLog() writes to `/tmp/callbridge_debug.log` with ISO8601 timestamps
- Python: logging.basicConfig() writes to `call_logger.log` and stderr with formatted timestamps
- Pattern: Log key transitions (recording start, transcription complete, Salesforce create success) at INFO; detailed variable state at DEBUG (not configured in this codebase)
- Phone number: Sanitized via _sanitize_phone() (strip non-digits and leading +)
- Contact search: Minimum 2 characters for SOSL
- Action items: JSON parsing with validation of required fields (description, due_date, is_follow_up_call)
- Audio file: Must have stable size for 2+ seconds before proceeding
- Salesforce: OAuth via simple_salesforce library using username/password/security_token stored in `.env` (production org domain "welisa")
- AssemblyAI: Bearer token in Authorization header
- Gemini: API key in x-goog-api-key header
- No authentication on CallBridge macOS app itself (assumes local-only access to localhost:8765)

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
