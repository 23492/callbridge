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
- `com.autologger.server.plist` — launches uvicorn (KeepAlive: true), logs to `logs/`

Reload after changes:
```bash
launchctl unload ~/Library/LaunchAgents/com.welisa.callbridge.plist
launchctl load ~/Library/LaunchAgents/com.welisa.callbridge.plist
```

## Config

- `.env` — API keys and Salesforce credentials (gitignored)
- `config.py` — reads env vars
- Audio Hijack session name: "Voice Chat"
- Recordings dir: `~/Auto Logger Recordings`
