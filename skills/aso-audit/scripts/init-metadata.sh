#!/usr/bin/env bash
#
# Create an empty fastlane-style metadata directory for one locale, with
# inline comments showing the character limits and ASO tips.
set -euo pipefail

DIR="${1:-}"
LOCALE="${2:-en-US}"

if [[ -z "$DIR" ]]; then
    cat <<EOF >&2
Usage: $0 <metadata-dir> [locale]

Examples:
  $0 fastlane/metadata
  $0 fastlane/metadata zh-Hans
EOF
    exit 2
fi

target="$DIR/$LOCALE"
mkdir -p "$target"

write_if_missing() {
    local f="$1"
    if [[ -e "$target/$f" ]]; then
        echo "  · $f exists, leaving alone"
        return
    fi
    cat > "$target/$f"
    echo "  + $f"
}

cd_check() {
    [[ -d "$target" ]] || { echo "could not mkdir $target" >&2; exit 1; }
}

cd_check
echo "==> Initializing $target"

write_if_missing name.txt <<'EOF'
EOF
# (The .txt files store raw text only — Apple counts characters with no comment lines.
#  We instead bundle a separate README inside the locale dir explaining the limits.)

write_if_missing subtitle.txt <<'EOF'
EOF

write_if_missing keywords.txt <<'EOF'
EOF

write_if_missing description.txt <<'EOF'
EOF

write_if_missing promotional_text.txt <<'EOF'
EOF

write_if_missing release_notes.txt <<'EOF'
EOF

cat > "$target/README.md" <<'EOF'
# App Store metadata for this locale

Apple's character limits (April 2026):

| File | Limit | Notes |
|---|---|---|
| name.txt | 30 chars | NO " for iPhone" / " for iPad" suffix — Apple rejects |
| subtitle.txt | 30 chars | Indexed for search. Make it different from the name. |
| keywords.txt | 100 chars | Comma-separated, NO space after commas (each space costs 1 char of ranking budget). Don't repeat words from `name.txt` — Apple already indexes the name. |
| description.txt | 4000 chars | NOT indexed for search. First ~170 chars visible before "more" — make them count. |
| promotional_text.txt | 170 chars | NOT indexed. Useful for time-sensitive announcements; can be updated without resubmit. |
| release_notes.txt | 4000 chars | "What's New in This Version". Required on every version. |

After editing, validate with:

```sh
appstore-prep/skills/aso-audit/scripts/audit-metadata.sh ../..
```

(adjust path to point at the parent of this locale dir)
EOF
echo "  + README.md"

echo
echo "Done. Edit the .txt files, then run:"
echo "  appstore-prep/skills/aso-audit/scripts/audit-metadata.sh $DIR"
