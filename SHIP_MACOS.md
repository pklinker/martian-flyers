# Shipping Barsoom Flyers on macOS

The export preset (`export_presets.cfg`, preset **"macOS"**, universal binary)
and the app icon (`assets/ui/app_icon.svg`) are committed and ready. What
remains is environment- and credential-gated and must be done on a Mac with an
Apple Developer account — it cannot be automated in this repo.

## 1. One-time setup

- **Install the macOS export templates** for the matching Godot version
  (4.6.3): *Editor → Manage Export Templates → Download and Install*, or drop
  the `.tpz` into `~/Library/Application Support/Godot/export_templates/`.
  Without these, `--export-release "macOS"` fails with "export templates not
  found" (this is why CI here can't produce the build).
- **Apple Developer Program** membership ($99/yr) — required for a
  *Developer ID Application* certificate and for notarization.

## 2. Unsigned local build (works today, once templates are installed)

```sh
godot --headless --path . --export-release "macOS" build/MartianFlyers.app
```

Produces a runnable `.app`. Gatekeeper will warn on other machines (right-click
→ Open to bypass locally). Fine for personal use and playtests.

## 3. Signed + notarized build (for distribution)

Fill these into `export_presets.cfg` under `[preset.0.options]` (or, better,
keep secrets out of git by setting them through *Project → Export* on the
machine that builds — Godot stores credentials in `export_credentials.cfg`,
which is already in `.gitignore`):

- `codesign/codesign=2` (use Xcode `codesign`/built-in `rcodesign`).
- `codesign/identity="Developer ID Application: Your Name (TEAMID)"`.
- `codesign/apple_team_id="TEAMID"`.
- Hardened-runtime entitlements: leave the defaults — the game needs no special
  entitlements (no JIT, no sandbox exceptions, no mic/camera).
- `notarization/notarization=2` (notarize via `notarytool`), then either:
  - **App Store Connect API key:** `notarization/api_uuid`,
    `notarization/api_key` (path to the `.p8`), `notarization/api_key_id`; or
  - **Apple ID:** `notarization/apple_id_name` (your Apple ID),
    `notarization/apple_id_password` (an *app-specific password*, not your real
    one), `notarization/apple_team_id`.

Then export — Godot signs, submits to Apple, waits for the ticket, and staples
it:

```sh
godot --headless --path . --export-release "macOS" build/MartianFlyers.dmg
```

## 4. Verify before distributing

```sh
spctl -a -vvv -t install build/MartianFlyers.app     # "accepted, source=Notarized Developer ID"
codesign --verify --deep --strict --verbose=2 build/MartianFlyers.app
xcrun stapler validate build/MartianFlyers.app
```

## Notes

- `application/bundle_identifier` is `com.barsoomflyers.martianflyers` — change
  it to a domain you control before submitting.
- Bump `application/short_version` / `application/version` per release.
- The icon is an SVG; Godot rasterizes it into the required `.icns` at export.
  If you later author the 1024×1024 `app_icon.png` from `ART_PLAN.md §6`, point
  `application/icon` at it instead.
