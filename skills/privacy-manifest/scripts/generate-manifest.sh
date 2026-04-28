#!/usr/bin/env bash
#
# Generate a starter PrivacyInfo.xcprivacy by scanning a Swift / Obj-C
# source tree for Required Reason API usage and emitting matching
# NSPrivacyAccessedAPIType blocks.
#
# Output goes to stdout — redirect to PrivacyInfo.xcprivacy.
#
# Usage:
#   ./generate-manifest.sh /path/to/ios/MyApp/Sources > PrivacyInfo.xcprivacy
#
# After generation, you still need to:
#   1. Add the file to the app target → Build Phases → Copy Bundle Resources
#   2. Set NSPrivacyTracking=true if you integrate any tracking SDK
#   3. Fill in NSPrivacyTrackingDomains with the analytics endpoints
#   4. Add NSPrivacyCollectedDataTypes for anything you collect
set -euo pipefail

DIR="${1:-}"
if [[ -z "$DIR" || ! -d "$DIR" ]]; then
    echo "Usage: $0 <swift-source-dir> > PrivacyInfo.xcprivacy" >&2
    exit 2
fi

# Each row: <regex>|<category>|<reason-code>|<reason-explanation>
APIS=(
    "UserDefaults|NSPrivacyAccessedAPICategoryUserDefaults|CA92.1|Access info from same app, per documentation"
    "\\.systemUptime|NSPrivacyAccessedAPICategorySystemBootTime|35F9.1|Measure time on-device"
    "\\.creationDate|NSPrivacyAccessedAPICategoryFileTimestamp|C617.1|Inside app or group container"
    "\\.modificationDate|NSPrivacyAccessedAPICategoryFileTimestamp|C617.1|Inside app or group container"
    "contentModificationDateKey|NSPrivacyAccessedAPICategoryFileTimestamp|C617.1|Inside app or group container"
    "creationDateKey|NSPrivacyAccessedAPICategoryFileTimestamp|C617.1|Inside app or group container"
    "attributesOfItem|NSPrivacyAccessedAPICategoryFileTimestamp|C617.1|Inside app or group container"
    "volumeAvailableCapacity|NSPrivacyAccessedAPICategoryDiskSpace|E174.1|Inside app or group container"
    "activeInputModes|NSPrivacyAccessedAPICategoryActiveKeyboards|54BD.1|Customize UI for active keyboard"
)

scan_files=$(find "$DIR" -type f \( -name '*.swift' -o -name '*.m' -o -name '*.mm' \) \
    ! -path '*/Pods/*' ! -path '*/DerivedData/*' ! -path '*/build/*' ! -path '*/.build/*' 2>/dev/null)

# Detect which categories to emit (collapse duplicates from multiple regexes
# pointing to the same category)
declare_emit=""
emit_reason=""
add_emit() {
    local cat="$1" code="$2"
    if [[ "$declare_emit" != *"|$cat|"* ]]; then
        declare_emit="$declare_emit|$cat|"
        # Remember the first reason code we saw for this category
        if [[ -z "${cat_codes:-}" ]]; then
            cat_codes="$cat:$code"
        else
            cat_codes="$cat_codes;$cat:$code"
        fi
    fi
}

for entry in "${APIS[@]}"; do
    regex="${entry%%|*}"
    rest="${entry#*|}"
    cat="${rest%%|*}"
    rest="${rest#*|}"
    code="${rest%%|*}"
    if echo "$scan_files" | xargs grep -lE "$regex" 2>/dev/null | head -1 | grep -q .; then
        add_emit "$cat" "$code"
    fi
done

# Emit XML
cat <<'XML_HEADER'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key>
    <false/>
    <!-- Set to <true/> if you integrate AppsFlyer, Meta SDK, or any
         cross-app tracking. Then declare the domains in NSPrivacyTrackingDomains. -->
    <key>NSPrivacyTrackingDomains</key>
    <array>
        <!-- e.g. -->
        <!-- <string>impression.appsflyer.com</string> -->
        <!-- <string>graph.facebook.com</string> -->
    </array>
    <key>NSPrivacyCollectedDataTypes</key>
    <array>
        <!-- Add an entry per data type you collect. Apple has a fixed list:
             https://developer.apple.com/documentation/bundleresources/privacy_manifest_files/describing_data_use_in_privacy_manifests
             Most app + analytics combos need at minimum:
               - NSPrivacyCollectedDataTypeDeviceID  (linked, for analytics)
               - NSPrivacyCollectedDataTypeProductInteraction (linked, for analytics) -->
    </array>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
XML_HEADER

# Emit one block per detected category
if [[ -n "${cat_codes:-}" ]]; then
    IFS=';' read -ra entries <<<"$cat_codes"
    for e in "${entries[@]}"; do
        cat="${e%%:*}"
        code="${e#*:}"
        cat <<XML_BLOCK
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>$cat</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>$code</string>
            </array>
        </dict>
XML_BLOCK
    done
fi

cat <<'XML_FOOTER'
    </array>
</dict>
</plist>
XML_FOOTER
