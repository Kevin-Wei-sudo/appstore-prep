#!/usr/bin/env bash
#
# Archive an iOS app, sign it for App Store distribution, and upload to ASC.
#
# Wraps the manual flow:
#   xcodegen generate                   (if --regenerate-project)
#   xcodebuild archive                  (manual signing)
#   xcodebuild -exportArchive           (destination=upload)
#
# What this script does that hand-rolled commands miss:
#   - Generates a correct ExportOptions.plist if not supplied
#   - Detects "train version closed" → tells you to bump MARKETING_VERSION
#   - Detects "build N already used" → tells you to bump CFBundleVersion
#   - Optionally bumps CFBundleVersion in project.yml or Info.plist before archiving
#
# Usage: see --help.
set -euo pipefail

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

WORKSPACE=""
PROJECT_FILE=""
SCHEME=""
BUNDLE_ID=""
TEAM_ID=""
DIST_IDENTITY=""
PROFILE_NAME=""
ARCHIVE_PATH=""
EXPORT_PATH=""
EXPORT_OPTIONS=""
REGENERATE_DIR=""
BUMP_BUILD_FROM=""

usage() {
    cat <<'EOF' >&2
Usage: archive-and-upload.sh [options]

Required (one of --workspace or --project):
  --workspace PATH                .xcworkspace path
  --project PATH                  .xcodeproj path (if no workspace)
  --scheme NAME                   build scheme
  --bundle-id ID                  e.g. io.example.myapp
  --team-id ID                    Apple developer team id (10 chars)
  --distribution-identity NAME    e.g. "Apple Distribution: Foo (ABCDE12345)"
  --profile-name NAME             provisioning profile NAME (the field inside the .provisionprofile, NOT filename)
  --archive-path PATH             where to write the .xcarchive
  --export-path PATH              where to write the exported IPA + upload logs

Optional:
  --export-options PATH           pre-existing ExportOptions.plist (skip generation)
  --regenerate-project DIR        run `xcodegen generate` in DIR before archiving
  --bump-build-from FILE          increment CFBundleVersion in project.yml or Info.plist
  -h, --help                      show this help

After upload, the build appears in App Store Connect → TestFlight → Builds
within 5–15 minutes (status: Processing → Ready to Submit).
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workspace) WORKSPACE="$2"; shift 2 ;;
        --project) PROJECT_FILE="$2"; shift 2 ;;
        --scheme) SCHEME="$2"; shift 2 ;;
        --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
        --team-id) TEAM_ID="$2"; shift 2 ;;
        --distribution-identity) DIST_IDENTITY="$2"; shift 2 ;;
        --profile-name) PROFILE_NAME="$2"; shift 2 ;;
        --archive-path) ARCHIVE_PATH="$2"; shift 2 ;;
        --export-path) EXPORT_PATH="$2"; shift 2 ;;
        --export-options) EXPORT_OPTIONS="$2"; shift 2 ;;
        --regenerate-project) REGENERATE_DIR="$2"; shift 2 ;;
        --bump-build-from) BUMP_BUILD_FROM="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

missing=()
[[ -z "$WORKSPACE" && -z "$PROJECT_FILE" ]] && missing+=("--workspace or --project")
[[ -z "$SCHEME" ]] && missing+=(--scheme)
[[ -z "$BUNDLE_ID" ]] && missing+=(--bundle-id)
[[ -z "$TEAM_ID" ]] && missing+=(--team-id)
[[ -z "$DIST_IDENTITY" ]] && missing+=(--distribution-identity)
[[ -z "$PROFILE_NAME" ]] && missing+=(--profile-name)
[[ -z "$ARCHIVE_PATH" ]] && missing+=(--archive-path)
[[ -z "$EXPORT_PATH" ]] && missing+=(--export-path)
if (( ${#missing[@]} )); then
    echo "Missing required arguments: ${missing[*]}" >&2
    usage
    exit 1
fi

# ---- Optional: bump build number ----
if [[ -n "$BUMP_BUILD_FROM" ]]; then
    if [[ ! -f "$BUMP_BUILD_FROM" ]]; then
        red "File not found for --bump-build-from: $BUMP_BUILD_FROM"
        exit 1
    fi
    case "$BUMP_BUILD_FROM" in
        *.yml|*.yaml)
            current=$(awk -F'"' '/CURRENT_PROJECT_VERSION:/ {print $2}' "$BUMP_BUILD_FROM")
            if [[ -z "$current" ]]; then
                red "Could not find CURRENT_PROJECT_VERSION in $BUMP_BUILD_FROM"
                exit 1
            fi
            next=$((current + 1))
            sed -i '' "s/CURRENT_PROJECT_VERSION: \"$current\"/CURRENT_PROJECT_VERSION: \"$next\"/" "$BUMP_BUILD_FROM"
            green "==> Bumped build number $current → $next in $BUMP_BUILD_FROM"
            ;;
        *Info.plist|*.plist)
            current=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUMP_BUILD_FROM")
            next=$((current + 1))
            /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $next" "$BUMP_BUILD_FROM"
            green "==> Bumped CFBundleVersion $current → $next in $BUMP_BUILD_FROM"
            ;;
        *)
            red "Don't know how to bump build in $BUMP_BUILD_FROM (must be .yml or .plist)"
            exit 1
            ;;
    esac
