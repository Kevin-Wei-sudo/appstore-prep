#!/usr/bin/env bash
#
# Scan an iOS / macOS Swift codebase for OAuth anti-patterns that App
# Store review (Guideline 4.5 / 4.8) rejects.
#
# Detects:
#   1. UIApplication.shared.open(authURL)  -> kicks to Safari, rejected
#   2. UIApplication.openURL(authURL)      -> deprecated API, same issue
#   3. NSWorkspace.shared.open(authURL)    -> macOS equivalent
#   4. WKWebView used for OAuth            -> phishing risk, rejected
#
# Heuristic: a call site is flagged when an auth-URL signal appears within
# ±15 lines of the call. Auth-URL signals are domain/path patterns Apple's
# review team also pattern-matches on.
#
# Suppress a false positive by adding a trailing comment:
#   UIApplication.shared.open(myURL)  // oauth-review-check: ok
set -euo pipefail

DIR="${1:-}"
if [[ -z "$DIR" || ! -e "$DIR" ]]; then
    cat <<EOF >&2
Usage: $0 <path-to-swift-source-dir-or-file>
EOF
    exit 2
fi

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
gray() { printf '\033[90m%s\033[0m\n' "$*"; }

# Collect Swift files (excluding generated / Pods / DerivedData)
swift_files=$(find "$DIR" -type f -name '*.swift' \
    ! -path '*/Pods/*' \
    ! -path '*/DerivedData/*' \
    ! -path '*/.build/*' \
    ! -path '*/build/*' 2>/dev/null)

if [[ -z "$swift_files" ]]; then
    yellow "No Swift files found under $DIR"
    exit 0
fi

# URL signals — case-insensitive match within ±15 lines of a call site.
# Strong signals (HIGH severity if present): obvious OAuth endpoints.
# Weak signals (MED severity): generic auth-y variable / path names.
STRONG_SIGNALS='oauth|/authorize|appleid\.apple\.com|accounts\.google\.com|github\.com/login|login\.microsoftonline|console\.anthropic\.com/oauth|claude\.ai/oauth|/v1/oauth|/v2/oauth|/connect/authorize'
WEAK_SIGNALS='authURL|loginURL|signInURL|signinURL|oauthURL|/auth/|/login|/sign-?in|/sso'

# Detect helpful-API presence (good signs).
HELPFUL_APIS='ASWebAuthenticationSession|SFSafariViewController'

high_count=0
med_count=0
info_count=0

scan_file() {
    local f="$1"
    local total
    total=$(wc -l < "$f")

    # Map: line numbers of call-site anti-patterns
    local antipattern_lines
    antipattern_lines=$(grep -nE '(UIApplication\.shared\.open|UIApplication\.openURL|NSWorkspace\.shared\.open|WKWebView\s*\()' "$f" 2>/dev/null || true)

    [[ -z "$antipattern_lines" ]] && return

    while IFS= read -r match; do
        [[ -z "$match" ]] && continue
        local lineno text suppress_check
        lineno="${match%%:*}"
        text="${match#*:}"

        # Suppression comment
        if [[ "$text" == *"oauth-review-check: ok"* ]]; then
            continue
        fi

        # Determine which API was hit (used in the message)
        local api=""
        if [[ "$text" == *"UIApplication.shared.open"* ]]; then api="UIApplication.shared.open"
        elif [[ "$text" == *"UIApplication.openURL"* ]]; then api="UIApplication.openURL"
        elif [[ "$text" == *"NSWorkspace.shared.open"* ]]; then api="NSWorkspace.shared.open"
        elif [[ "$text" == *"WKWebView"* ]]; then api="WKWebView"
        fi

        # Window: ±5 lines around the call site. Narrow enough to stay inside
        # the same function in typical Swift formatting, wide enough to catch
        # the URL definition right above the call.
        local lo hi
        lo=$(( lineno - 5 ))
        (( lo < 1 )) && lo=1
        hi=$(( lineno + 5 ))
        (( hi > total )) && hi=$total
        local window
        # Strip out lines that are themselves suppression comments before
        # signal-matching — otherwise the literal 'oauth-review-check: ok'
        # in a nearby suppression triggers false HIGH signals on unrelated calls.
        window=$(sed -n "${lo},${hi}p" "$f" | grep -v 'oauth-review-check: ok' || true)

        # Severity
        local severity="" hint=""
        if grep -iqE "$STRONG_SIGNALS" <<<"$window"; then
            severity="HIGH"
            hint=$(grep -ioE "$STRONG_SIGNALS" <<<"$window" | head -1)
            high_count=$((high_count + 1))
        elif grep -iqE "$WEAK_SIGNALS" <<<"$window"; then
            severity="MED"
            hint=$(grep -ioE "$WEAK_SIGNALS" <<<"$window" | head -1)
            med_count=$((med_count + 1))
        else
            # No auth signal nearby — this call is probably opening a non-auth URL
            # (App Store link, share sheet, etc). Don't report it.
            continue
        fi

        # Print the finding
        local rel
        rel="${f#$DIR/}"
        case "$severity" in
            HIGH)
                red "❌ HIGH  $rel:$lineno"
                red "   $api near auth signal '$hint'"
                ;;
            MED)
                yellow "⚠️  MED   $rel:$lineno"
                yellow "   $api near auth-looking name '$hint'"
                ;;
        esac
        gray "   line $lineno: $(echo "$text" | sed -E 's/^[[:space:]]+//')"

        # Recommend a fix per API
        case "$api" in
            "UIApplication.shared.open"|"UIApplication.openURL"|"NSWorkspace.shared.open")
                gray "   fix: present an SFSafariViewController(url:) for view-only auth pages,"
                gray "        or ASWebAuthenticationSession for OAuth with a callback URL scheme."
                ;;
            "WKWebView")
                gray "   fix: replace the WKWebView with ASWebAuthenticationSession — Apple"
                gray "        rejects custom WebView OAuth (users can't see the URL bar = phishing risk)."
                ;;
        esac
        echo
    done <<<"$antipattern_lines"

    # Note when helpful APIs are already present (info)
    if grep -qE "$HELPFUL_APIS" "$f"; then
        local present
        present=$(grep -oE "$HELPFUL_APIS" "$f" | sort -u | tr '\n' ',' | sed 's/,$//')
        gray "ℹ️  INFO  ${f#$DIR/}: already imports $present"
        info_count=$((info_count + 1))
    fi
}

bold "==> Scanning $DIR for OAuth anti-patterns"
echo

while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    scan_file "$f"
done <<<"$swift_files"

echo "—————————————————————————————"
if (( high_count > 0 )); then
    red "$high_count HIGH violation(s) — fix before App Store submission"
fi
if (( med_count > 0 )); then
    yellow "$med_count MED  warning(s)   — verify each manually"
fi
if (( info_count > 0 )); then
    gray "$info_count INFO file(s)      — already use a compliant API"
fi
if (( high_count == 0 && med_count == 0 )); then
    green "No OAuth anti-patterns near auth-URL signals."
fi

(( high_count > 0 )) && exit 1
exit 0
