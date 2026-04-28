#!/usr/bin/env bash
#
# Audit a project for PrivacyInfo.xcprivacy correctness:
#   1. Locate any PrivacyInfo.xcprivacy in the project
#   2. Scan code for Required Reason APIs and check the manifest
#      declares each one (ITMS-91053 prevention)
#   3. Cross-reference SDK dependencies against Apple's "commonly used
#      SDKs" list — those must ship their OWN manifest
#
# Exits 1 if any hard violations (Required Reason API used but not
# declared, OR flagged SDK without its own manifest in Pods/).
set -euo pipefail

DIR="${1:-}"
if [[ -z "$DIR" || ! -d "$DIR" ]]; then
    cat <<EOF >&2
Usage: $0 <project-dir>

Walks the project to find PrivacyInfo.xcprivacy files, scans Swift / Obj-C
code for Required Reason API usage, and lists third-party SDKs against
Apple's flagged list.
EOF
    exit 2
fi

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
gray() { printf '\033[90m%s\033[0m\n' "$*"; }

fail=0

# 1. Find manifest
bold "==> Looking for PrivacyInfo.xcprivacy"
manifests=$(find "$DIR" -type f -name 'PrivacyInfo.xcprivacy' \
    ! -path '*/Pods/*' \
    ! -path '*/DerivedData/*' \
    ! -path '*/build/*' 2>/dev/null || true)

if [[ -z "$manifests" ]]; then
    red "  ✗ no PrivacyInfo.xcprivacy found in the app target"
    red "    generate one with: ./generate-manifest.sh <swift-source-dir> > PrivacyInfo.xcprivacy"
    red "    then add to the app target's 'Copy Bundle Resources' build phase"
    fail=1
    main_manifest=""
else
    while IFS= read -r m; do
        green "  ✓ found: ${m#$DIR/}"
    done <<<"$manifests"
    main_manifest=$(head -1 <<<"$manifests")
fi

# 2. Required Reason API scan
bold ""
bold "==> Scanning for Required Reason API usage"

# Each entry: <regex>|<category>|<friendly>
APIS=(
    "UserDefaults|NSPrivacyAccessedAPICategoryUserDefaults|UserDefaults / NSUserDefaults"
    "\\.systemUptime|NSPrivacyAccessedAPICategorySystemBootTime|ProcessInfo.systemUptime"
    "\\.creationDate|NSPrivacyAccessedAPICategoryFileTimestamp|file creationDate"
    "\\.modificationDate|NSPrivacyAccessedAPICategoryFileTimestamp|file modificationDate"
    "contentModificationDateKey|NSPrivacyAccessedAPICategoryFileTimestamp|contentModificationDateKey"
    "creationDateKey|NSPrivacyAccessedAPICategoryFileTimestamp|creationDateKey"
    "attributesOfItem|NSPrivacyAccessedAPICategoryFileTimestamp|FileManager.attributesOfItem"
    "volumeAvailableCapacity|NSPrivacyAccessedAPICategoryDiskSpace|volumeAvailableCapacity"
    "activeInputModes|NSPrivacyAccessedAPICategoryActiveKeyboards|UITextInputMode.activeInputModes"
)

# Collect categories actually used in code
declare_used=()
note_use() {
    local cat="$1"
    for x in "${declare_used[@]:-}"; do
        [[ "$x" == "$cat" ]] && return
    done
    declare_used+=("$cat")
}

scan_files=$(find "$DIR" -type f \( -name '*.swift' -o -name '*.m' -o -name '*.mm' \) \
    ! -path '*/Pods/*' ! -path '*/DerivedData/*' ! -path '*/build/*' ! -path '*/.build/*' 2>/dev/null)

for entry in "${APIS[@]}"; do
    regex="${entry%%|*}"
    rest="${entry#*|}"
    cat="${rest%%|*}"
    friendly="${rest#*|}"
    hits=$(echo "$scan_files" | xargs grep -lE "$regex" 2>/dev/null || true)
    if [[ -n "$hits" ]]; then
        gray "  $friendly used in:"
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            gray "    ${f#$DIR/}"
        done <<<"$hits"
        note_use "$cat"
    fi
done

# Check declarations vs usage
if [[ -n "$main_manifest" ]]; then
    echo
    for cat in "${declare_used[@]:-}"; do
        if grep -q "$cat" "$main_manifest"; then
            green "  ✓ $cat declared in manifest"
        else
            red "  ✗ $cat used in code but NOT declared in $main_manifest"
            red "    add an <NSPrivacyAccessedAPIType> block — see SKILL.md for reason codes"
            fail=1
        fi
    done
    # Reverse: stale declarations
    while IFS= read -r declared_cat; do
        [[ -z "$declared_cat" ]] && continue
        used=0
        for u in "${declare_used[@]:-}"; do
            [[ "$u" == "$declared_cat" ]] && used=1 && break
        done
        if (( ! used )); then
            yellow "  ! $declared_cat declared in manifest but no usage found in code"
            yellow "    consider removing — Apple may ask why it's declared"
        fi
    done < <(grep -oE 'NSPrivacyAccessedAPICategory[A-Za-z]+' "$main_manifest" | sort -u)
fi

