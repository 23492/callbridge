# NNO auto-detection (beta)

Goal: when a call ends, CallBridge recognises a no-answer (NNO: niet opgenomen, voicemail, busy, unreachable) from the audio itself, before anything is uploaded. No AssemblyAI or Gemini call, no model download, no network. Runtime cost is a few hundred milliseconds of DSP on the Mac.

Ships on the `beta` channel first (see "Beta channel" in `CLAUDE.md`). Stable users see nothing until phase 6.

## Why the waveform is enough

The Audio Hijack session (`audio-hijack/Voice Chat.ah4session`) records Phone.app with `captureInputs = true` and `splitChannels = true`, to 128 kbps MP3. If that gives one channel per side (remote party, Kiran's mic), the two kinds of call look very different:

| Signal | Answered call | NNO |
|---|---|---|
| Ringback tone (425 Hz, or 440+480 Hz; see phase 1 results) | A few cycles, then stops | Runs until hang-up, or until voicemail picks up |
| Busy tone (425 Hz, 0.5 s / 0.5 s) | Never | Busy line |
| Remote speech after ringback | Short "met ..." then back-and-forth | A monologue (voicemail greeting or network message: "het nummer dat u belt...") |
| Turn-taking between channels | Many alternations | 0 or 1 alternations |
| Voicemail beep (narrow tone, roughly 0.8 to 1.5 kHz, 0.2 to 1.5 s) | Never | Right after the greeting |
| Kiran's channel | Speaks throughout | Silent, or one short message after the beep |
| Duration | Usually > 60 s | Usually < 45 s |

Every row is cheap to measure: Goertzel filters for the tones, an energy plus spectral-flatness voice activity detector per channel, and segment counting. Ringback cadence plus "no turn-taking" should already separate most cases. The other rows cover voicemail that picks up fast and network messages.

Phase 1 measured the stereo layout on real recordings: see "Phase 1 results" below.

## Where it runs

In the Swift app, between "recording finished" and "show save dialog" (`onRecordingComplete` in `main.swift`):

- `AVAudioFile` decodes the MP3 natively, downmixed per channel to 8 kHz Float.
- `Accelerate`/`vDSP` does the framing and filtering.
- The classifier lives in a new `CallBridge/CallBridge/NNODetector.swift`. It takes `[Float]` buffers and has no Cocoa or AVFoundation import, so it compiles and tests on Linux CI, like the update-channel tests do.

The Python backend is not a good fit: the PyInstaller spec excludes numpy, and decoding MP3 there would mean bundling ffmpeg.

The classifier is hand-set thresholds, or at most a logistic regression whose handful of weights are hard-coded constants. No ML runtime.

## Cost of mistakes

A false NNO on a real conversation loses a call log and transcript. A missed NNO costs one click. The targets reflect that:

- Suggest mode: precision ≥ 95%, recall ≥ 70%.
- Auto mode: precision ≥ 99% on the calibration set, only above a high-confidence cut-off. The recording is kept for 7 days instead of being trashed, so a wrong auto-NNO can still be processed via "Recente opnames".

## Phases

Each phase ends with something working on the `beta` branch. Versions are `2.1.0-beta.N`.

### Phase 0: beta channel (done)

- `beta` branch, `UpdateChannel` (stable/beta) with its own manifest per branch.
- Settings → Updates → "Bètaversies ontvangen" toggle; menu shows "· bèta" and "↩ Terug naar stabiel vX".
- `build-release.sh` and the Release workflow accept `X.Y.Z-beta.N` (GitHub pre-release, only from `beta`).
- `scripts/test-update-channel.sh`: 32 assertions on version ordering and channel rules; `build.yml` compiles the app on macOS for every push to `beta`.

### Phase 1: corpus and channel check

Offline only, nothing ships to users.

- Verify the stereo layout on 3 known recordings (one answered, one voicemail, one unanswered) and record the channel mapping in this file.
- Build a labelled corpus from what is already on Kiran's Mac. Saved calls stay in `~/Auto Logger Recordings`. NNO recordings were moved to the Trash by the NNO button. Labels come from matching file timestamps (`Telefoongesprek %date %time`) to Salesforce Tasks: `Subject = 'NNO'` versus `Log_Type__c = 'Sales Call'` (read-only SOQL).
- `scripts/nno-analyze`: dumps per-recording features to CSV, so thresholds come from data instead of guesses.

Done when: at least 50 labelled NNO and 50 answered recordings, plus a CSV of features.

#### Phase 1 results (2026-10-01, first 22 recordings)

Recordings from 2026-09-24 to 2026-10-01, labelled against Kiran's Salesforce Tasks by start time and duration (read-only SOQL). The two long calls match `CallDurationInSeconds` exactly (776 s, 703 s).

Channel layout of the `Telefoongesprek` files: stereo, left = Kiran's microphone, right = Phone.app output (the other side, including all network tones). The channels are uncorrelated (r ≈ 0.0). The two `Voice Chat 20261001` files are a mono mix (r = 1.00) from a differently configured session, so the detector needs a mono fallback.

Tones seen on the right channel:

| Tone | Where it comes from | Files |
|---|---|---|
| 440 + 480 Hz, 2 s on / 4 s off | Ringback generated on the Apple side (US-style cadence) | most NNOs |
| 425 Hz, 1 s on / 4 s off | Dutch network ringback | 4 files |
| 950 / 1400 / 1800 Hz | SIT tone: number not in service | 1 file |

So the detector must recognise both ringback families; 425 Hz alone would have missed most NNOs.

The deciding feature is Kiran's own channel. In every NNO it is silent (< 1.5 s of speech), except when he leaves a voicemail: then a long remote greeting comes first, followed by one or two short stretches of his own speech. Real conversations have ≥ 10 s of own speech in 4 or more stretches.

Prototype rule (`docs/beta/nno-prototype.js`), in order:

1. SIT tone → NNO
2. mono recording → conversation if > 90 s, otherwise unsure
3. own speech ≥ 10 s or ≥ 4 stretches → conversation
4. own speech < 1.5 s → NNO
5. ≤ 2 own stretches after ≥ 8 s remote speech → NNO (voicemail left)
6. otherwise unsure

Result:

| | Salesforce says NNO | Salesforce says call | No matching Task |
|---|---|---|---|
| Detector: NNO | 14 | 0 | 4 |
| Detector: conversation | 0 | 2 | 3 |
| Detector: unsure | 0 | 0 | 0 |

16 of 16 labelled recordings correct, no false NNO. The set is far too small for the precision targets, and mono recordings can only be judged on duration. Next: more recordings, especially short answered calls ("bel je later terug") and mono files.

### Phase 2: detector core

- `NNODetector.swift`: features (duration, ringback seconds and cadence match, busy cadence, beep found, remote monologue length, turn count, local speech seconds) and `classify() -> (verdict, confidence, reason)`.
- Unit tests on synthetic signals (generated 425 Hz cadences, beep, noise bursts as "speech"), run in CI on Linux and macOS.
- Corpus evaluation from phase 1, reporting precision and recall per NNO type.

Done when: the targets above are met on the corpus, and a mutation check shows the tests catch a broken threshold.

### Phase 3: shadow mode (`2.1.0-beta.1`)

- The detector runs on every call. The UI does not change.
- After the user picks Opslaan / NNO / Niet opslaan, the app appends one line to `~/Library/Application Support/CallBridge/nno-shadow.jsonl`: features, verdict, user choice. No audio and no phone numbers.
- Menu item "NNO-detectie statistiek" shows agreement so far.

Done when: about 2 weeks of real calls are logged and the agreement rate is known.

### Phase 4: suggest mode (`2.1.0-beta.2`)

- New Settings section "NNO-detectie": Uit / Voorstellen / Automatisch (Automatisch disabled until phase 5).
- In Voorstellen, the save dialog highlights NNO and shows the reason, for example "Waarschijnlijk geen gehoor: 32 s kiestoon, voicemail-piep, geen gesprek". The user still clicks.
- If the user picks Opslaan on a detected NNO, there is no block, only the shadow log entry.

Done when: precision in the shadow log ≥ 95% over at least 100 calls.

### Phase 5: auto mode (`2.1.0-beta.3`)

- Above the high-confidence cut-off, CallBridge logs the NNO itself and posts a notification with an "Ongedaan maken" action. Undo deletes the two Salesforce Tasks and reopens the save dialog.
- The recording is kept for 7 days.
- Any Salesforce write test needs Kiran's manual approval (production org gate).

Done when: zero false auto-NNOs over 2 weeks of Kiran's own calls.

### Phase 6: promote to stable (`2.1.0`)

- Merge `beta` into `main`, release `2.1.0` from `main`. Detection default for stable users is Voorstellen. Automatisch stays opt-in.
- Beta users get `2.1.0` automatically (a final release overtakes its betas).

## Open questions

1. Stereo layout: answered in phase 1 (left = Kiran, right = other side). Why are the `Voice Chat` files mono? Probably a session that was set up separately from the shipped template.
2. Do Welisa colleagues call abroad? The 440+480 Hz tone already shows up for Dutch numbers. Other tones (UK 400+450 Hz) are cheap to add, but need examples.
3. When the voicemail picks up and Kiran leaves a message, is that still an NNO? The current NNO flow suggests yes.
