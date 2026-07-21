# Signing, notarization & DMG distribution

This is the one-time setup that turns a CallBridge build into something a
colleague can install on a clean Mac by **double-clicking a `.dmg` and dragging
the app to Applications** — no terminal, no Gatekeeper right-click dance.

Two independent signing systems are in play; don't confuse them:

| Signature | Purpose | Key/secret |
|-----------|---------|------------|
| **EdDSA (Ed25519)** | Proves an *auto-update* zip came from us. Verified in-app by `UpdateChecker`. | `SIGNING_PRIVATE_KEY` (already set up) |
| **Apple Developer ID + notarization** | Proves the *app itself* is from an identified developer, so macOS runs it without warnings. | Everything on this page |

The build already works **without** the Apple secrets — it falls back to ad-hoc
signing and an unsigned DMG (fine for the dev Mac, but a fresh Mac still shows a
Gatekeeper warning). Add the secrets below to get a clean, notarized install.

---

## What you need from Apple (once)

1. **An Apple Developer Program membership** ($99/yr) for the Welisa team.
2. A **Developer ID Application** certificate:
   - Xcode → Settings → Accounts → your team → **Manage Certificates** → **+** →
     *Developer ID Application*. (Or create it on
     <https://developer.apple.com/account/resources/certificates>.)
   - The identity name looks like
     `Developer ID Application: Welisa B.V. (TEAMID1234)`. The 10-character code
     in parentheses is your **Team ID**.
3. An **App Store Connect API key** for notarization (preferred over an Apple ID
   password because it never expires on password change):
   - <https://appstoreconnect.apple.com/access/integrations/api> → **+** →
     role *Developer*. Download the `.p8` **once** (you can't re-download it).
   - Note the **Key ID** and, at the top of that page, the **Issuer ID**.

---

## Building a distributable release locally

Export the cert into your login keychain (double-click the `.p12`/from Xcode),
then:

```bash
export DEVELOPER_ID_APP="Developer ID Application: Welisa B.V. (TEAMID1234)"

# Notarization — App Store Connect API key (preferred):
export AC_API_KEY_ID="XXXXXXXXXX"
export AC_API_ISSUER_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
export AC_API_KEY_PATH="$HOME/keys/AuthKey_XXXXXXXXXX.p8"
#   …or Apple ID fallback:
# export AC_APPLE_ID="you@welisa.nl"
# export AC_TEAM_ID="TEAMID1234"
# export AC_PASSWORD="app-specific-password"   # appleid.apple.com → App-Specific Passwords

./build-release.sh 2.1.0
```

The script will:

1. Build the Swift app + the embedded PyInstaller backend.
2. **Deep-sign** every nested Mach-O (the backend and its dylibs/`.so`) and the
   app with your Developer ID, the hardened runtime, and
   `CallBridge/entitlements.plist` (`scripts/codesign-app.sh`).
3. Zip the app, **notarize** it (`xcrun notarytool submit --wait`), and
   **staple** the ticket onto the `.app`.
4. Re-zip the stapled app as `CallBridge.app.zip` (the auto-update payload) and
   EdDSA-sign it.
5. Build `CallBridge-<version>.dmg` (`build-dmg.sh`), notarize and staple it too.

Verify the result:

```bash
spctl --assess --type execute -vv CallBridge/CallBridge.app   # → accepted, Notarized Developer ID
xcrun stapler validate CallBridge-2.1.0.dmg                   # → The validate action worked!
```

Without the Apple env vars set, the same command still succeeds but produces an
ad-hoc, un-notarized build (the script says so in its summary).

---

## Building via GitHub Actions

The **Release** workflow (`.github/workflows/release.yml`,
`workflow_dispatch` → enter a version) does all of the above on a `macos-latest`
runner and attaches both the `.dmg` and the auto-update `.zip` to the GitHub
Release. Add these **repository secrets** (Settings → Secrets and variables →
Actions). All are optional — omit them for an ad-hoc build.

| Secret | How to produce it |
|--------|-------------------|
| `DEVELOPER_ID_APP` | The identity string, e.g. `Developer ID Application: Welisa B.V. (TEAMID1234)` |
| `DEVELOPER_ID_CERT_P12` | Export the cert **with its private key** from Keychain Access as `.p12`, then `base64 -i cert.p12 \| pbcopy` |
| `DEVELOPER_ID_CERT_PW` | The password you set when exporting the `.p12` |
| `AC_API_KEY_P8` | `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
| `AC_API_KEY_ID` | App Store Connect Key ID |
| `AC_API_ISSUER_ID` | App Store Connect Issuer ID |
| `SIGNING_PRIVATE_KEY` | *(already set)* Ed25519 auto-update key |

The workflow imports the cert into a throwaway keychain, decodes the `.p8`, runs
`build-release.sh`, publishes the release, and wipes both from the runner.

---

## Why these entitlements?

The embedded backend is a PyInstaller bundle: a Python interpreter plus many
signed-separately C-extension dylibs. Under the hardened runtime that
notarization requires, loading them needs
`com.apple.security.cs.disable-library-validation`, and CPython/deps need
executable-memory + JIT entitlements. `CallBridge/entitlements.plist` grants
exactly those, plus the network client/server access the pipeline uses. Drop any
of them and the notarized app launches but the backend child process crashes.

---

## Troubleshooting

- **`notarytool` says *Invalid* — check the log:**
  `xcrun notarytool log <submission-id> --key … ` (the id is printed by
  `submit`). Almost always an unsigned nested binary or a missing hardened
  runtime flag — re-run `scripts/codesign-app.sh` and confirm every Mach-O under
  `Contents/Resources/callbridge-server` is signed.
- **App opens but no backend / menu shows "Server niet bereikbaar":** the
  embedded binary was signed without `disable-library-validation`. Confirm the
  entitlements were applied (`codesign -d --entitlements - CallBridge.app`).
- **DMG still warns on a fresh Mac:** it wasn't stapled. `xcrun stapler validate`
  the `.dmg`; stapling requires the notarization to have *succeeded* first.
