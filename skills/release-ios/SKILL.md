---
name: release-ios
description: Use this skill to archive, export, and upload an iOS app to App Store Connect. Wraps `xcodebuild archive` + `xcodebuild -exportArchive`, generates a correct ExportOptions.plist with manual signing, and detects the two most painful pre-upload failures — "train version is closed for new build submissions" (need to bump MARKETING_VERSION) and "build N already exists" (need to bump CFBundleVersion). Trigger when the user asks to ship, archive, export, upload, or submit an iOS build to App Store Connect / TestFlight, or when they hit errors about closed train versions, duplicate build numbers, missing provisioning profiles, or `Apple Distribution` signing failures.
---

# release-ios

Wraps the iOS archive → export → upload flow as a single command, with the failure modes we've actually hit pre-detected.

## When to use this skill

- The user wants to ship an iOS build to App Store Connect (or TestFlight)
- They got "train version 'X.Y.Z' is closed for new build submissions" on upload (= the version was approved while iterating; need a new MARKETING_VERSION)
- They got "this version has already been used" / "build N already exists" (= need to bump CFBundleVersion)
- They got "no profile matching" / "Apple Distribution: ... not found" during archive

## What this skill does

[scripts/archive-and-upload.sh](scripts/archive-and-upload.sh) runs the full flow:

1. **(Optional) Regenerate Xcode project from XcodeGen** if `project.yml` is present
2. **Archive** with `xcodebuild archive` using manual signing — never let Xcode "automatically manage signing" for distribution; it picks the wrong cert at random
3. **Generate `ExportOptions.plist`** if you don't supply one (sets `method=app-store-connect`, `signingStyle=manual`, your provisioning profile)
4. **Export + upload** with `xcodebuild -exportArchive` (this both signs the IPA and ships it to App Store Connect — destination=upload)
5. **Detect the train-closed / duplicate-build errors** in the output and tell you exactly which version field to bump

## Usage

```sh
./archive-and-upload.sh \
  --workspace /path/to/MyApp.xcworkspace \
  --scheme MyApp \
  --bundle-id io.example.myapp \
  --team-id ABCDE12345 \
  --distribution-identity "Apple Distribution: Foo (ABCDE12345)" \
  --profile-name "MyApp iOS App Store" \
  --archive-path ./build/MyApp.xcarchive \
  --export-path ./build/export
```

If your project uses XcodeGen, set `--regenerate-project /path/to/dir-with-project.yml` and the script runs `xcodegen generate` first.

If you want the script to bump the build number for you before archiving, pass `--bump-build-from project.yml` or `--bump-build-from Info.plist` — it increments `CURRENT_PROJECT_VERSION` (or `CFBundleVersion`) by 1 in-place.

## Preconditions

Run [scripts/preflight.sh](scripts/preflight.sh) first. It checks:

1. **Apple Distribution** code-signing identity present in keychain
2. **iOS App Store** provisioning profile installed (`Platform = iOS`, no `ProvisionedDevices`, app id matches your bundle id)
3. `xcodebuild`, `xcrun altool`, `/usr/libexec/PlistBuddy` available
4. `xcodegen` available if `project.yml` exists in the project directory
5. App-specific password keychain entry exists (for `altool` upload). If you upload via `xcodebuild -exportArchive` with `destination=upload`, the auth piggybacks off your Xcode session — but `altool` retries need the keychain entry.

## The failure modes you'll actually hit

### "Invalid Pre-Release Train. The train version 'X.Y.Z' is closed for new build submissions"

What it means: a build for that `MARKETING_VERSION` was already approved. Apple closes the train so you can't keep adding builds to a shipped version.

What to do: bump `MARKETING_VERSION` to a new value (typically a patch increment). The build number can stay the same (`CFBundleVersion` only needs to be globally unique per train, but in practice incrementing it keeps things sane).

The script detects this string in the upload output and prints:

```
==> Train closed for X.Y.Z. Bump MARKETING_VERSION (e.g. X.Y.(Z+1)) and re-run.
```

This was the #1 footgun while shipping ClaudeScope this week — we hit it twice in a row because Apple approved Build N while we were preparing Build N+1 for the same version.

### "This version has already been used. Please update version and rebuild"

What it means: `CFBundleVersion` (Build N) was already uploaded for this train.

What to do: increment `CFBundleVersion` and re-archive. The script flags this with:

```
==> Build number N already used. Bump CFBundleVersion (e.g. to N+1) and re-run.
```

Use `--bump-build-from <file>` to do this automatically next time.

### "No profile matching 'XYZ' was found"

What it means: either the profile isn't installed, or the name in your `--profile-name` flag doesn't match the `Name` field inside the .provisionprofile.

What to do: check installed profiles with:

```sh
ls ~/Library/MobileDevice/Provisioning\ Profiles/
# pick the file, then:
security cms -D -i <file> | grep -A1 '<key>Name</key>'
```

Use that exact `Name` for `--profile-name`. The file basename is irrelevant.

### "errSecInternalComponent" on archive

Almost always a keychain access issue (Xcode running in a different security session than your terminal). Unlock the login keychain explicitly:

```sh
security unlock-keychain -p "$KEYCHAIN_PASSWORD" ~/Library/Keychains/login.keychain-db
```

If that doesn't help, the cert's private key isn't in the keychain holding the cert. Re-import the .p12.

## OAuth / SFSafariViewController guideline (avoid the rejection we hit)

If your app does OAuth, **do not** use `UIApplication.shared.open(authURL)` — it kicks the user out to Safari and Apple rejects under Guideline 4 (Design). Wrap the auth URL in `SFSafariViewController` instead. The `oauth-review-check` skill (see roadmap) will scan for this anti-pattern, but it's worth checking manually:

```sh
grep -RIn 'UIApplication.shared.open' --include='*.swift' .
```

If any of those URLs are auth/login flows, fix them before submitting — this rejection costs 5–7 days of re-review.

## After upload

The build appears in App Store Connect under TestFlight → Builds within 5–15 minutes of upload (status: "Processing" → "Ready to Submit"). Then either:

- Use Blitz / ASC GUI to attach the build to a version and submit for review.
- Use `aso-audit` (planned) to check the metadata before submission.

This skill stops at "build is in ASC and processed" — submission is downstream.
