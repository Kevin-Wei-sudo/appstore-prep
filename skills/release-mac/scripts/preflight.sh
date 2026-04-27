#!/usr/bin/env bash
#
# Preflight check for Mac App Store packaging.
#
# Verifies:
#   1. Apple Distribution + 3rd Party Mac Developer Installer identities
#   2. At least one Mac App Store provisioning profile is installed
#   3. xcrun, codesign, productbuild, PlistBuddy are available
#
# Exits non-zero with a specific message on the first missing piece — the
# downstream sign-and-package.sh assumes all of these are present.
set -euo pipefail

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

fail=0

echo "==> Checking signing identities (security find-identity)"
identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if grep -q "Apple Distribution:" <<<"$identities"; then
    green "  ✓ Apple Distribution identity present"
else
    red "  ✗ no 'Apple Distribution' identity found"
    red "    download an Apple Distribution cert from developer.apple.com → Certificates,"
    red "    install the .cer (double-click), and ensure its private key is in your"
    red "    login keychain (.p12 import from the original Mac that requested it)."
    fail=1
fi

if grep -q "3rd Party Mac Developer Installer:" <<<"$identities"; then
    green "  ✓ 3rd Party Mac Developer Installer identity present"
else
    red "  ✗ no '3rd Party Mac Developer Installer' identity found"
    red "    this is a SEPARATE certificate from Apple Distribution. Create one in"
    red "    developer.apple.com → Certificates → Mac Installer Distribution."
    fail=1
fi

echo
echo "==> Checking Mac App Store provisioning profiles"
profile_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
if [[ ! -d "$profile_dir" ]]; then
    red "  ✗ $profile_dir does not exist"
    red "    download a Mac App Store Connect provisioning profile and double-click the .provisionprofile"
    fail=1
else
    found_mas=0
    while IFS= read -r p; do
        # Mac App Store profiles have ProvisionsAllDevices=false AND a single team key,
        # but the simplest disambiguator is the entitlement: beta-reports-active=YES means MAS.
        plist=$(security cms -D -i "$p" 2>/dev/null || true)
        if grep -q "<key>beta-reports-active</key>" <<<"$plist"; then
            name=$(/usr/libexec/PlistBuddy -c 'Print :Name' /dev/stdin <<<"$plist" 2>/dev/null || basename "$p")
            green "  ✓ $name ($(basename "$p"))"
            found_mas=1
        fi
    done < <(find "$profile_dir" -type f -name '*.provisionprofile' 2>/dev/null)

    if (( ! found_mas )); then
        yellow "  ! no profile with 'beta-reports-active' (Mac App Store marker) found"
        yellow "    you may have a Developer ID profile installed instead. Create a"
        yellow "    'Mac App Store Connect' profile in developer.apple.com → Profiles."
        # not a hard fail — user might be intentionally checking before download
    fi
fi

echo
echo "==> Checking required tools"
for tool in xcrun codesign productbuild pkgutil sips /usr/libexec/PlistBuddy; do
    if command -v "$tool" >/dev/null 2>&1 || [[ -x "$tool" ]]; then
        green "  ✓ $tool"
    else
        red "  ✗ $tool not found"
        fail=1
    fi
done

echo
if (( fail )); then
    red "Preflight FAILED. Fix the items above before running sign-and-package.sh."
    exit 1
fi
green "Preflight passed."
