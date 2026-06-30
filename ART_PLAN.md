# Barsoom Flyers — Art & Look-and-Feel Plan

*Companion to `IMPLEMENTATION_PLAN.md` (Phase D "SSD art pass" + Phase B
"Terrain") and `GAME_DESIGN.md`. Status: no image assets exist yet — every
visual is a `_draw()` vector primitive. That's the opportunity: assets can be
authored offline to the contract below, dropped into `assets/`, and wired in
later in short, mechanical coding sessions.*

## 0. Division of labor

**Downtime tasks (no Claude needed):** everything in §3–§6 — drawing/sourcing
images, exporting to spec, picking and downloading fonts, dropping files into
the folder layout in §2, and logging licenses in `assets/CREDITS.md`.

**Claude sessions (short, one per wiring step):** the checklist in §7. Each
step is "load these files, draw them instead of the primitive, keep the
primitive as fallback" — small diffs, easy to test.

The architecture rule still applies: art is **pure UI**. No rules logic ever
keys off a texture; the engine never knows assets exist.

> **Addendum — Isometric view (2026):** The map now offers a tilted **isometric
> view** alongside the flat top-down one (toolbar *View* toggle; *↶/↷* snap-rotate
> the field through 6 orientations). It is a deliberate, scoped departure from the
> flat-ink direction in §1 *for the isometric mode only*: hills/towers extrude into
> sun-shaded prisms, flyers hover with cast shadows, and dust storms and a drifting
> cloud layer add atmosphere. **Top-down view is unchanged** — the original flat
> ink-and-parchment look in §1 is preserved exactly there (guarded by a unit test).
> The 2.5D rendering is still pure `_draw()` vector work through one projection seam
> in [`hex_map.gd`](ui/hex_map.gd); the look is tuned by the constants near the top of
> that file (`ISO_TILT`, `ISO_HEIGHT`, `SHIP_ALT`, `SUN_SCREEN`) and the per-feature
> heights in [`terrain_def.gd`](src/rules/terrain_def.gd) `render_height()`. When
> authoring assets, treat §1 as the contract for **top-down**; isometric massing is
> generated procedurally by default — but **§4b** lets you swap in authored **3D
> terrain models** (glTF) that take over from the procedural prisms when present.

## 1. Art direction

**One sentence:** *ink-and-parchment pulp cartography — a 1912 adventure
novel's endpaper map come alive, not a video-game space battle.*

Anchors (already established in code — keep new art consistent with these):

| Element | Color | Hex | Source |
|---|---|---|---|
| Sea-bottom ochre (map ground) | `(0.87, 0.80, 0.66)` | `#DECCA8` | `hex_map.gd SEA_BOTTOM` |
| Parchment (menus/panels) | `(0.95, 0.93, 0.86)` | `#F2EDDB` | `main_menu.gd PAPER` |
| Ink (lines, text) | `(0.13, 0.11, 0.09)` | `#211C17` | `main_menu.gd INK` |
| Grid line | `(0.45, 0.38, 0.28)` @55% | `#736147` | `hex_map.gd GRID` |
| Helium (player) blue | `(0.16, 0.32, 0.62)` | `#29529E` | `SIDE_COLORS[0]` |
| Zodanga (enemy) red | `(0.62, 0.16, 0.13)` | `#9E2921` | `SIDE_COLORS[1]` |
| Active-ship gold | `(0.95, 0.75, 0.15)` | `#F2BF26` | `ACTIVE_RING` |
| Wreck grey-brown | `(0.35, 0.32, 0.30)` | `#59524D` | `WRECK` |

Style guidance:
- **Line work over shading.** Think engraved book illustration / SFB SSD
  sheets: confident ink outlines, flat or lightly hatched fills, no gradients,
  no drop shadows, no photo textures.
- **Muted, sun-bleached palette** on the map (everything sits on ochre); the
  two faction colors are the only saturated things on the field, so tokens
  always pop.
- Reference imagery worth collecting in a mood folder: Frank Schoonover /
  J. Allen St. John Barsoom plates, Jules Verne airship engravings, SFB SSD
  sheets, old survey maps of dry lake beds.

## 2. Folder layout & conventions

