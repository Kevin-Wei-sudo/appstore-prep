---
name: icon-check
description: Use this skill to validate an iOS or macOS AppIcon.appiconset before submitting to App Store Connect. Catches the issues that cause visible white borders, halos, or rejected uploads — non-full-bleed icons, alpha channels, mismatched pixel sizes vs the size declared in Contents.json, and missing required slots (especially the iOS 1024 marketing icon and the macOS 512pt@2x). Trigger when: the user is about to upload to ASC, has a visible white border on the home screen icon, hit error 90236 (missing required icon size), or asks "is my app icon ready for submission".
---

# icon-check

Validate an `AppIcon.appiconset` before you upload to App Store Connect. The single most common rejection-or-shame source for first-time submitters.

## When to use this skill

- Right before archiving for App Store submission
- After designing a new icon
- After hitting validation error 90236 ("Missing required icon")
- When the icon shows a visible white border / halo / corner pixels on the device home screen
- When porting an icon from Android → iOS (Android adaptive icons have safe zones; iOS does not)

## What this skill checks

Run [scripts/check-icons.sh](scripts/check-icons.sh) pointed at an `.appiconset` directory:

```sh
./check-icons.sh path/to/Assets.xcassets/AppIcon.appiconset
```

It validates:

1. **All required slots are present.** For iOS: 1024, 180, 167, 152, 120, 87, 80, 76, 60, 58, 40, 29, 20. For macOS: 1024 (512pt@2x), 512, 256, 128, 64, 32, 16. The 1024 (iOS marketing / macOS 512pt@2x) is the one that triggers error 90236 most often.
2. **Pixel dimensions match the slot.** A common bug: someone resizes a 512×512 to fill the 1024 slot. ASC reads the actual pixel header and rejects the build. The script uses `sips -g pixelWidth -g pixelHeight`.
3. **No alpha channel.** iOS rejects PNGs with alpha for the marketing 1024 icon. The script uses `sips -g hasAlpha`. macOS is more forgiving but we warn.
4. **Full-bleed at corners.** This is the white-border check. The script samples the top-left 4×4 pixel block and the center 4×4 pixel block. If the corner is pure or near-pure white (RGB > 240) AND the center is not, the icon was designed with built-in rounded corners — iOS will apply its squircle mask on top, leaving white pixels where the designed corner clipped before the system mask did. Result: visible white halo.
5. **Single 1024 source for all sizes (suggested).** Sampled corner colors across sizes should be within tolerance. If the 60 has a different background than the 1024, somebody hand-edited some sizes. Not strictly fatal, but flagged.

## Common causes of a visible white border

You have a 1024 PNG that was exported from a design tool with built-in rounded corners and a transparent or white background outside the rounded square. iOS does not honor the designed corners — it applies its own squircle mask. So:

- If the area outside the designed corner is **transparent**, iOS shows the system parent-view background through it (often white in Light Mode), creating a halo.
- If it's **filled white**, iOS shows white pixels right up to the squircle mask edge — visible white border.

The fix is to design the icon **full-bleed**: every pixel from corner to corner is part of the design, and you let iOS clip with its own mask. No designed corners.

## Fix recipe

Once `check-icons.sh` flags a non-full-bleed icon:

1. Re-export the 1024 from your design tool with **no rounded corners and no transparent area**. The background should extend to all four hard corners.
2. Save as `AppIcon-1024.png`, no alpha.
3. Regenerate every smaller size from that 1024 source so the design stays consistent:
   ```sh
   for sz in 20 29 40 58 60 76 80 87 120 152 167 180; do
       sips -z $sz $sz AppIcon-1024.png --out AppIcon-$sz.png
   done
   ```
4. Re-run `check-icons.sh`. All checks should now pass.
5. Commit and re-archive.

## Why this matters more than people think

The white-border issue won't fail App Store validation — the build uploads fine and gets approved. Users see the halo on their home screen and form a bad first impression. A reviewer might not even notice. So this is a "pass-but-embarrassing" class of bug, which is worse than a hard validation failure (those at least force a fix).

If your icon has been live for a release with this issue, ship a follow-up version with the fix; you cannot replace the binary on an approved version, but you can ship a new patch version with no other changes (we did this for ClaudeScope: v1.0.2 had the visible border, v1.0.3 was a full-bleed icon-only update).
