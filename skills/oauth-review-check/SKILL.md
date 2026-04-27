---
name: oauth-review-check
description: Use this skill to scan an iOS / macOS codebase for OAuth / sign-in flows that will be rejected under App Store Guideline 4.5 / 4.8. Specifically: detects `UIApplication.shared.open(url)` (and the older `openURL`) calls where the URL is auth-related, `NSWorkspace.shared.open` for auth on macOS, and `WKWebView` used for OAuth (also rejected). Recommends the correct API per case — `ASWebAuthenticationSession` for OAuth with a callback, `SFSafariViewController` for view-only auth pages (paste-code flow). Trigger when: user is preparing for App Store submission and uses any OAuth/SSO flow, hit a Guideline 4 rejection saying "the OAuth experience opens in Safari", asks "is my login flow App Store compliant", or when you see auth-looking URLs being opened with UIApplication APIs.
---

# oauth-review-check

Static-scan an iOS / macOS Swift codebase for OAuth flows that App Store review will reject. The check is grep-based and runs in seconds.

## Why this matters

Apple Guideline 4.5 / 4.8 (Design): *"Sign-In experiences must keep the user inside your app."* If your app does OAuth and you do any of these, you'll get rejected:

| Anti-pattern | Why Apple rejects |
|---|---|
| `UIApplication.shared.open(authURL)` | Kicks the user out to Safari. Loses app context. The user can't tell if they're back in your app afterward. |
| `WKWebView` for OAuth | Phishing risk — user can't see the URL bar. Also rejected because it bypasses the system's password-autofill + biometrics. |
| `openURL(authURL)` (deprecated API) | Same problem as `UIApplication.shared.open`. |
| `NSWorkspace.shared.open(authURL)` (macOS) | macOS App Store equivalent — kicks to default browser. Less strictly enforced than iOS but still flagged. |

Single rejection cycle = 5–7 days of review limbo. This skill catches the issue *before* you submit.

## What the right answer looks like

**For "view-only" auth pages (paste-code flow)** — user opens login page, copies a code, pastes it back into your app. Use `SFSafariViewController`:

```swift
import SafariServices

let safariVC = SFSafariViewController(url: authURL)
present(safariVC, animated: true)
```

**For "callback" OAuth** — auth provider redirects back to your app via a custom URL scheme. Use `ASWebAuthenticationSession`:

```swift
import AuthenticationServices

let session = ASWebAuthenticationSession(
    url: authURL,
    callbackURLScheme: "myapp"
) { callbackURL, error in
    // handle the redirect
}
session.presentationContextProvider = self
session.start()
```

`ASWebAuthenticationSession` is what Apple wants for OAuth — it handles cookies properly, returns the callback URL, and lives in a sandboxed Safari instance.

## Run the scan

```sh
./scripts/scan.sh /path/to/ios/Sources
```

Or scan the whole app at once:

```sh
./scripts/scan.sh ios/MyApp
```

The script:

1. Greps for `UIApplication.shared.open`, `UIApplication.openURL`, `NSWorkspace.shared.open`, and `WKWebView` initializations
2. For each hit, looks at the surrounding ±15 lines for auth-URL signals (`oauth`, `/authorize`, `/login`, `appleid.apple.com`, `accounts.google.com`, etc.)
3. Reports each suspect call site with the matching auth-URL hint and a one-line fix
4. Exits 1 if any high-confidence violation is found; exits 0 otherwise (warnings still print)

## Interpreting the output

- **❌ HIGH** — `UIApplication.shared.open` or `WKWebView` near an auth URL. **Fix before submission**, or expect rejection.
- **⚠️ MED** — `UIApplication.shared.open` near a URL that *might* be auth (suggestive variable name like `loginURL`, `authURL`). Verify manually.
- **ℹ️ INFO** — `ASWebAuthenticationSession` or `SFSafariViewController` already imported in the file. Likely OK.

## False positives

The scanner is grep-based — no AST. Two known false-positive classes:

1. **Marketing URLs labeled "login"**: a button like `UIApplication.shared.open(URL(string: "https://example.com/login")!)` that just opens your marketing login *page* (not the OAuth flow itself) is technically legal — Apple allows opening a marketing site in Safari. But it's still risky because reviewers may not distinguish. Move it into `SFSafariViewController` to be safe.
2. **Universal links to your own app**: `UIApplication.shared.open(URL(string: "https://myapp.example.com/callback?token=..."))` is fine — it bounces back into your app via universal links. The scanner can't always tell. Suppress with a `// oauth-review-check: ok` trailing comment.

Use the suppression comment sparingly — false suppressions defeat the point of the scan.

## Hooking into release-ios

Run before every archive:

```sh
appstore-prep/skills/oauth-review-check/scripts/scan.sh ios/MyApp/Sources && \
appstore-prep/skills/release-ios/scripts/archive-and-upload.sh ...
```

If the scan reports a HIGH, the archive doesn't run.