```
assets/
  ships/        top-down map tokens + SSD profile silhouettes
  terrain/      hex tiles and overlays (+ .glb 3D terrain models, §4b)
  map/          ground textures, compass rose, edge dressing
  ui/           panels, buttons, banners, icons, title art
  fonts/        .ttf/.otf files
  CREDITS.md    one line per asset: source, author, license, URL
```

- **Format:** PNG with transparency (or SVG — Godot 4 imports SVG natively;
  if you work in Inkscape/Affinity, commit the SVG and let Godot rasterize).
- **Naming:** lowercase snake_case, exactly as listed in the inventories
  below — the wiring code will look these names up, so matching names means
  zero coordination later.
- **License rule:** only CC0 / public domain / fonts under OFL, or your own
  work. Log everything in `CREDITS.md` as you go, not at the end.

## 3. Ship map tokens (highest payoff — do these first)

The map draws flat-top hexes with circumradius `R` between 10 and 34 px
(follow camera zooms). Tokens are drawn rotated by code.

**Authoring contract — one sprite sheet per ship class:**
- Each sheet is a **horizontal strip of three 512×512 frames** (canvas
  **1536×512**), left to right: **pristine | damaged | wreck**. Authoring the
  states side by side on one canvas keeps them visually consistent (same
  silhouette, same line weight); code slices frames with `AtlasTexture`.
  - *Pristine:* the ship as commissioned.
  - *Damaged:* same hull, battle-worn — smoke scarring, a splintered rail,
	a holed deck. Silhouette must stay identical to frame 1 (the token
	rotates; a changed outline reads as a different ship).
  - *Wreck:* broken-back hulk in neutral `#59524D`, faction color burned
	away. Replaces frames 1–2 when the ship is destroyed or grounded.
- Top-down view, **nose pointing straight UP** in every frame (facing 0 =
  north; code rotates in 60° steps clockwise).
- Transparent background, ship centered per frame, hull length ~85% of frame
  height (it gets scaled down to roughly 1.3·R ≈ 13–44 px on screen, so
  silhouette readability at small size matters more than detail).
- Strong dark outline (~6 px at 512) so it reads against ochre.
- Hull fill in the faction color, deck details in ink. If you'd rather paint
  one neutral hull and let code tint it, paint in greys and name it
  `*_sheet_tintable.png` instead — either works; pick one approach and stick
  to it.

| File | Subject | Notes |
|---|---|---|
| `scout_sheet.png` | Helium Scout Flyer | small, slim, one bow tube visible, open deck |
| `cruiser_sheet.png` | Zodangan Patrol Cruiser | bigger, broader beam, broadside gun sponsons |
| `one_man_sheet.png` | one-man flyer *(future class — optional)* | tiny sliver |
| `battleship_sheet.png` | battleship *(future class — optional)* | massive, layered decks |

(The wreck frame lives in each class's sheet, so there is no shared
`wreck_token.png` — a broken scout and a broken cruiser look like
themselves.)

Design hook from the novels: Barsoomian flyers are open-decked airships —
more "flying brass-and-timber warship" than airplane. Propellers aft,
buoyancy tanks in the hull, guns on deck mounts.

## 4. Terrain hex tiles

Terrain rules don't exist yet (Phase B), but the art contract can be fixed
now so tiles are ready the day the rules land. GDD terrain set: **hills**
(block LOS), **ruined towers**, **dust storms** (spotting penalty).

**Authoring contract:**
- One flat-top hexagon footprint per tile: canvas **512×444** (width 2R,
  height √3·R for R=256), hex corners touching left/right canvas edges,
  transparent outside the hex. A feature may overhang the hex edge by up to
  ~5% (a tower tip, a dust wisp) — overhang sells it as terrain, not tiling.
- Must read at 20 px wide. Ink-heavy, minimal interior detail.
- 2–3 variants per type beats one perfect tile — variety kills the
  wallpaper-repeat look.

