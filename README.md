# appstore-prep

A Claude Code plugin that captures the gnarly pre-submission steps of shipping iOS / macOS / Android apps to App Store Connect and Google Play. Distills hard-won failure modes (signing, packaging, asset hygiene) into skills that Claude can invoke automatically.

## Positioning

[**Blitz**](https://blitz.dev) is the right tool for *App Store Connect operations* — submit for review, manage versions, upload screenshots, attach IAPs, control TestFlight. ~35 MCP tools, native macOS GUI, polished.

**appstore-prep complements Blitz**, covering the part *before* the .pkg / .ipa is ready for upload:

| | appstore-prep | Blitz |
|---|---|---|
| OAuth-flow review-rejection scanner (Guideline 4.5/4.8) | ✅ | ❌ |
| `PrivacyInfo.xcprivacy` audit + Required Reason API detection (ITMS-91053) | ✅ | ❌ |
| iOS archive + upload, with train-closed and duplicate-build detection | ✅ | ❌ |
| Mac App Store .pkg signing (Apple Distribution + 3rd Party Mac Developer Installer) | ✅ | ❌ |
| SwiftPM nested-bundle 409 fix | ✅ | ❌ |
| AppIcon white-border / full-bleed validation | ✅ | ❌ |
| AccentColor.colorset 90546 fix | ✅ | ❌ |
| Android Play Store keystore + AAB packaging | (planned) | ❌ |
| ASO (keywords, subtitle, screenshots) | (planned) | ❌ |
| Cross-platform analytics SDK integration | (planned) | ❌ |
| ASC operations (versions, IAPs, TestFlight, screenshots upload) | ❌ | ✅ |

Use appstore-prep to produce a clean artifact, hand off to Blitz to submit it.

## Skills

### `privacy-manifest`

Audit and generate `PrivacyInfo.xcprivacy`. Catches the two ITMS-91053 enforcement issues that block new App Store submissions in 2026: (1) Required Reason APIs used without a declared reason — `UserDefaults`, `systemUptime`, file timestamps, `volumeAvailableCapacity`, `UITextInputMode.activeInputModes`; (2) flagged third-party SDKs (AppsFlyer, FBSDKCoreKit/Meta, Firebase, Google, OneSignal, etc) embedded without their own privacy manifest. Generator emits a valid starter manifest from a code scan.

Triggers when the user is preparing App Store submission, hits ITMS-91053, or integrates a flagged SDK.

### `oauth-review-check`

Static-scan an iOS / macOS Swift codebase for OAuth flows that App Store review will reject under Guideline 4.5 / 4.8 — `UIApplication.shared.open(authURL)` (kicks to Safari), `WKWebView` for OAuth (phishing risk), `NSWorkspace.shared.open` for auth (macOS). Recommends `ASWebAuthenticationSession` (OAuth with callback) or `SFSafariViewController` (view-only auth pages). Heuristic scoring: HIGH near a real OAuth URL, MED near auth-looking variable names, suppressible with `// oauth-review-check: ok`.

Triggers when the user is preparing for App Store submission, hit a Guideline 4 rejection, or asks if their login flow is App Store compliant.

### `release-ios`

Archive, export, and upload an iOS app to App Store Connect with one command. Generates a correct manual-signing `ExportOptions.plist`, optionally bumps `CFBundleVersion` in `project.yml` or `Info.plist` before archiving, and post-mortems the upload — if it fails with "train version closed for new build submissions" or "build N already exists", the script tells you exactly which version field to bump.

Triggers when the user wants to ship/archive/export/upload to App Store Connect or TestFlight, or hits errors about closed trains, duplicate build numbers, missing profiles, or `errSecInternalComponent`.

### `release-mac`

Package and sign a macOS Swift / SwiftPM app for the Mac App Store. Handles the whole `.pkg` flow including the SwiftPM nested-bundle fix, the AccentColor catalog hack, and the Apple Distribution → 3rd Party Mac Developer Installer signing distinction.

Triggers when the user is about to ship, or hits errors 409 / 90236 / 90546 / signing identity issues.

### `icon-check`

Validate an `AppIcon.appiconset` directory before submission. Catches the white-border bug (icon designed with built-in rounded corners — iOS applies its own squircle mask on top, leaving white pixels at the corners), missing required sizes, alpha on the 1024 marketing icon, and pixel-dimension mismatches.

Triggers when the user is about to upload, sees a halo on the home screen icon, or hits error 90236.

## Install

This is a [Claude Code plugin](https://docs.claude.com/en/docs/claude-code/plugins). Run inside Claude Code:

```
/plugin marketplace add Kevin-Wei-sudo/appstore-prep
/plugin install appstore-prep@kevin-wei-sudo
```

Once installed, the skills auto-load every session — Claude invokes `release-ios`, `release-mac`, `icon-check`, `aso-audit`, or `oauth-review-check` automatically when the conversation matches their triggers (e.g. "I want to ship to App Store", "is my OAuth flow compliant", "validate my AppIcon").

### Local clone install

If you want to hack on the plugin while using it:

```sh
git clone https://github.com/Kevin-Wei-sudo/appstore-prep ~/dev/appstore-prep
```

Then in `.claude/settings.json`:

```json
{
  "plugins": ["~/dev/appstore-prep"]
}
```

## Run a script directly

You don't need Claude Code to use the scripts — they're self-contained:

```sh
# Validate an icon set
./skills/icon-check/scripts/check-icons.sh ios/MyApp/Assets.xcassets/AppIcon.appiconset

# Preflight signing setup
./skills/release-mac/scripts/preflight.sh

# Sign and package a macOS .app
./skills/release-mac/scripts/sign-and-package.sh \
  --app /path/to/MyApp.app \
  --entitlements /path/to/MyApp.entitlements \
  --profile ~/Library/MobileDevice/Provisioning\ Profiles/MyApp_Mac_App_Store.provisionprofile \
  --distribution-identity "Apple Distribution: Name (TEAMID)" \
  --installer-identity "3rd Party Mac Developer Installer: Name (TEAMID)" \
  --output /path/to/MyApp.pkg
```

Requires macOS (uses `sips`, `swift`, `codesign`, `productbuild`, `PlistBuddy`). Xcode Command Line Tools is sufficient — full Xcode is not required.

## Roadmap

- `release-android` — Play Console keystore setup, AAB build, fastlane metadata template
- `integrate-analytics` — wire AppsFlyer + Meta SDK into iOS/Android with the right ATT + SKAdNetwork plumbing

Not in scope: anything Blitz already does well (ASC operations, TestFlight, IAPs).

## License

Apache-2.0
