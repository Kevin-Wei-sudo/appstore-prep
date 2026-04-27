#!/usr/bin/env bash
#
# Preflight check for iOS App Store packaging.
#
# Verifies:
#   1. Apple Distribution code-signing identity present
#   2. At least one iOS App Store provisioning profile installed
#      (Platform=iOS, no ProvisionedDevices)
#   3. xcodebuild, altool, PlistBuddy available
#   4. xcodegen if `project.yml` is in the project dir
#
# Optional: pass --bundle-id <id> to verify a profile actually covers
# the given app id.
set -euo pipefail

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

BUNDLE_ID=""
PROJECT_DIR="${PWD}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
        --project-dir) PROJECT_DIR="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--bundle-id <id>] [--project-dir <path>]
EOF
            exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

fail=0

echo "==> Checking signing identities"
codesigning="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if grep -q "Apple Distribution:" <<<"$codesigning"; then
    green "  ✓ Apple Distribution identity present"
else
    red "  ✗ no 'Apple Distribution' identity found"
    red "    download an Apple Distribution cert from developer.apple.com → Certificates,"
    red "    install the .cer (double-click), and ensure its private key is in your"
    red "    login keychain (.p12 import from the original Mac)."
    fail=1
fi

echo
echo "==> Checking iOS App Store provisioning profiles"
profile_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
if [[ ! -d "$profile_dir" ]]; then
    red "  ✗ $profile_dir does not exist"
    fail=1
else
    found_ios=0
    while IFS= read -r p; do
        plist=$(security cms -D -i "$p" 2>/dev/null || true)
        is_ios=0
        sed -n '/<key>Platform<\/key>/,/<\/array>/p' <<<"$plist" | grep -q '<string>iOS</string>' && is_ios=1
        has_devices=0
        grep -q '<key>ProvisionedDevices</key>' <<<"$plist" && has_devices=1
        if (( is_ios && ! has_devices )); then
            name=$(grep -A1 '<key>Name</key>' <<<"$plist" | tail -1 | sed -E 's,.*<string>(.*)</string>.*,\1,')
            [[ -z "$name" ]] && name="$(basename "$p")"
            app_id=$(grep -A1 '<key>application-identifier</key>' <<<"$plist" | tail -1 | sed -E 's,.*<string>[A-Z0-9]+\.(.*)</string>.*,\1,')
            if [[ -n "$BUNDLE_ID" ]]; then
                if [[ "$app_id" == "$BUNDLE_ID" || "$app_id" == "*" ]]; then
                    green "  ✓ $name — covers $BUNDLE_ID"
                    found_ios=1
                fi
            else
                green "  ✓ $name (covers $app_id)"
                found_ios=1
            fi
        fi
    # iOS profiles use .mobileprovision; macOS uses .provisionprofile.
    done < <(find "$profile_dir" -type f \( -name '*.mobileprovision' -o -name '*.provisionprofile' \) 2>/dev/null)

    if (( ! found_ios )); then
        if [[ -n "$BUNDLE_ID" ]]; then
            red "  ✗ no iOS App Store profile covering $BUNDLE_ID"
        else
            yellow "  ! no iOS App Store profile (Platform=iOS, no ProvisionedDevices) found"
        fi
        red "    create a 'iOS App Store' profile in developer.apple.com → Profiles."
        fail=1
    fi
fi

echo
echo "==> Checking required tools"
for tool in xcrun xcodebuild /usr/libexec/PlistBuddy; do
    if command -v "$tool" >/dev/null 2>&1 || [[ -x "$tool" ]]; then
        green "  ✓ $tool"
    else
        red "  ✗ $tool not found"
        fail=1
    fi
done

# xcodegen only required if project.yml exists
if [[ -f "$PROJECT_DIR/project.yml" ]]; then
    if command -v xcodegen >/dev/null 2>&1; then
        green "  ✓ xcodegen ($PROJECT_DIR/project.yml present)"
    else
        red "  ✗ xcodegen not found but project.yml exists"
        red "    install with: brew install xcodegen"
        fail=1
    fi
fi

# altool keychain entry — only warn, not fail (the export upload path
# uses the user's Xcode session, only altool retries hit the keychain)
echo
echo "==> Checking altool app-specific password keychain entry"
if security find-internet-password -s "appleid.apple.com" -a "$(whoami)" >/dev/null 2>&1 \
   || security find-generic-password -l "ASC_APP_SPECIFIC_PASSWORD" >/dev/null 2>&1; then
    green "  ✓ an Apple ID / app-specific password entry exists"
else
    yellow "  ! no Apple ID / app-specific password in keychain"
    yellow "    not strictly required if you upload via xcodebuild -exportArchive,"
    yellow "    but altool retries will fail. Add one with:"
    yellow "    xcrun altool --store-password-in-keychain-item ASC_APP_SPECIFIC_PASSWORD \\"
    yellow "      -u YOUR_APPLE_ID -p YOUR_APP_SPECIFIC_PASSWORD"
fi

echo
if (( fail )); then
    red "Preflight FAILED."
    exit 1
fi
green "Preflight passed."