| File(s) | Subject | Notes |
|---|---|---|
| `hill_1.png`, `hill_2.png`, `hill_3.png` | rocky hills/mesa | hatched slopes, slightly darker ochre `#C9B58E`-ish |
| `tower_1.png`, `tower_2.png` | ruined Orovar towers | broken white-marble spires, long shadow optional |
| `dust_storm_1.png` … `dust_storm_3.png` | dust storm | ~50–60% opacity swirl, warm grey-orange; semi-transparent so ships ghost through; 3 variants can double as animation frames |
| `sea_bottom_1.png` … `sea_bottom_4.png` | plain ground variation | *subtle*: faint moss-yellow mottling, dry cracks, an old keel-scar — barely-there texture to break the flat ochre; must tile against `#DECCA8` without visible seams |

## 4b. 3D models (isometric view) — *AI-generation contract*

The isometric view draws hills, towers, and ships as procedural primitives
(`hex_map.gd _draw_terrain_prism` / the vector ship token). Authored **3D models**
replace those with real meshes. They are **glTF rendered live**: the shared
`model_baker.gd` rig (an offscreen `SubViewport` + orthographic `Camera3D`) bakes
each model to a sprite at the current view angle (cached per ~15° of field
rotation), which the depth-sorted draw pass blits onto the hex. The **primitive
stays the fallback** — drop a model in and it takes over; with none, nothing changes.

**One pipeline, three asset folders** (all follow the contract below):
- `assets/terrain/` — `hill_<n>.glb` (broad mesas).
- `assets/buildings/` — `tower_<n>.glb` (ruined towers; a tower is a building).
- `assets/ships/` — `scout_<n>.glb`, `cruiser_<n>.glb`, `fighter_<n>.glb`, mapped
  to the classes `helium_scout` / `zodanga_cruiser` / `one_man_flyer`. Ships bake
  at `facing + field-rotation`, hover with a shadow, and get a **side-colour base
  ring** (the shared hulls aren't faction-tinted, so the ring is what reads
  player-blue vs enemy-red). `battleship` has no model yet → keeps the token.
- `assets/effects/` — reserved (wrecks/explosions); empty for now.

Per-model on-screen scale, framing, and ground anchor are tuned in
`model_baker.gd`'s `_register(...)` table, not in the asset.

This section is the contract to hand an **AI 3D generator** (Meshy, Tripo, etc.):
give it the prose seed *plus* every constraint below — text-to-3D tools ignore
scale/orientation unless told, so the technical block is not optional.

**File & engine:**
- Format: **glTF 2.0 binary `.glb`** — one self-contained file, **textures
  embedded**. Godot 4.6 imports it natively.
- Mesh + material **only**: no animation, no rig/skeleton, no cameras or lights
  inside the file. **Apply all transforms** (no leftover object-level scale/rot).

**Axes, anchor, orientation:**
- **Y-up**, `+Y` is up (glTF convention; Godot keeps it).
- Centered on **X/Z at the origin**; the **base sits exactly on `Y = 0`** and the
  model rises into `+Y`, so it stands on the ground plane with no gap or sink.
- `+Z` faces **north** (matches facing 0). Hills/towers are near-radial so this is
  mostly cosmetic, but keep it consistent.

**Scale — define the unit (critical):** **1 unit = one hex circumradius.** The
engine rescales the bake to the on-screen `hex_size`, so *proportions* matter most;
author to these bounding boxes so a hill fills its hex and a tower is a slender
spire (heights match `TerrainDef.render_height`: hill 0.55, tower 1.5):

| Type | Footprint (X×Z) | Height (Y) | Read |
|---|---|---|---|
| Hill | ≈ 1.8 × 1.8 units | ≈ 0.55 units | broad, low, rounded/flat-topped mesa |
| Tower | ≈ 0.8 × 0.8 units | ≈ 1.5 units | slender, crumbling ruined spire |

**Topology & materials:**
- **Low-poly: ≤ ~3k triangles.** It renders ≤ 256 px; silhouette beats detail.
  Clean, manifold, no interior faces.
- PBR metallic-roughness, **metalness 0, roughness ~0.9** — fully matte, no gloss,
  **no emission**. Baked ambient occlusion is welcome. Albedo texture ≤ 512 px, or
  vertex colors.
- Palette to sit on the ochre map (see §1): **hill** sun-bleached ochre-brown
  ≈ `#80592A`; **tower** weathered off-white limestone/marble ≈ `#9A948A`.

