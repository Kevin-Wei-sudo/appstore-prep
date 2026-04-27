---
name: release-mac
description: Use this skill when packaging or uploading a macOS Swift / SwiftPM app to the Mac App Store. Handles Apple Distribution + 3rd Party Mac Developer Installer signing, embedding the Mac App Store provisioning profile, patching SwiftPM nested-bundle Info.plists (the CFBundleIdentifier 409 error), forcing actool to emit Assets.car when the catalog is AppIcon-only (the 90546 error), AppIcon size requirements (the 90236 "missing 512pt@2x" error), and producing a signed .pkg ready for Transporter / altool upload. Trigger when the user says they want to ship, submit, package, sign, or upload a Mac app to App Store Connect, or when they hit any of: error 409 missing bundle identifier, error 90236 missing icon, error 90546 missing asset catalog, productbuild signing problems, or "Apple Distribution" / "3rd Party Mac Developer Installer" identity issues.
---

# release-mac

Ship a macOS Swift / SwiftPM app to the Mac App Store. This is the playbook — the part that comes *before* you click "Submit for Review" in App Store Connect (which Blitz handles well).

## When to use this skill

The user is trying to:
- Upload a `.pkg` to App Store Connect for a macOS app
- Resolve a Transporter / altool validation error in the 90xxx or 409 range
- Set up signing identities and provisioning for a first-time Mac App Store build
- Re-sign an ad-hoc `.app` for App Store distribution

