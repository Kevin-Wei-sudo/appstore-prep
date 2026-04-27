#!/usr/bin/env bash
#
# Audit App Store metadata against Apple's character limits and ASO best
# practices. Reads a fastlane-style directory:
#
#   fastlane/metadata/
#     en-US/
#       name.txt
#       subtitle.txt
#       keywords.txt
#       description.txt
#       promotional_text.txt
#       release_notes.txt
#     zh-Hans/
#       ...
#
# Exits 0 if no hard-limit violations, 1 otherwise. Warnings (best-practice
# advice) print but don't fail the run.
set -euo pipefail

DIR="${1:-}"
if [[ -z "$DIR" || ! -d "$DIR" ]]; then
    cat <<EOF >&2
Usage: $0 <metadata-dir>

Expected layout (fastlane deliver compatible):
  <metadata-dir>/<locale>/{name,subtitle,keywords,description,promotional_text,release_notes}.txt
EOF
    exit 2
fi

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }

fail=0

# Apple-imposed character limits (April 2026).
# Parallel arrays for bash 3.2 compatibility (macOS default bash has no
# associative arrays).
FIELD_NAMES=(name subtitle keywords description promotional_text release_notes)
FIELD_LIMITS=(30 30 100 4000 170 4000)

limit_for() {
    local target="$1" i
    for i in "${!FIELD_NAMES[@]}"; do
        if [[ "${FIELD_NAMES[$i]}" == "$target" ]]; then
            echo "${FIELD_LIMITS[$i]}"
            return
        fi
    done
    echo 0
}

lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }

# Count characters the way ASC counts: bytes count for ASCII; for CJK / emoji
# Apple's own counter uses grapheme clusters. We approximate with `wc -m`
# (multibyte char count). Close enough for almost all real cases — if it's
# right at the boundary, paste into ASC to confirm.
count_chars() {
    LANG=en_US.UTF-8 wc -m < "$1" | awk '{print $1}'
}

# Strip trailing newline before counting so a trailing \n doesn't push you
# 1 over a limit.
char_count() {
    local f="$1"
    local raw
    raw=$(cat "$f")
    printf '%s' "$raw" | LANG=en_US.UTF-8 wc -m | awk '{print $1}'
}

audit_locale() {
    local locale_dir="$1"
    local locale
    locale=$(basename "$locale_dir")
    bold "==> Locale: $locale"

    # 1. Hard character limits
    for field in "${FIELD_NAMES[@]}"; do
        local file="$locale_dir/$field.txt"
        local limit
        limit=$(limit_for "$field")
        if [[ ! -f "$file" ]]; then
            if [[ "$field" == "name" || "$field" == "description" || "$field" == "keywords" ]]; then
                red "  ✗ $field.txt missing (required)"
                fail=1
            else
                yellow "  ! $field.txt missing (optional)"
            fi
            continue
        fi
        local n
        n=$(char_count "$file")
        if (( n > limit )); then
            red "  ✗ $field.txt: $n / $limit chars — over limit by $((n - limit))"
            fail=1
        elif (( n == 0 )); then
            yellow "  ! $field.txt: empty"
        else
            local pct=$(( n * 100 / limit ))
            green "  ✓ $field.txt: $n / $limit chars (${pct}%)"
        fi
    done

    # 2. Keyword field deep checks
    local kw_file="$locale_dir/keywords.txt"
    local name_file="$locale_dir/name.txt"
    if [[ -f "$kw_file" ]]; then
        local kw
        kw=$(cat "$kw_file" | tr -d '\n')
        # space-after-comma waste
        if [[ "$kw" == *", "* ]]; then
            local waste
            waste=$(grep -o ', ' <<<"$kw" | wc -l | awk '{print $1}')
            yellow "    keywords: $waste space(s) after commas — drop them to recover $waste chars of budget"
        fi
        # internal duplicates
        local kw_clean
        kw_clean=$(tr ',' '\n' <<<"$kw" | sed 's/^[ \t]*//;s/[ \t]*$//' | tr '[:upper:]' '[:lower:]' | sort)
        local total_kw uniq_kw
        total_kw=$(grep -c . <<<"$kw_clean" || true)
        uniq_kw=$(sort -u <<<"$kw_clean" | grep -c . || true)
        if (( total_kw > uniq_kw )); then
            yellow "    keywords: $((total_kw - uniq_kw)) duplicate(s) inside the field"
        fi
        # overlap with app name (Apple already indexes name; redundant chars)
        if [[ -f "$name_file" ]]; then
            local name_words
            name_words=$(tr -cs 'A-Za-z0-9' '\n' < "$name_file" | tr '[:upper:]' '[:lower:]' | sort -u)
            while IFS= read -r w; do
                [[ -z "$w" || ${#w} -lt 3 ]] && continue
                if grep -qx "$w" <<<"$kw_clean"; then
                    yellow "    keywords: '$w' is already in app name — Apple indexes name automatically, drop from keywords"
                fi
            done <<<"$name_words"
        fi
        # utilization
        local kw_chars
        kw_chars=$(char_count "$kw_file")
        local kw_limit
        kw_limit=$(limit_for keywords)
        if (( kw_chars < kw_limit * 80 / 100 )); then
            yellow "    keywords: only ${kw_chars}/${kw_limit} chars used — you have $((kw_limit - kw_chars)) chars of free ranking budget"
        fi
    fi

    # 3. Subtitle vs name
    local sub_file="$locale_dir/subtitle.txt"
    if [[ -f "$name_file" && -f "$sub_file" ]]; then
        local name sub
        name=$(cat "$name_file" | tr -d '\n')
        sub=$(cat "$sub_file" | tr -d '\n')
        if [[ -n "$name" && -n "$sub" ]]; then
            local lname lsub
            lname=$(lower "$name")
            lsub=$(lower "$sub")
            if [[ "$lsub" == "$lname" ]]; then
                red "  ✗ subtitle is identical to name — wasted 30-char keyword slot"
                fail=1
            elif [[ "$lsub" == *"$lname"* ]]; then
                yellow "  ! subtitle contains the app name — wasted chars (Apple indexes name separately)"
            fi
        fi
    fi

    # 4. Name "for iPhone/iPad" lint (Apple rejects)
    if [[ -f "$name_file" ]]; then
        local name
        name=$(cat "$name_file" | tr -d '\n')
        local lname
        lname=$(lower "$name")
        if [[ "$lname" == *" for iphone"* || "$lname" == *" for ipad"* ]]; then
            red "  ✗ name contains 'for iPhone' / 'for iPad' — Apple rejects this in the App Name field"
            fail=1
        fi
    fi

    # 5. Description hook check (first ~170 chars are visible before "more")
    local desc_file="$locale_dir/description.txt"
    if [[ -f "$desc_file" ]]; then
        local hook
        hook=$(head -c 170 "$desc_file")
        if [[ ! "$hook" == *.* && ! "$hook" == *"!"* && ! "$hook" == *"?"* ]]; then
            yellow "    description: first 170 chars don't end a sentence — those are the visible portion before 'more'. Make them count."
        fi
    fi
}

# Walk every immediate subdirectory as a locale.
for d in "$DIR"/*/; do
    [[ -d "$d" ]] || continue
    audit_locale "${d%/}"
    echo
done

if (( fail )); then
    red "aso-audit FAILED with hard violations."
    exit 1
fi
green "aso-audit passed (warnings, if any, are advisory)."