**Style:** stylized, illustrated, lightly faceted low-poly — pulp cartography,
**not photoreal**. No high-frequency noise/grime; it must read as a hand-built
diorama piece, consistent with §1's engraved-line look.

**Variants & naming:** 2–3 per type to kill repetition. Files go in
`assets/terrain/` as `hill_1.glb`, `hill_2.glb`, `hill_3.glb`, `tower_1.glb`,
`tower_2.glb`. The loader hashes the hex to pick a variant (a given hill always
looks the same). Log each asset's source/license in `assets/CREDITS.md`.

**Prompt seeds (pair with the constraints above):**
- *Hill:* "low-poly stylized Martian rocky mesa / dry-lakebed hill, weathered
  ochre sandstone, flat-topped, matte, engraved-illustration look, game asset."
- *Tower:* "low-poly ruined ancient Martian watchtower spire, broken weathered
  pale marble, slender, crumbling top, matte, stylized game asset."

**Acceptance check before committing a model:** drop it in `assets/terrain/`,
open the map in isometric, and confirm it stands on the hex (base flush to the
ground), is roughly hex-sized, turns with `↶/↷` and right-drag, and reads at small
zoom. If it floats or sinks, the base isn't on `Y = 0`; if it's the wrong size,
the footprint isn't in hex-circumradius units.

## 5. SSD ship silhouettes (Phase D "art pass" — already on the roadmap)

The SSD panel (`ssd_panel.gd`) draws armor/system boxes on parchment; a real
SFB sheet has the ship's silhouette behind the boxes. **Shipped:** a faint
top-down hull is now drawn behind the armor grid (vector fallback in
`_draw_topdown_hull`), so the spatial armor boxes sit on the matching facing —
bow boxes on the nose, port/starboard down the flanks, stern on the tail. An
authored texture overrides the drawn hull when present.

**Authoring contract (updated — this is a TOP-DOWN plan view now, not a side
profile, so it aligns with the bow-top/stern-bottom armor layout):**
- **Top-down**, **nose pointing UP** (facing 0 = bow at top), centered on the
  hull centerline. This is the same orientation as the map token (§3), so the
  SSD silhouette can reuse the pristine frame of `<id>_sheet.png` if you like.
- Pure line art, single ink color `#211C17`, no fill or very light wash —
  it sits *behind* boxes at ~13% opacity, so it must work as a watermark.
- Canvas **512×768** (taller than wide — a hull is longer than its beam),
  transparent. The view scales it into the armor band, ~2× as tall as wide.

| File | Subject |
|---|---|
| `scout_profile.png` | Helium Scout Flyer, top-down |
| `cruiser_profile.png` | Zodangan Patrol Cruiser, top-down |

(Loader checks `assets/ships/<id>_profile.{png,svg}`. The main menu and
victory/defeat modal can reuse these.)

## 6. UI dressing

### Fonts (quick win — an evening's task)
Pick, download, and drop into `assets/fonts/`; wiring is a 10-line Theme
change. All suggestions are OFL (free, redistributable):

- **Display/title** (wants "1912 adventure novel"): *IM Fell English* (the
  strongest genre fit), *Cinzel*, or *Pirata One* (riskier). Get the one you
  like as `display.ttf`.
- **Body/UI** (wants readable at 12 px over parchment): *Alegreya* or
  *Crimson Pro* as `body.ttf`; *Alegreya Sans* as `ui.ttf` for buttons/labels.
- Numbers matter: check the font's digits in a to-hit table mockup before
  committing.

### Images