If the user only needs to submit, manage versions, edit pricing, upload screenshots — point them to Blitz (https://blitz.dev). This skill complements it: Blitz handles ASC; this skill produces the artifact ASC accepts.

## Preconditions to confirm before signing

Run [scripts/preflight.sh](scripts/preflight.sh) before anything else. It checks:

1. **Signing identities present in keychain.** Both are needed:
   - `Apple Distribution: <Name> (<TEAM_ID>)` — signs the `.app`
   - `3rd Party Mac Developer Installer: <Name> (<TEAM_ID>)` — signs the `.pkg`
   - These are *different certificates*. A common mistake is trying to sign the .pkg with "Developer ID Installer" — that's for direct distribution (DMG/notarization), not App Store.
2. **Mac App Store provisioning profile** installed under `~/Library/MobileDevice/Provisioning Profiles/`. Type must be `Mac App Store Connect` (not `Mac Development`, not `Developer ID`). The profile's app ID must match the bundle id you're shipping.
3. **App Store Connect app record exists** with the matching bundle id. The .pkg upload will silently fail if no record exists yet.

## The five-step packaging flow

Use [scripts/sign-and-package.sh](scripts/sign-and-package.sh). It accepts:

```
./sign-and-package.sh \
  --app /path/to/MyApp.app \
  --entitlements /path/to/MyApp.entitlements \
  --profile /path/to/MyApp_Mac_App_Store.provisionprofile \
  --distribution-identity "Apple Distribution: Name (TEAMID)" \
  --installer-identity "3rd Party Mac Developer Installer: Name (TEAMID)" \
  --output /path/to/MyApp.pkg
```

Steps the script runs (read it before running on a real release; the obscure parts are commented):

1. **Embed the provisioning profile** as `Contents/embedded.provisionprofile` inside the bundle. Mac App Store builds will not validate without this even if the profile is installed system-wide.
2. **Scrub xattrs** (`xattr -cr`). Quarantine and com.apple.FinderInfo xattrs survive a build and break codesign.
3. **Patch SwiftPM nested-bundle Info.plists.** SwiftPM emits resource bundles like `MyApp_MyApp.bundle` whose `Info.plist` only has `CFBundleDevelopmentRegion`. ASC validation rejects nested bundles missing `CFBundleIdentifier` with error 409 ("Missing Bundle Identifier"). The script walks every `*.bundle` in the .app, derives a stable `<main_id>.resources.<bundle-name>` identifier, and adds the missing keys. This is the single most common cause of first-time Mac App Store upload failures for SwiftPM apps.
4. **Codesign nested bundles first, then the outer .app.** Order matters — outer signature seals the inner ones. Use `--options runtime --timestamp` and pass entitlements only to the outer signature. Verify with `codesign --verify --deep --strict --verbose=2`.
5. **`productbuild --component <app> /Applications --sign <installer>`**. The `--component` form is correct for App Store; do not use `productbuild --component-plist` unless you have multiple components. `pkgutil --check-signature` should print "signed by a developer certificate issued by Apple for distribution".

## Common failure modes and fixes

### Error 409 — Missing Bundle Identifier

A nested `.bundle` (usually SwiftPM's resource bundle) has no `CFBundleIdentifier`. The packaging script handles this in step 3. If you saw this error from a different tool: copy the patching block out of [scripts/sign-and-package.sh](scripts/sign-and-package.sh), or run the script end-to-end.

### Error 90236 — Missing required icon "512pt × 512pt @2x"

Your `AppIcon.appiconset` is missing the 1024×1024 PNG slot, **or** all sizes were generated by resizing the wrong source. Symptoms include the 1024 image actually being a 512×512 file with `@2x` metadata, or the icon set having fewer slots than `Contents.json` declares.

Fix:
- Make sure `AppIcon-1024.png` is genuinely 1024×1024 pixels, no alpha.
- Regenerate every smaller size from that 1024 source via `sips -z N N AppIcon-1024.png --out AppIcon-N.png`.
- Verify each file's actual pixel dimensions with `sips -g pixelWidth -g pixelHeight AppIcon-*.png`.

### Error 90546 — Missing asset catalog

actool only emits `Assets.car` when the catalog has at least one *non-AppIcon* asset. If your `Assets.xcassets` only contains `AppIcon.appiconset`, ASC rejects the build because no asset catalog made it into the bundle.

Fix: add a trivial `AccentColor.colorset/Contents.json` (any color works — it's the existence that matters). Reference template: [scripts/AccentColor.colorset.Contents.json](scripts/AccentColor.colorset.Contents.json).

### "errSecInternalComponent" during codesign

Almost always a keychain access issue. Unlock the keychain explicitly and retry:

```sh
security unlock-keychain -p "$KEYCHAIN_PASSWORD" ~/Library/Keychains/login.keychain-db
```

If it persists, the signing identity's private key isn't in the keychain holding the cert. Check with `security find-identity -v -p codesigning` — if the cert appears with no `valid identities found` next to it, re-import the .p12.

### "main executable failed strict validation" / Sparkle leftover

App Store builds must not embed Sparkle. If your DMG build path embeds it, your App Store path needs to either skip Sparkle entirely (via a build flag) or strip it before signing. The script signs whatever frameworks exist; that's not the right place to strip — fix it in the build step.

## Upload

Two valid paths after the .pkg is signed:

- **Transporter.app** (recommended for first upload): `open -a Transporter <pkg>`. Lets you see validation errors clearly.
- **`xcrun altool`**: needs an app-specific password stored in keychain.

  ```sh
  xcrun altool --upload-app -f <pkg> -t macos \
    -u <apple_id> -p @keychain:ASC_APP_SPECIFIC_PASSWORD
  ```

After upload, switch to Blitz / ASC GUI to attach the build to a version and submit for review.

## Reference: certificate types

| Distribution path | App signing cert | Installer cert | Notarization needed? |
|---|---|---|---|
| Mac App Store | Apple Distribution | 3rd Party Mac Developer Installer | No (App Store path) |
| Direct download / DMG | Developer ID Application | Developer ID Installer (for .pkg) | Yes |
| Internal / development | Apple Development | n/a | n/a |

A common bug: a developer has a `Developer ID Application` cert and assumes it works for App Store. It does not. The Mac App Store path requires `Apple Distribution`.