fi

# ---- Optional: regenerate Xcode project from XcodeGen ----
if [[ -n "$REGENERATE_DIR" ]]; then
    echo "==> Regenerating Xcode project via xcodegen ($REGENERATE_DIR)"
    (cd "$REGENERATE_DIR" && xcodegen generate)
fi

# ---- Step 1: archive ----
mkdir -p "$(dirname "$ARCHIVE_PATH")"
rm -rf "$ARCHIVE_PATH"

build_target_args=()
if [[ -n "$WORKSPACE" ]]; then
    build_target_args+=(-workspace "$WORKSPACE")
else
    build_target_args+=(-project "$PROJECT_FILE")
fi

echo "==> Archiving (manual signing)"
xcodebuild archive \
    "${build_target_args[@]}" \
    -scheme "$SCHEME" \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$DIST_IDENTITY" \
    PROVISIONING_PROFILE_SPECIFIER="$PROFILE_NAME" \
    DEVELOPMENT_TEAM="$TEAM_ID"

if [[ ! -d "$ARCHIVE_PATH" ]]; then
    red "Archive failed — $ARCHIVE_PATH not produced"
    exit 1
fi
green "==> Archive succeeded: $ARCHIVE_PATH"

# ---- Step 2: ExportOptions.plist ----
if [[ -z "$EXPORT_OPTIONS" ]]; then
    EXPORT_OPTIONS="$EXPORT_PATH/ExportOptions.plist"
    mkdir -p "$EXPORT_PATH"
    cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>$BUNDLE_ID</key>
        <string>$PROFILE_NAME</string>
    </dict>
    <key>signingCertificate</key>
    <string>Apple Distribution</string>
    <key>destination</key>
    <string>upload</string>
</dict>
</plist>
EOF
    green "==> Generated $EXPORT_OPTIONS"
fi

# ---- Step 3: export + upload ----
mkdir -p "$EXPORT_PATH"
log_file="$EXPORT_PATH/upload.log"

echo "==> Exporting + uploading (xcodebuild -exportArchive, destination=upload)"
set +e
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" 2>&1 | tee "$log_file"
exit_code=${PIPESTATUS[0]}
set -e

# ---- Step 4: interpret outcome ----
echo
if (( exit_code == 0 )) && grep -q 'EXPORT SUCCEEDED' "$log_file"; then
    green "==> Upload succeeded. Build will appear in App Store Connect → TestFlight → Builds in 5–15 min."
    exit 0
fi

# Diagnose known failures
if grep -q "train version '.*' is closed" "$log_file"; then
    bad_train=$(grep -oE "train version '[^']+'" "$log_file" | head -1 | tr -d "'" | sed 's/train version //')
    red "==> Train closed for $bad_train."
    red "    A build for this MARKETING_VERSION was already approved. Bump it (e.g. patch+1)"
    red "    in your project.yml or Info.plist, regenerate the Xcode project, and re-run."
    exit 1
fi

if grep -qE "version has already been used|build number .* has already been used|already exists" "$log_file"; then
    red "==> Build number already used for this train."
    red "    Bump CFBundleVersion (re-run with --bump-build-from project.yml)."
    exit 1
fi

if grep -q "No profile matching" "$log_file"; then
    red "==> Profile name not found. The --profile-name flag must match the 'Name' field"
    red "    inside the .provisionprofile, not the filename. Inspect with:"
    red "      security cms -D -i ~/Library/MobileDevice/Provisioning\\ Profiles/<file> | grep -A1 '<key>Name</key>'"
    exit 1
fi

if grep -q "errSecInternalComponent" "$log_file"; then
    red "==> errSecInternalComponent: keychain access denied. Try:"
    red "      security unlock-keychain ~/Library/Keychains/login.keychain-db"
    exit 1
fi

red "==> Upload failed (exit $exit_code). Inspect $log_file for details."
exit $exit_code