| File | Subject | Spec |
|---|---|---|
| `parchment_panel.png` | nine-patch panel background | 256×256, aged-paper tone near `#F2EDDB`, darker inked border ~24 px; used for SSD overlay, dialogs, menus |
| `parchment_wide.png` | full-screen menu backdrop | 1920×1080, same paper, heavier foxing/stains toward edges, center calm enough for text |
| `title_art.png` | main-menu hero image | two flyers closing over a dead sea bottom, engraving style; 1600×600, transparent or on-paper |
| `victory_banner.png` / `defeat_banner.png` | game-over modal headers | 800×200 each; laurels/crossed banners vs. a sinking hulk |
| `compass_rose.png` | map corner ornament | 256×256 ink rose, ~30% opacity in use |
| Icon set, 64×64 each, single-color ink on transparent: | `icon_gun.png`, `icon_torpedo.png`, `icon_crew.png`, `icon_engine.png`, `icon_dc.png`, `icon_buoyancy.png`, `icon_rudder.png`, `icon_bridge.png`, `icon_magazine.png`, `icon_propeller.png` | replaces text labels in allocation/fire UI; keep stroke weight uniform across the set |
| `app_icon.png` | macOS app icon (Phase D export) | 1024×1024; a single flyer over a hex, reads at 16 px |

### Effects sprites (optional, last)

Phase D lists hit flashes and shell tracers; those will likely stay
code-drawn. Worth pre-making only: `explosion_1..4.png` (4-frame ink-blot
burst, 256×256) and `smoke_puff.png` — used for magazine explosions and
wrecks.

## 7. Wiring checklist (Claude sessions, in payoff order)

Each is one small session; none blocks the art above.

1. **Token textures on the map** — `hex_map.gd _draw_ship`: if
   `assets/ships/<id>_sheet.png` exists, slice the three frames with
   `AtlasTexture`, then `draw_set_transform` (rotate by `facing * 60°`, scale
   to ~1.3·`hex_size`) + `draw_texture_rect`; else keep the triangle. Frame
   pick is pure UI: wreck when destroyed/grounded, damaged below some
   capability threshold (e.g. any system boxes lost — read from `ShipState`
   queries, no new rules), pristine otherwise. ~50 lines.
2. **Theme + fonts** — project-wide `Theme` resource: fonts from
   `assets/fonts/`, parchment nine-patch on panels/buttons, ink font colors.
   Touches no logic. Instantly changes the whole game's feel.
3. **Main-menu dress-up** — backdrop, title art, themed buttons in
   `main_menu.gd`.
4. **SSD silhouette underlay** — `ssd_panel.gd`: draw `<id>_profile.png` at
   low opacity behind the box grid, scaled to panel width.
5. **Ground variation** — `hex_map.gd`: per-hex deterministic pick (hash of
   coords) from `sea_bottom_*.png`, drawn under the grid lines. Compass rose
   in a fixed screen corner.
6. **Victory/defeat banners + icons** — `map_demo.gd` modal and allocation/
   fire rows.
7. **Terrain tiles** — only after terrain *rules* exist in `TurnEngine`
   (Phase B). The view then draws `hill/tower/dust` tiles for hexes the
   engine reports as terrain. Art from §4 will already be waiting.
8. **3D terrain models (isometric)** — new `ui/terrain_models.gd`: a small
   offscreen `SubViewport` + orthographic `Camera3D` (~35° elevation, matched to
   `ISO_TILT`) + `DirectionalLight3D` (matched to `SUN_SCREEN`) bakes each
   `assets/terrain/*.glb` (§4b) to a sprite, cached per ~15° of field rotation
   (plus a straight-down frame for top-down). `hex_map.gd _draw_terrain_model`
   blits the nearest-angle sprite in the existing depth-sorted pass, **falling
   back to `_draw_terrain_prism` when no model is present**. Needs one placeholder
   `.glb` to validate; everything else is already in place.

## 8. Suggested downtime order

1. Fonts (smallest effort, whole-game payoff).
2. `scout_sheet.png` + `cruiser_sheet.png` (pristine | damaged | wreck
   frames) — the thing you stare at all game.
3. `parchment_panel.png` + `parchment_wide.png`.
4. The two SSD profiles (highest craft, reused in three places).
5. Sea-bottom variation tiles, compass rose.
6. Terrain tiles (hills → towers → dust).
7. Title art, banners, icon set.
8. App icon, effects frames.

**Tools:** Inkscape (free, ideal for this line-art style — and you can commit
the SVGs), Affinity Designer, or Procreate. AI generation is fine for
mood/reference or a base to trace, but the engraved-line style usually needs
manual cleanup to stay consistent across assets — consistency across the set
matters more than any single piece's quality.
