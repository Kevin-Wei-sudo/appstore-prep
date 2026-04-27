---
name: aso-audit
description: Use this skill to audit App Store / Mac App Store metadata before submission. Validates keywords ≤100 chars (and warns on space-after-comma, name duplication, internal duplicates, wasted slots), subtitle ≤30 chars and distinct from name, app name ≤30 chars without "for iPhone/iPad" suffix, description ≤4000 chars, promotional text ≤170 chars, "What's New" ≤4000 chars, and screenshot pixel sizes / counts per device size. Reads fastlane-style `fastlane/metadata/<locale>/*.txt` directories so it works without an ASC API key. Trigger when: user is preparing App Store submission metadata, hits "keywords must be less than 100 characters", asks how to optimize ASO, or just before clicking "Submit for Review".
---

# aso-audit

Audit App Store metadata for character-limit and ASO best-practice violations *before* you paste it into App Store Connect.

## When to use this skill

- About to submit a new version: catch character-limit overruns before they fail in the ASC web form
- Hit the "keywords must be less than 100 characters" error
- Optimizing ASO: see how many of your 100 keyword chars are actually being used
- Localizing for a new market: same checks across each locale

This skill is the **offline / pre-submission** layer. It does not query the live App Store ranking, search volume, or competitor data — those need third-party APIs and are out of scope for the OSS plugin. (If you want those, that's a paid service area; see the roadmap.)

## What it checks

Run [scripts/audit-metadata.sh](scripts/audit-metadata.sh) on a fastlane-style metadata directory:

```sh
./audit-metadata.sh fastlane/metadata
```

It walks every `<locale>/` subdirectory and validates each field against Apple's rules:

| Field | File | Limit | Extra checks |
|---|---|---|---|
| App name | `name.txt` | 30 chars | warns on " for iPhone" / " for iPad" / trailing emoji (Apple often rejects) |
| Subtitle | `subtitle.txt` | 30 chars | warns if same as or contains the app name (wasted ranking slot) |
| Keywords | `keywords.txt` | 100 chars | warns on space-after-comma (eats budget), duplicates with app name, internal duplicates, low utilization (< 80% of budget used) |
| Description | `description.txt` | 4000 chars | warns if first 3 lines (~170 chars) don't include a value prop — Apple shows only those before "more" |
| Promotional text | `promotional_text.txt` | 170 chars | not indexed for search (warning if user is keyword-stuffing here) |
| What's New | `release_notes.txt` | 4000 chars | warns if identical to previous release_notes.bak (placeholder check) |

For each violation the script prints a one-line fix recipe.

## ASO best-practice checks (beyond Apple's hard limits)

### Keyword budget utilization

Apple gives you 100 chars. Most apps use 60–70 because they put spaces after commas (which count). The script reports utilization:

```
keywords.txt: 73/100 chars, 13 keywords, 13 chars wasted on commas+spaces
  → drop the spaces after commas to recover 12 chars of ranking budget
```

### Name + subtitle + keywords interaction

Apple indexes `name`, `subtitle`, and `keywords` together for search. **If a word appears in `name`, including it in `keywords` is wasted budget** — Apple already indexes it. The script warns on overlap.

### Localization completeness

If you have multiple locales, all required fields must exist in each. Common bug: shipping with localized `name.txt` but inheriting the English `description.txt`.

## Screenshot validation

Run [scripts/check-screenshots.sh](scripts/check-screenshots.sh) on a fastlane-style screenshots directory:

```sh
./check-screenshots.sh fastlane/screenshots
```

It checks each `<locale>/<device-folder>/*.png|jpg`:

1. **Required device sizes for current submissions** (April 2026):
   - **6.9" Display** (iPhone 16/17 Pro Max): 1320×2868 — required for new iPhone submissions
   - **6.7" Display** (iPhone 14/15 Pro Max): 1290×2796 or 1284×2778 — accepted
   - **6.5" Display** (iPhone 11 Pro Max): 1242×2688 or 1284×2778 — optional now, was required pre-2024
   - **iPad 13"** / **12.9"** (3rd gen+): 2064×2752 / 2048×2732 — required for universal apps
2. **Pixel dimensions match the slot** (most common bug: 6.5" PNGs in the 6.7" folder)
3. **3 ≤ count ≤ 10** per device per locale
4. **No alpha channel** on JPEGs (Apple rejects)
5. **No device frames** (warning — Apple's HIG discourages embedded device chrome; widely enforced)

## Generate a starter manifest

If you don't have a fastlane setup yet, run [scripts/init-metadata.sh](scripts/init-metadata.sh):

```sh
./init-metadata.sh fastlane/metadata en-US
```

It creates an empty `fastlane/metadata/en-US/` with all the expected `.txt` files and inline comments showing the limits. Edit, then re-run audit.

## What this skill does NOT do (yet)

- Live keyword rank tracking (needs scraping or Sensor Tower API)
- Search volume estimation (needs a paid data source)
- Competitor metadata comparison (needs scraping)
- A/B test result analysis (needs ASC Analytics API)
- Review sentiment monitoring (needs ASC API + NLP)

These are the "ASO dashboard" features and live in a separate (paid) tier — outside this OSS plugin.

## Hooking into release-ios

You can chain this skill with `release-ios` so the audit runs before every archive:

```sh
appstore-prep/skills/aso-audit/scripts/audit-metadata.sh fastlane/metadata && \
appstore-prep/skills/release-ios/scripts/archive-and-upload.sh ...
```

If audit fails, the archive doesn't run.
