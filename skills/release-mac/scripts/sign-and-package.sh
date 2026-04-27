#!/usr/bin/env bash
#
# Re-sign a built .app for Mac App Store distribution and wrap it in a signed .pkg.
#
# Assumes the .app already exists (Xcode archive, SwiftPM build, etc) and is
# *not* yet signed for distribution (ad-hoc / development signing is fine).
#
# What this script handles that hand-rolled signing usually misses:
#   - embeds the Mac App Store provisioning profile inside the bundle
#   - patches SwiftPM nested .bundle Info.plists that lack CFBundleIdentifier
#     (App Store Connect error 409)
#   - signs nested frameworks/bundles before the outer .app (correct order)
#   - uses --options runtime --timestamp on every signature
#   - signs the final .pkg with the 3rd Party Mac Developer Installer cert
#     (NOT Developer ID Installer — different cert, different distribution path)
#
# Usage:
#   sign-and-package.sh \
#     --app /path/to/MyApp.app \
#     --entitlements /path/to/MyApp.entitlements \
#     --profile /path/to/MyApp_Mac_App_Store.provisionprofile \
#     --distribution-identity "Apple Distribution: Name (TEAMID)" \
#     --installer-identity "3rd Party Mac Developer Installer: Name (TEAMID)" \
#     --output /path/to/MyApp.pkg
set -euo pipefail

usage() {
    cat <<'EOF' >&2
Usage: sign-and-package.sh [options]

Required:
  --app PATH                          Path to the .app bundle to sign
  --entitlements PATH                 Path to the .entitlements file
  --profile PATH                      Path to the Mac App Store .provisionprofile
  --distribution-identity NAME        e.g. "Apple Distribution: Foo (ABCDE12345)"
  --installer-identity NAME           e.g. "3rd Party Mac Developer Installer: Foo (ABCDE12345)"
  --output PATH                       Output .pkg path

Optional:
  --skip-nested-patch                 Don't patch nested-bundle Info.plists (default: patch)
  -h, --help                          Show this message
EOF
}

APP_BUNDLE=""
ENTITLEMENTS=""
PROFILE_PATH=""
DISTRIBUTION_IDENTITY=""
INSTALLER_IDENTITY=""
PKG_PATH=""
PATCH_NESTED=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP_BUNDLE="$2"; shift 2 ;;
        --entitlements) ENTITLEMENTS="$2"; shift 2 ;;
        --profile) PROFILE_PATH="$2"; shift 2 ;;
        --distribution-identity) DISTRIBUTION_IDENTITY="$2"; shift 2 ;;
        --installer-identity) INSTALLER_IDENTITY="$2"; shift 2 ;;
        --output) PKG_PATH="$2"; shift 2 ;;
        --skip-nested-patch) PATCH_NESTED=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

missing=()
[[ -z "$APP_BUNDLE" ]] && missing+=(--app)
[[ -z "$ENTITLEMENTS" ]] && missing+=(--entitlements)
[[ -z "$PROFILE_PATH" ]] && missing+=(--profile)
[[ -z "$DISTRIBUTION_IDENTITY" ]] && missing+=(--distribution-identity)
[[ -z "$INSTALLER_IDENTITY" ]] && missing+=(--installer-identity)
[[ -z "$PKG_PATH" ]] && missing+=(--output)
if (( ${#missing[@]} )); then
    echo "Missing required arguments: ${missing[*]}" >&2
    usage
    exit 1
fi

[[ -d "$APP_BUNDLE" ]] || { echo "App bundle not found: $APP_BUNDLE" >&2; exit 1; }
[[ -f "$ENTITLEMENTS" ]] || { echo "Entitlements not found: $ENTITLEMENTS" >&2; exit 1; }
[[ -f "$PROFILE_PATH" ]] || { echo "Provisioning profile not found: $PROFILE_PATH" >&2; exit 1; }

echo "==> Step 1/5: Embedding provisioning profile"
cp "$PROFILE_PATH" "$APP_BUNDLE/Contents/embedded.provisionprofile"

echo "==> Step 2/5: Scrubbing extended attributes"
xattr -cr "$APP_BUNDLE"

if (( PATCH_NESTED )); then
    echo "==> Step 3/5: Patching nested .bundle Info.plists (SwiftPM 409 fix)"
    MAIN_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")
    MAIN_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")
    MAIN_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist")

    # SwiftPM bundles on macOS are shallow (Info.plist at bundle root); also handle
    # the regular Contents/Info.plist layout.
    while IFS= read -r nested_plist; do
        nested_bundle_dir="$(dirname "$nested_plist")"
        while [[ "$nested_bundle_dir" != "$APP_BUNDLE" && "$nested_bundle_dir" != *.bundle ]]; do
            nested_bundle_dir="$(dirname "$nested_bundle_dir")"
        done
        nested_name="$(basename "$nested_bundle_dir" .bundle)"
        # Underscores aren't valid in reverse-DNS — replace with hyphens for stability.
        nested_id="$MAIN_BUNDLE_ID.resources.${nested_name//_/-}"
        echo "    patching $nested_bundle_dir → $nested_id"
        /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $nested_id" "$nested_plist" 2>/dev/null \
            || /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $nested_id" "$nested_plist"
        /usr/libexec/PlistBuddy -c "Add :CFBundleName string $nested_name" "$nested_plist" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string BNDL" "$nested_plist" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $MAIN_VERSION" "$nested_plist" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $MAIN_BUILD" "$nested_plist" 2>/dev/null || true
    done < <(
        { find "$APP_BUNDLE" -path '*.bundle/Info.plist' 2>/dev/null
          find "$APP_BUNDLE" -path '*.bundle/Contents/Info.plist' 2>/dev/null; }
    )
else
    echo "==> Step 3/5: SKIPPED (--skip-nested-patch)"
fi

echo "==> Step 4/5: Codesigning (nested bundles first, then outer .app)"
# Sign frameworks/embedded apps/xpc/dylibs first, deepest-first via reverse sort.
while IFS= read -r nested; do
    [[ -z "$nested" ]] && continue
    codesign --force --sign "$DISTRIBUTION_IDENTITY" \
             --options runtime \
             --timestamp \
             "$nested"
done < <(find "$APP_BUNDLE" \( -name "*.framework" -o -name "*.app" -o -name "*.xpc" -o -name "*.dylib" \) -type d -mindepth 1 2>/dev/null | sort -r)

codesign --force --sign "$DISTRIBUTION_IDENTITY" \
         --entitlements "$ENTITLEMENTS" \
         --options runtime \
         --timestamp \
         "$APP_BUNDLE"

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "==> Step 5/5: Building signed installer .pkg"
rm -f "$PKG_PATH"
productbuild --component "$APP_BUNDLE" /Applications \
             --sign "$INSTALLER_IDENTITY" \
             "$PKG_PATH"
pkgutil --check-signature "$PKG_PATH"

echo
echo "==> Done: $PKG_PATH"
echo
echo "Upload with one of:"
echo "  open -a Transporter \"$PKG_PATH\""
echo "  xcrun altool --upload-app -f \"$PKG_PATH\" -t macos -u APPLE_ID -p @keychain:ASC_APP_SPECIFIC_PASSWORD"
