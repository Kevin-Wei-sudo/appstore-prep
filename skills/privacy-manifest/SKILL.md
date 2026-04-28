---
name: privacy-manifest
description: Use this skill to verify and generate `PrivacyInfo.xcprivacy` for an iOS / macOS app. Catches the two App Store enforcement issues that produce ITMS-91053 warnings (now blocking for new submissions in 2026): (1) Required Reason APIs used without a declared reason in `NSPrivacyAccessedAPITypes` — `UserDefaults`, `systemUptime`, file timestamps, `volumeAvailableCapacity`, `UITextInputMode.activeInputModes`; (2) third-party SDKs from Apple's flagged "commonly used SDKs" list embedded without their own privacy manifest (AppsFlyer, FBSDKCoreKit / Meta, Firebase, Google, OneSignal, etc). Trigger when: user is preparing App Store submission, hit ITMS-91053 / "Missing API declaration" warnings, integrated AppsFlyer / Meta / Firebase, or asks "do I need a privacy manifest".
---

# privacy-manifest

Audit and generate `PrivacyInfo.xcprivacy` for your app. Apple started warning on missing manifests in May 2024 (ITMS-91053); for new submissions in 2026 the warnings are blocking.

## When to use this skill

- About to submit a new app to the App Store
- Got an "ITMS-91053: Missing API declaration" warning during upload
- Just integrated AppsFlyer / Meta / Firebase / OneSignal / any third-party analytics
- Migrated a project from before mid-2024 and never added a privacy manifest

## What it checks

Run [scripts/audit-manifest.sh](scripts/audit-manifest.sh) on a project directory:

```sh
./audit-manifest.sh /path/to/ios/MyApp
```

The script does three things:

### 1. Find the manifest file

Walks the project for `PrivacyInfo.xcprivacy` files. Reports where it found them and whether the main app target has one. (A common bug: developers add the manifest but forget to include it in the **app target**'s build phase, so it doesn't ship in the bundle.)

### 2. Scan Swift / Obj-C code for Required Reason APIs

Apple maintains a list of APIs that require a declared "approved reason" in `NSPrivacyAccessedAPIType`. The script greps for each category and reports usage:

| API | Category in manifest | Common reasons |
|---|---|---|
| `UserDefaults`, `NSUserDefaults` | `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1` (App settings) |
| `.systemUptime` (ProcessInfo) | `NSPrivacyAccessedAPICategorySystemBootTime` | `35F9.1` (Measure time on-device) |
| `creationDate`, `modificationDate`, `contentModificationDateKey` | `NSPrivacyAccessedAPICategoryFileTimestamp` | `DDA9.1` (Display to user), `C617.1` (Inside app or group container) |
| `volumeAvailableCapacity` | `NSPrivacyAccessedAPICategoryDiskSpace` | `85F4.1` (Display to user), `E174.1` (Inside app or group container) |
| `UITextInputMode.activeInputModes` | `NSPrivacyAccessedAPICategoryActiveKeyboards` | `54BD.1` (Customize the UI for active keyboard) |

For each API used in code, the script checks whether the matching `NSPrivacyAccessedAPIType` block exists in the manifest. Missing → ITMS-91053 on upload.

### 3. Detect flagged third-party SDKs

Apple maintains a list of "commonly used SDKs" that **must** ship their own `PrivacyInfo.xcprivacy` (since May 2024). The script scans for:

- `Podfile.lock` — every pod versus the flagged list
- `Package.resolved` — every SwiftPM dependency
- `Cartfile.resolved` — Carthage
- `Pods/<SDK>/PrivacyInfo.xcprivacy` — verify the manifest is actually there

Flagged SDKs the script knows about (April 2026 list):
AppsFlyer, FBSDKCoreKit / FBSDKLoginKit / FBSDKShareKit / FBAEMKit (Meta), Firebase (all subspecs), GoogleSignIn, GoogleUtilities, GoogleDataTransport, OneSignal, Alamofire, AFNetworking, SDWebImage, Kingfisher, RealmSwift, RxSwift, RxCocoa, RxRelay, SnapKit, IQKeyboardManager, SVProgressHUD, lottie-ios, Charts, hermes, Mantle, FMDB, MaterialComponents, OpenSSL, BoringSSL / openssl_grpc, grpc, Protobuf, SwiftProtobuf, nanopb, FBLPromises, PromisesObjC, PromisesSwift, GTMAppAuth, GTMSessionFetcher, GoogleToolboxForMac, AppAuth, Reachability, ReachabilitySwift, Starscream, SwiftyGif, SwiftyJSON, Toast, OrderedSet, libavif, libwebp, plus all Flutter `*_plus` and platform packages.

Out-of-date SDK = upload warning at best, rejection at worst.

## Generate a starter manifest

If you don't have one yet:

```sh
./scripts/generate-manifest.sh /path/to/ios/MyApp/Sources > PrivacyInfo.xcprivacy
```

The generator scans your code for Required Reason API usage and writes a manifest with the matching `NSPrivacyAccessedAPIType` blocks. You still need to:

1. Add the file to your app target (Build Phases → Copy Bundle Resources)
2. Set `NSPrivacyTracking` to true if you have any tracking SDK (AppsFlyer, Meta, etc.)
3. Fill in `NSPrivacyTrackingDomains` with the analytics endpoints
4. Fill in `NSPrivacyCollectedDataTypes` for anything you collect (email, device id, IP, etc.)

The generator picks the most common reason code for each API. For ambiguous cases (file timestamps used for cache invalidation vs displaying to user), it picks `C617.1` and you should review.

## NSPrivacyTracking and NSPrivacyTrackingDomains

These are the two fields that catch most teams off guard. If you integrate any SDK that does cross-app tracking (AppsFlyer is the canonical example):

```xml
<key>NSPrivacyTracking</key>
<true/>
<key>NSPrivacyTrackingDomains</key>
<array>
    <string>impression.appsflyer.com</string>
    <string>events.appsflyer.com</string>
    <string>register.appsflyer.com</string>
    <string>onelink-api.appsflyer.com</string>
    <!-- Meta -->
    <string>graph.facebook.com</string>
    <string>graph.instagram.com</string>
    <string>connect.facebook.net</string>
</array>
```

Without these, ATT permission means nothing — the system blocks the calls *anyway* because the domain isn't declared.

## Hooking into release-ios

```sh
appstore-prep/skills/privacy-manifest/scripts/audit-manifest.sh ios/MyApp && \
appstore-prep/skills/release-ios/scripts/archive-and-upload.sh ...
```

If audit fails on a Required Reason API mismatch, the archive doesn't run.

## Reference

- [Apple — Describing required reason API usage](https://developer.apple.com/documentation/bundleresources/privacy_manifest_files/describing_use_of_required_reason_api)
- [Apple — Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy_manifest_files)
- [Apple — Required Reason API list (full)](https://developer.apple.com/documentation/bundleresources/privacy_manifest_files/describing_use_of_required_reason_api)
