#!/usr/bin/env bash
#
# Validate App Store screenshot pixel sizes / counts against Apple's
# current device-size matrix.
#
# Reads a fastlane-style screenshots directory:
#
#   fastlane/screenshots/
#     en-US/
#       iPhone 6.9 Display/
#         01.png
#         02.png
#       iPhone 6.7 Display/
#       iPad 13 Display/
#     zh-Hans/
#       ...
#
# The folder names are flexible — we match on substring (e.g. "6.9", "6.7",
# "13", "12.9", "6.5"). Pixel sizes are validated against Apple's expected
# values per device family.
set -euo pipefail

DIR="${1:-}"
if [[ -z "$DIR" || ! -d "$DIR" ]]; then
    echo "Usage: $0 <screenshots-dir>" >&2
    exit 2
fi

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }

fail=0

# Device family → list of acceptable WxH (any orientation).
# Apple accepts both portrait and landscape; we test both.
check_size() {
    local family="$1" w="$2" h="$3"
    case "$family" in
        "6.9")
            # iPhone 16/17 Pro Max
            [[ "$w $h" == "1320 2868" || "$w $h" == "2868 1320" ]] && return 0
            ;;
        "6.7")
            # iPhone 14/15 Pro Max
            [[ "$w $h" == "1290 2796" || "$w $h" == "2796 1290" \
            || "$w $h" == "1284 2778" || "$w $h" == "2778 1284" ]] && return 0
            ;;
        "6.5")
            # iPhone 11 Pro Max etc — optional in 2024+ but still accepted
            [[ "$w $h" == "1242 2688" || "$w $h" == "2688 1242" \
            || "$w $h" == "1284 2778" || "$w $h" == "2778 1284" ]] && return 0
            ;;
        "5.5")
            # legacy iPhone Plus, still accepted
            [[ "$w $h" == "1242 2208" || "$w $h" == "2208 1242" ]] && return 0
            ;;
        "13"|"12.9")
            # iPad Pro 12.9 / 13
            [[ "$w $h" == "2048 2732" || "$w $h" == "2732 2048" \
            || "$w $h" == "2064 2752" || "$w $h" == "2752 2064" ]] && return 0
            ;;
        "11")
            # iPad Pro 11
            [[ "$w $h" == "1668 2388" || "$w $h" == "2388 1668" ]] && return 0
            ;;
    esac
    return 1
}

family_from_folder() {
    local folder="$1"
    local lf
    lf=$(tr '[:upper:]' '[:lower:]' <<<"$folder")
    case "$lf" in
        *6.9*) echo "6.9" ;;
        *6.7*) echo "6.7" ;;
        *6.5*) echo "6.5" ;;
        *5.5*) echo "5.5" ;;
        *12.9*) echo "12.9" ;;
        *13*) echo "13" ;;
        *11*) echo "11" ;;
        *) echo "" ;;
    esac
}

audit_locale() {
    local locale_dir="$1"
    local locale
    locale=$(basename "$locale_dir")
    bold "==> Locale: $locale"

    local saw_required_iphone=0

    for device_dir in "$locale_dir"/*/; do
        [[ -d "$device_dir" ]] || continue
        local folder=$(basename "$device_dir")
        local family
        family=$(family_from_folder "$folder")
        if [[ -z "$family" ]]; then
            yellow "  ! $folder: device family not recognized (skipping)"
            continue
        fi

        # Count + validate
        local count=0 bad=0
        local img_files=()
        while IFS= read -r f; do
            img_files+=("$f")
        done < <(find "$device_dir" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) | sort)

        count=${#img_files[@]}
        if (( count == 0 )); then
            red "  ✗ $folder: empty"
            fail=1
            continue
        fi
        if (( count < 3 )); then
            red "  ✗ $folder: $count screenshot(s) — Apple requires at least 3"
            fail=1
        elif (( count > 10 )); then
            red "  ✗ $folder: $count screenshot(s) — Apple allows max 10"
            fail=1
        fi

        for f in "${img_files[@]}"; do
            local w h
            w=$(sips -g pixelWidth "$f" 2>/dev/null | awk '/pixelWidth/ {print $2}')
            h=$(sips -g pixelHeight "$f" 2>/dev/null | awk '/pixelHeight/ {print $2}')
            if ! check_size "$family" "$w" "$h"; then
                red "    ✗ $(basename "$f"): ${w}×${h} doesn't match $family\" device family"
                bad=1
                fail=1
            fi
            # alpha on JPEG is fatal
            local hasAlpha
            hasAlpha=$(sips -g hasAlpha "$f" 2>/dev/null | awk '/hasAlpha/ {print $2}')
            local lf
            lf=$(tr '[:upper:]' '[:lower:]' <<<"$f")
            if [[ "$hasAlpha" == "yes" && "$lf" == *.jp*g ]]; then
                red "    ✗ $(basename "$f"): JPEG has alpha channel — Apple rejects"
                fail=1
            fi
        done

        if (( ! bad )); then
            green "  ✓ $folder: $count screenshots, all ${family}\" sized correctly"
        fi

        case "$family" in
            "6.9"|"6.7") saw_required_iphone=1 ;;
        esac
    done

    if (( ! saw_required_iphone )); then
        red "  ✗ no iPhone 6.9\" or 6.7\" screenshots found — at least one is required for new iPhone submissions in 2026"
        fail=1
    fi
}

for d in "$DIR"/*/; do
    [[ -d "$d" ]] || continue
    audit_locale "${d%/}"
    echo
done

if (( fail )); then
    red "check-screenshots FAILED."
    exit 1
fi
green "check-screenshots passed."
