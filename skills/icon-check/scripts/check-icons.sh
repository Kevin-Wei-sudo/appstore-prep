#!/usr/bin/env bash
#
# Validate an AppIcon.appiconset directory before App Store submission.
#
# Catches: missing slots, pixel-dimension mismatches, alpha channels on
# the 1024 marketing icon, and non-full-bleed designs that produce visible
# white borders on the iOS home screen.
#
# Usage:
#   check-icons.sh path/to/AppIcon.appiconset
#
# Exits 0 if all checks pass, 1 if any hard check fails.
set -euo pipefail

ICONSET="${1:-}"
if [[ -z "$ICONSET" || ! -d "$ICONSET" ]]; then
    echo "Usage: $0 <path/to/AppIcon.appiconset>" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAMPLE_RGB="$SCRIPT_DIR/sample-rgb.swift"

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

fail=0
warn=0

# iOS required pixel sizes (for ASCONNECT validation).
ios_required_sizes=(20 29 40 58 60 76 80 87 120 152 167 180 1024)

echo "==> Validating $ICONSET"

# 1. Required slots and pixel dimensions
echo
echo "--- Required size slots"
for sz in "${ios_required_sizes[@]}"; do
    matches=$(find "$ICONSET" -type f -name "*${sz}.png" | head -1)
    if [[ -z "$matches" ]]; then
        red "  ✗ no PNG found for ${sz}px slot"
        fail=1
    else
        actual_w=$(sips -g pixelWidth "$matches" 2>/dev/null | awk '/pixelWidth/ {print $2}')
        actual_h=$(sips -g pixelHeight "$matches" 2>/dev/null | awk '/pixelHeight/ {print $2}')
        if [[ "$actual_w" != "$sz" || "$actual_h" != "$sz" ]]; then
            red "  ✗ $(basename "$matches") is ${actual_w}×${actual_h}, expected ${sz}×${sz}"
            fail=1
        else
            green "  ✓ ${sz}px → $(basename "$matches") (${actual_w}×${actual_h})"
        fi
    fi
done

# 2. Alpha on 1024
echo
echo "--- Alpha channel (1024 must be opaque for iOS marketing icon)"
icon_1024=$(find "$ICONSET" -type f -name "*1024.png" | head -1)
if [[ -n "$icon_1024" ]]; then
    has_alpha=$(sips -g hasAlpha "$icon_1024" 2>/dev/null | awk '/hasAlpha/ {print $2}')
    if [[ "$has_alpha" == "yes" ]]; then
        red "  ✗ $(basename "$icon_1024") has an alpha channel — strip it before uploading"
        red "     fix: sips -s format png --setProperty hasAlpha no $icon_1024 --out ${icon_1024%.png}-opaque.png"
        fail=1
    else
        green "  ✓ no alpha channel on 1024"
    fi
fi

# 3. Full-bleed corner sample (white-border detector)
echo
echo "--- Full-bleed check (white-border detector)"
if [[ -n "$icon_1024" ]] && command -v swift >/dev/null 2>&1; then
    # 8x8 top-left patch
    tl=$(swift "$SAMPLE_RGB" "$icon_1024" 0 0 8 8 2>/dev/null || echo "nan nan nan")
    # 8x8 center patch
    cx=$(( 1024 / 2 - 4 ))
    center=$(swift "$SAMPLE_RGB" "$icon_1024" "$cx" "$cx" 8 8 2>/dev/null || echo "nan nan nan")

    echo "    top-left avg RGB:  $tl"
    echo "    center   avg RGB:  $center"

    read tl_r tl_g tl_b <<<"$tl"
    read c_r c_g c_b <<<"$center"

    if [[ "$tl_r" == "nan" ]]; then
        yellow "  ! could not sample (Swift available? $(command -v swift))"
        warn=1
    elif (( tl_r > 240 && tl_g > 240 && tl_b > 240 )); then
        if (( c_r > 240 && c_g > 240 && c_b > 240 )); then
            yellow "  ! corner and center are both near-white — could be a white-themed icon. Visually verify."
            warn=1
        else
            red "  ✗ top-left corner is near-white (RGB $tl_r,$tl_g,$tl_b) but center is not."
            red "     This is the classic white-border bug — your icon was designed with built-in"
            red "     rounded corners. iOS applies its squircle mask on top, leaving white pixels"
            red "     visible at the corners. Re-export the 1024 full-bleed (no designed corners)"
            red "     and regenerate smaller sizes via: sips -z N N AppIcon-1024.png --out AppIcon-N.png"
            fail=1
        fi
    else
        green "  ✓ top-left corner is not white (RGB $tl_r,$tl_g,$tl_b)"
    fi
elif ! command -v swift >/dev/null 2>&1; then
    yellow "  ! swift not found — install Xcode Command Line Tools (xcode-select --install) to enable this check"
    warn=1
fi

# 4. Cross-size corner consistency
echo
echo "--- Cross-size corner consistency"
if command -v swift >/dev/null 2>&1; then
    ref_rgb=""
    ref_name=""
    divergent=()
    for png in "$ICONSET"/*.png; do
        [[ -f "$png" ]] || continue
        # 4×4 top-left patch
        rgb=$(swift "$SAMPLE_RGB" "$png" 0 0 4 4 2>/dev/null || echo "")
        [[ -z "$rgb" ]] && continue
        if [[ -z "$ref_rgb" ]]; then
            ref_rgb="$rgb"
            ref_name="$(basename "$png")"
            continue
        fi
        read r1 g1 b1 <<<"$ref_rgb"
        read r2 g2 b2 <<<"$rgb"
        dr=$(( r1 > r2 ? r1 - r2 : r2 - r1 ))
        dg=$(( g1 > g2 ? g1 - g2 : g2 - g1 ))
        db=$(( b1 > b2 ? b1 - b2 : b2 - b1 ))
        max_diff=$(( dr > dg ? dr : dg ))
        max_diff=$(( max_diff > db ? max_diff : db ))
        if (( max_diff > 30 )); then
            divergent+=("$(basename "$png") corner=($r2,$g2,$b2) diff=$max_diff")
        fi
    done

    if [[ -n "$ref_name" ]]; then
        echo "    reference: $ref_name corner=($ref_rgb)"
        if (( ${#divergent[@]} )); then
            for d in "${divergent[@]}"; do
                yellow "  ! $d — possibly hand-edited"
            done
            warn=1
        else
            green "  ✓ all sizes share the same corner color (within tolerance)"
        fi
    fi
fi

echo
if (( fail )); then
    red "icon-check FAILED. Fix the items above before submitting."
    exit 1
fi
if (( warn )); then
    yellow "icon-check passed with warnings."
    exit 0
fi
green "icon-check passed clean."