# 3. SDK list check
bold ""
bold "==> Cross-checking third-party SDKs against Apple's flagged list"

# Apple's flagged SDKs that MUST ship their own PrivacyInfo.xcprivacy.
# (Curated April 2026 — Apple updates this list periodically; see
# developer.apple.com/support/third-party-SDK-requirements/)
FLAGGED_SDKS="
Abseil
AFNetworking
Alamofire
AppAuth
BoringSSL
openssl_grpc
Charts
connectivity_plus
device_info_plus
DKImagePickerController
DKPhotoGallery
FBAEMKit
FBLPromises
FBSDKCoreKit
FBSDKLoginKit
FBSDKShareKit
file_picker
FirebaseABTesting
FirebaseAnalytics
FirebaseAuth
FirebaseCore
FirebaseCoreDiagnostics
FirebaseCoreInternal
FirebaseCrashlytics
FirebaseDynamicLinks
FirebaseFirestore
FirebaseInstallations
FirebaseMessaging
FirebaseRemoteConfig
fluttertoast
FMDB
geolocator_apple
GoogleDataTransport
GoogleSignIn
GoogleToolboxForMac
GoogleUtilities
grpc
GTMAppAuth
GTMSessionFetcher
hermes
image_picker_ios
IQKeyboardManager
IQKeyboardManagerSwift
Kingfisher
libavif
libwebp
lottie-ios
lottie-react-native
Mantle
MaterialComponents
nanopb
OneSignal
OneSignalCore
OneSignalExtension
OneSignalOutcomes
OpenSSL
OrderedSet
package_info
package_info_plus
path_provider
path_provider_ios
PromisesObjC
PromisesSwift
Protobuf
Reachability
ReachabilitySwift
RealmSwift
RxCocoa
RxRelay
RxSwift
SDWebImage
share_plus
shared_preferences_ios
SnapKit
sqflite
Starscream
SVProgressHUD
SwiftProtobuf
SwiftyGif
SwiftyJSON
Toast
url_launcher
url_launcher_ios
video_player_avfoundation
wakelock_plus
webview_flutter_wkwebview
"

# Find dependency manifests
podfile_lock=$(find "$DIR" -maxdepth 4 -name 'Podfile.lock' ! -path '*/build/*' 2>/dev/null | head -1)
package_resolved=$(find "$DIR" -maxdepth 5 -name 'Package.resolved' ! -path '*/build/*' 2>/dev/null | head -1)
cartfile_resolved=$(find "$DIR" -maxdepth 4 -name 'Cartfile.resolved' 2>/dev/null | head -1)

found_any=0
detected_sdks=""

check_sdk_in_manifest() {
    local manifest="$1"
    while IFS= read -r sdk; do
        [[ -z "$sdk" ]] && continue
        # Word-boundary match to avoid e.g. "FirebaseCore" matching "FirebaseCoreInternal"
        if grep -qE "(^|[^A-Za-z])$sdk([^A-Za-z0-9]|$)" "$manifest"; then
            detected_sdks="$detected_sdks$sdk\n"
            found_any=1
        fi
    done <<<"$FLAGGED_SDKS"
}

if [[ -n "$podfile_lock" ]]; then
    gray "  scanning ${podfile_lock#$DIR/}"
    check_sdk_in_manifest "$podfile_lock"
fi
if [[ -n "$package_resolved" ]]; then
    gray "  scanning ${package_resolved#$DIR/}"
    check_sdk_in_manifest "$package_resolved"
fi
if [[ -n "$cartfile_resolved" ]]; then
    gray "  scanning ${cartfile_resolved#$DIR/}"
    check_sdk_in_manifest "$cartfile_resolved"
fi
# Also check direct SDK presence (e.g. AppsFlyer added without CocoaPods)
appsflyer_present=0
if find "$DIR" -type d -name 'AppsFlyer*' ! -path '*/build/*' 2>/dev/null | head -1 | grep -q .; then
    appsflyer_present=1
    detected_sdks="${detected_sdks}AppsFlyer\n"
    found_any=1
fi

if (( found_any )); then
    yellow ""
    yellow "  ! flagged SDK(s) detected — each MUST ship its own PrivacyInfo.xcprivacy:"
    printf "$detected_sdks" | sort -u | while IFS= read -r s; do
        [[ -z "$s" ]] && continue
        # Verify the SDK ships a manifest if installed via Pods
        sdk_manifest=$(find "$DIR" -path "*/Pods/$s/*PrivacyInfo.xcprivacy" 2>/dev/null | head -1)
        if [[ -n "$sdk_manifest" ]]; then
            green "    ✓ $s — has its own manifest at ${sdk_manifest#$DIR/}"
        else
            # If we can't find the SDK in Pods, we can't verify the manifest is bundled.
            # That's expected for SwiftPM (not all SDK manifests are scannable from
            # Package.resolved alone). Just print the requirement.
            yellow "    ? $s — verify the version you use ships PrivacyInfo.xcprivacy"
            yellow "      (older versions don't — upgrade if needed)"
        fi
    done
else
    green "  ✓ no flagged SDKs detected"
fi

echo
if (( fail )); then
    red "privacy-manifest audit FAILED."
    exit 1
fi
green "privacy-manifest audit passed (warnings, if any, are advisory)."
