# Maps as a Catalog — Plan

Move the **map** — the board, its terrain layout, and the terrain *kinds* it
uses — out of hard-coded GDScript and into an **editable, moddable catalog**,
exactly as [`SHIP_MODDING.md`](SHIP_MODDING.md) did for ships and guns. Then
extend the **3d-gen** editor (`/Users/paulklinker/src/3d-gen`) to *author whole
maps* — paint terrain onto a hex grid, pick the assets, and export a map pack
straight into the flyers catalog.

Scope explicitly excludes ships (those are already catalogued and are placed by
the player at deploy time, see [`PLACEMENT.md`](PLACEMENT.md)).

This document is a plan only — no code changes are included.

---

## 0. Eng-review decisions (2026-07-01)

Locked during `/plan-eng-review`. These **override the body below** where they
differ; the body is kept for rationale.

1. **One catalog, shared loader.** Extract the common layered-load / mod-scan /
   JSON-read / reject machinery into a `CatalogLoader` helper that `ShipCatalog`
   also uses (refactored onto it, guarded by the parity test). Add **one**
   `MapCatalog` that loads *both* `maps.json` and `terrain.json` (mirroring how
   `ShipCatalog` loads guns+ships together) — **not** a separate `TerrainCatalog`.
   `MapLibrary` is the single facade exposing `map(id)`, `map_ids()`, and
   `kind(id)` (terrain-kind lookup). Supersedes the `TerrainCatalog`/
   `TerrainLibrary` split in §5.2.
2. **Map→kind referential integrity.** After every layer loads, `MapCatalog`
   validates each map's cells against the kind set (both files are in by then).
   An unknown-kind cell is dropped with a loud `push_error` (map+kind+hex); a map
   that loses required terrain or names an unknown kind is dropped so the picker
   never offers a broken map. Mirrors [`_drop_ships_with_unknown_guns`](src/rules/ship_catalog.gd:177).
3. **Asset origin travels with the kind.** Promote the loader's `source` from an
   error label to a real **base path** (`res://` or the pack's
   `user://mods/<pack>/`) stored on each kind def. `ModelBaker`/`DustSprites`
   resolve assets as `<source_root>/assets/<dir>/<prefix>_N`. One resolution path
   for core and mod kinds; no prefix-collision ambiguity.
4. **[CRITICAL] Runtime glb load needs a spike.** `load()`/`ResourceLoader.exists()`
   on a `.glb` only resolves the **editor-baked** `.scn` under `res://.godot/`
   (verified: `tower_1.glb.import`). A `.glb` in `user://mods/<pack>/assets/` has
   no `.import` sidecar and **will not load** — so mod-supplied glb terrain/
   buildings won't render, while PNG sprite sheets (dust) *do* load from `user://`.
   **Gate the modder-asset work on a proof-of-concept:** load a `user://` glb at
   runtime via `GLTFDocument.new()` + `GLTFState` + `append_from_file` into a
   mountable `Node3D`. If it works, `ModelBaker` keeps the fast baked-`.scn` path
   for core kinds and uses the `GLTFDocument` path for mod kinds. The data-driven
   maps/kinds work (§4/§5) does **not** block on this spike. Corrects §5.4's
   "just extend the dir list."
   **→ SPIKE PASSED (2026-07-01):** [`tests/spike_runtime_glb.gd`](tests/spike_runtime_glb.gd),
   10/10 checks headless on Godot 4.6. The `GLTFDocument` path works, the loaded
   scene packs into a `PackedScene` (baker contract unchanged — set `owner` on
   descendants before `pack()`), and the negative control confirms the original
   finding. Mod glb terrain/buildings are **viable as designed**; T1 done.
5. **Pack export is its own path, not a retarget of the dev save.** The
   dev-server `/api/save` writes into the author's source checkout
   (`DEFAULT_GAME_DIR`, disabled in production) — useless to a real modder on a
   shipped build. 3d-gen ships **two** export paths: (a) dev save (author inner
   loop, unchanged); (b) **pack export** — a downloadable self-contained zip
   (`maps.json` + `terrain.json` + `assets/`) plus documented install into the
   per-OS `user://mods/` location (`%APPDATA%/Godot/app_userdata/…`, etc).
   Supersedes §6.4's "same operation aimed at a different dir."
6. **Renderer branches on a `render_type` property, not an id.** A kind with
   `render.sprite` draws the animated billboard; `render.model` draws the
   extruded/baked mesh; else procedural fallback. Removes the hardcoded
   `t == TerrainDef.Type.DUST_STORM` compares in [`hex_map.gd:633`](ui/hex_map.gd:633)
   and [`:690`](ui/hex_map.gd:690) so any future animated kind works.
7. **Deploy defaults: `DEFAULT_` const + instance var.** Rename the consts to
   `DEFAULT_DEPLOY_ZONE_COLS` / `DEFAULT_DEPLOY_MIN_SEPARATION` (keep 24/10), add
   instance vars initialized from them that `apply_map` overrides per map, and
   repoint the 6 static refs in [`test_rules.gd`](tests/test_rules.gd:1511).
   Same for `map_cols`/`map_rows` (already vars).
8. **String-id sentinel + hot-path cost.** `terrain{}` string-keyed means the
   `terrain.get(h, -1)` "no terrain" sentinel in [`terrain_def.gd:22`](src/rules/terrain_def.gd:22),[`:32`](src/rules/terrain_def.gd:32)
   becomes `StringName()` and every `blocks_los(int(...))`/`spot_penalty(int(...))`
   drops the `int()` coercion. This is the hot LOS/fire path the AI **clones and
   simulates forward** ([`save_game.gd` clone`], `ship_ai`), so the kind lookup
   must stay an O(1) dict hit on the loaded catalog — no per-call allocation.
9. **Save consistency.** Reconcile the §4.5/§5.3 contradiction: with kind ids in
   the save, loads **do** depend on the catalog. `terrain` serializes via the
   existing `var_to_str` (StringName round-trips); the missing-dependency guard
   walks the flat `terrain` dict's values (no ship-style nested structure to hang
   off). Parity/round-trip tests move from int assertions to id assertions.
10. **Schema kept in sync by a golden fixture.** A committed example pack
	(`maps.json` + `terrain.json`) is asserted by the flyers GDScript suite (must
	parse every field) **and** by a 3d-gen test (serializer reproduces it).
	Adding a field reddens both suites until both sides handle it.
11. **3d-gen gets Vitest.** No test framework exists there today. Add Vitest
	(Vite-native) to cover the `MapDoc→maps.json` serializer, the golden-fixture
	round-trip, and the merge endpoint's upsert-by-id (add / replace / create /
    preserve-others) — the catalog-corrupting logic.
12. **Editor grid: merged geometry + InstancedMesh.** The 48×48 painter draws all
    hex outlines as one merged `LineSegments` (single draw call) and painted cells
    as one `THREE.InstancedMesh` per kind — O(kinds) draw calls, not O(cells).
13. **Render tuning is authored against the mesh (desync guard).** `frame`/`span`/
	`look_y`/`anchor` are tuned to a specific glb. They are authored in 3d-gen's
	live 3D-iso preview (WYSIWYG against the actual mesh) and pack export bundles
	the mesh + its tuning together, so re-exporting a different mesh re-tunes in
	the same session. Core-only parity tests cannot catch mod-content desync — the
	WYSIWYG authoring is the mitigation.
14. **Painter stays in v1** (3D iso), accepted as the largest workstream.
15. **One indivisible commit.** The enum→string-id change, all switch sites
	(`damage_resolver`, `ship_state`, `ship_ai`, both `hex_map` passes),
	`ModelBaker`/`DustSprites` catalog-drive, and the parity test land **together**
	— the clean seams §8 implies between those steps do not exist.
16. **Landing order gains a step 0: the glb-runtime spike** (decision 4), before
	any modder-asset work.

### T2 as-built (2026-07-01) — schema pinned

The foundation (shared `CatalogLoader`, one `MapCatalog` loading `terrain.json` +
`maps.json`, `MapLibrary`, and the core data files) landed additively — the
running engine still uses the int-enum `TerrainDef`; a parity test asserts the
three core kinds reproduce today's `TerrainDef` + `ModelBaker`/`DustSprites`
values, and `dead_sea_bottom` reproduces `_place_terrain()`. Two schema details
were pinned during implementation, superseding the sketches in §4.1/§5.1:

- **Kind ids are lowercase snake_case** (`hill`, `tower`, `dust_storm`), not the
  `HILL` shown in the §4.1 example.
- **`render.color` is an `[r,g,b,a]` float array**, not the `#RRGGBBAA` hex in
  §5.1 — floats round-trip exactly so parity is `==` with no 8-bit tolerance.
- **Unknown-kind maps are dropped whole**, not per-cell (resolves §0.2's
  ambiguity): a map silently missing a terrain feature has shifted LOS lanes, so
  withholding it beats offering a subtly-wrong field. Matches the ship precedent.

---

## 1. Goals

1. **Data-driven maps.** The built-in engagement loads from a bundled data file
   (`res://data/maps.json`), not from `TurnEngine._place_terrain()`.
2. **Moddable.** A player (or the author, from 3d-gen) can add or override maps
   by dropping a data file + assets in a known folder — no build step, no editor.
3. **Assets travel with the map.** A map references terrain *kinds*; each kind
   binds to a glb / sprite asset and its LOS/spotting rules. New kinds ship as
   data, so a map pack can introduce a terrain feature the base game never had.
4. **Authorable in 3d-gen.** A new "Maps" surface in the editor lets you set the
   board size, paint terrain cells, preview with the real generated assets, and
   export the map (JSON) + the assets it needs into the game in one action.
5. **Zero churn for the rules.** LOS, spotting, deployment, save/load and the AI
   keep working. Old saves still load.

### Non-goals (this pass)
- Multiple simultaneous maps in one battle, or mid-battle terrain change.
- Procedural/random map generation in-game (3d-gen authors them offline).
- Networked/Workshop distribution. Local folder only, same as ship mods.
- Reworking the movement/impulse or fire model.

---

## 2. Current state (what we build on)

**A "map" today is three hard-coded things:**

- **Board size + deploy rules** — consts on `TurnEngine`: `map_cols = 48`,
  `map_rows = 48` ([`turn_engine.gd:37`](src/rules/turn_engine.gd:37)),
  `DEPLOY_ZONE_COLS = 24`, `DEPLOY_MIN_SEPARATION = 10`
  ([`turn_engine.gd:54`](src/rules/turn_engine.gd:54)).
- **Terrain layout** — `terrain: Dictionary` mapping `Vector2i → TerrainDef.Type`,
  populated by the hard-coded [`_place_terrain()`](src/rules/turn_engine.gd:215)
  during `setup_fleet()`.
- **Terrain kinds** — a fixed `enum Type { HILL, TOWER, DUST_STORM }` with static
  rules and render config in [`terrain_def.gd`](src/rules/terrain_def.gd):
  `blocks_los`, `spot_penalty`, `display_name`, `render_color`, `render_height`.

**The assets are discovered by fixed filename scan, keyed off that enum:**

- [`ModelBaker.scan_assets()`](ui/model_baker.gd:56) hard-registers
  `_register(TerrainDef.Type.HILL, "terrain/", "hill", …)` and `TOWER` with
  per-model tuning (`frame`, `span`, `look_y`, `anchor`), scanning
  `hill_1.glb … hill_5.glb`.
- [`DustSprites.scan_assets()`](ui/dust_sprites.gd:24) scans
  `duststorm_1.png … _5.png` + JSON sidecars.

**The pattern to copy already exists — the ship catalog.**
[`ShipCatalog`](src/rules/ship_catalog.gd) is an instance-based (DI) loader that
layers `res://data/{ships,guns}.json` then each `user://mods/<pack>/*.json`
(alphabetical, last-writer-wins by id), validates each entry, and rejects bad
ones loudly. [`ShipLibrary`](src/rules/ship_library.gd) is a thin static facade
(`ship(id)`, `ship_ids()`, `has_ship(id)`) so call sites never change; tests
inject a throwaway catalog via `use_catalog()`. **We build the map catalog the
same way.**

**Save/load already round-trips terrain.**
[`save_game.gd:108`](src/rules/save_game.gd:108) serializes
`engine.terrain.duplicate()`; load restores it verbatim
([`save_game.gd:137`](src/rules/save_game.gd:137)). A save carries its own
terrain, so it stays valid even if the map catalog changes.

**3d-gen already knows how to build + ship assets.**
[`ExportPanel`](../3d-gen/src/ui/ExportPanel.tsx) builds a glb or sprite pair and
POSTs it to the game via [`/api/save`](../3d-gen/vite-plugin-savefiles.ts), which
writes into `assets/<category>/` and maintains `CREDITS.md`. The terrain/building
artifacts a map needs (`hillDef`, `towerDef`, `dustStormDef`, …) already exist in
the [`registry`](../3d-gen/src/artifacts/registry.ts). We add a composition layer
on top and a JSON-merge save path.

---

## 3. The key scope decision

There are two levels of ambition. They were originally framed as sequential
phases; given the goal of continually adding terrain and buildings, they now land
**together** as one foundation (see the revised recommendation below).

- **Map layouts as data.** Maps are data — board size, deploy params, and which
  kind sits on each hex. Removes the hard-coded `_place_terrain()`, gives a map
  picker, and lets 3d-gen author layouts. Small, low-risk, touches almost no
  rules. (§4.)

- **Terrain kinds as data.** The terrain *kinds themselves* become catalog data —
  new kinds with their own LOS/spotting rules and their own asset binding. This
  is the "assets loadable from a catalog" part in full, and the only way to add a
  kind without editing GDScript. `terrain` stops being an `int` enum and becomes a
  **string id**, which touches `TerrainDef`, `ModelBaker`, `DustSprites`, the AI,
  and the save format. (§5.)

**Recommendation (revised — data-driven kinds are core, not deferred).** The
goal is to **keep adding terrain and buildings**, and adding a kind is precisely
what Phase 2 makes a data edit instead of a GDScript edit in three files (enum +
`terrain_def.gd` rules + `ModelBaker._register`). A Phase-1-only catalog can
*reference* the three existing kinds but can't add a fourth without code — so
deferring Phase 2 saves nothing and leaves a throwaway enum layer to rip out
later. **Adopt string-id, data-driven kinds from the start:** build the map
catalog (§4) and the terrain-kind catalog (§5) together as one foundation, with
`terrain{}` keyed by string id from day one. Phase 3 (authoring) then targets the
real kind catalog, so a modder can define a new kind's rules *and* mesh in 3d-gen.

> **Buildings are terrain kinds.** `TOWER` already renders from
> `assets/buildings/` ([`model_baker.gd:60`](ui/model_baker.gd:60)); to the rules
> a building is just a kind with `blocks_los = true`. They need no separate
> catalog — a building is a `terrain.json` entry whose `render.model.dir` points
> at `buildings/`. An optional `category` field ("terrain" | "building") on the
> kind record drives only editor grouping and asset foldering, not rules.

The one thing that *can* still be staged is the **save migration** (§5.3): if
there are no shipped saves in the wild yet, skip the legacy int→id remap entirely
and just adopt string ids. Confirm at review (§9).

---

## 4. Phase 1 — Maps as data (flyers)

### 4.1 Schema — `res://data/maps.json`

```json
{
  "maps": [
	{
	  "id": "dead_sea_bottom",
	  "display_name": "Dead Sea Bottom",
	  "cols": 48,
	  "rows": 48,
	  "deploy_zone_cols": 24,
	  "deploy_min_separation": 10,
	  "terrain": [
		{ "hex": [25, 7], "type": "HILL" },
		{ "hex": [26, 7], "type": "HILL" },
		{ "hex": [27, 5], "type": "TOWER" },
		{ "hex": [28, 8], "type": "DUST_STORM" },
		{ "hex": [29, 8], "type": "DUST_STORM" },
		{ "hex": [29, 7], "type": "DUST_STORM" }
	  ]
	}
  ]
}
```

The bundled `dead_sea_bottom` is a **faithful copy** of today's
`_place_terrain()` + current consts — guarded by a parity test (§7), same
discipline as the ship migration.

### 4.2 New types

- **`MapDef`** (`src/rules/map_def.gd`, a `Resource` like `ShipDef`): fields
  `id`, `display_name`, `cols`, `rows`, `deploy_zone_cols`,
  `deploy_min_separation`, `terrain: Array[Dictionary]` (or a parsed
  `Dictionary[Vector2i,int]`). `to_dict()` / `from_dict()` mirror `ShipDef`.
- **`MapCatalog`** (`src/rules/map_catalog.gd`): instance-based loader modeled on
  [`ShipCatalog`](src/rules/ship_catalog.gd) — load `res://data/maps.json`, then
  `user://mods/<pack>/maps.json` (reuse the same `_scan_mods` walk), validate,
  last-writer-wins by id.
- **`MapLibrary`** (`src/rules/map_library.gd`): static facade — `map(id)`,
  `map_ids()`, `has_map(id)`, `use_catalog()`, `reset_default()` — 1:1 with
  `ShipLibrary`.

### 4.3 Wiring into the engine

`TurnEngine` grows a small `apply_map(map: MapDef)` that sets `map_cols`,
`map_rows`, the two deploy fields (**promote the two consts to vars with the
current values as defaults**, so nothing else breaks), and fills `terrain`.
`_place_terrain()` is deleted; `setup_fleet()` calls `apply_map()` instead — with
a `map_id` param defaulting to the core map so existing tests/`setup(seed)` boot
unchanged.

`is_legal_deploy_hex` / `_in_deploy_band` already read the deploy fields, so once
those are vars, per-map deploy zones work for free.

### 4.4 Choosing a map (UI)

- `BattleConfig` gains a `map_id` (default `dead_sea_bottom`).
- Main menu / battle-config screen adds a map dropdown fed by
  `MapLibrary.map_ids()` → `MapLibrary.map(id).display_name`, mirroring the hull
  list in [`fleet_builder_screen.gd`](ui/fleet_builder_screen.gd:219).
- `map_demo._new_game()` ([`map_demo.gd:418`](ui/map_demo.gd:418)) passes
  `BattleConfig.map_id` into setup.

### 4.5 Save/load

Add `"map_id"` to the save dict ([`save_game.gd:100`](src/rules/save_game.gd:100))
for provenance/UI. Terrain still serializes as part of the save (via the existing
`var_to_str`), but note the correction from §0 decision 9: because cells now carry
**kind ids**, a load **does** depend on the catalog providing those kinds — the
missing-dependency guard (§5.3) declines a save naming an absent kind. This
replaces the earlier "loads don't depend on the catalog" claim, which was written
against the int-enum representation.

---

## 5. Data-driven terrain kinds (flyers) — part of the foundation

This is what makes *assets* (not just layouts) catalog-driven and lets you add
terrain and buildings without touching GDScript. Per §3 it lands **with** §4 as
one foundation, not as a deferred diff — `terrain{}` is keyed by string id from
the start.

### 5.1 Terrain kinds become data — `res://data/terrain.json`

```json
{
  "terrain": [
    {
	  "id": "hill",
	  "display_name": "Hill",
	  "blocks_los": true,
	  "spot_penalty": 0,
	  "render": {
		"color": "#805926cc", "height": 0.55,
		"model": { "dir": "terrain", "prefix": "hill",
				   "frame": 2.2, "span": 2.0, "look_y": 0.3, "anchor": 0.58 }
      }
    },
    {
	  "id": "tower", "display_name": "Tower", "blocks_los": true, "spot_penalty": 0,
	  "render": { "color": "#6b6b6be0", "height": 1.5,
		"model": { "dir": "buildings", "prefix": "tower",
				   "frame": 2.0, "span": 1.1, "look_y": 0.7, "anchor": 0.72 } }
    },
    {
	  "id": "dust_storm", "display_name": "Dust", "blocks_los": false, "spot_penalty": 1,
	  "render": { "color": "#d9b847_6b", "height": 0.0,
		"sprite": { "prefix": "duststorm", "span": 1.8, "anchor": 0.62 } }
    }
  ]
}
```

This folds every hard-coded number in [`terrain_def.gd`](src/rules/terrain_def.gd)
**and** the per-model tuning currently living in
[`ModelBaker._register`](ui/model_baker.gd:66) into one data record per kind — so
adding a terrain kind is a data edit plus its glb/sprite.

**Schema leaves room for richer rules (decided).** Today only `blocks_los` and
`spot_penalty` exist, but the kind record is an open object: `TerrainCatalog`
reads known fields and ignores/defaults the rest, so future rule fields (partial
LOS, per-kind movement cost, height-based blocking, cover bonus…) can be added to
the JSON and the editor form without a schema break or a data-file rewrite. Model
the loader as "default every unknown field," not "reject unknown fields," so old
packs keep loading as the ruleset grows.

### 5.2 The enum→string-id change (the crux)

- `terrain: Dictionary` changes from `Vector2i → int` to `Vector2i → StringName`
  (the kind id).
- `TerrainDef` becomes a **catalog** (`TerrainCatalog` + `TerrainLibrary` facade,
  same shape as ships): the current static funcs
  (`blocks_los`/`spot_penalty`/`los_clear`/`dust_along`/`render_*`) take a kind
  id and look it up. `los_clear`/`dust_along` keep their signatures but resolve
  ids instead of switching on the enum.
- **Callers to touch** (all mechanical): `damage_resolver.gd`, `ship_state.gd`
  (`guns_bearing_from`, `fire_preview`), `ship_ai.gd`, and the two render passes
  in [`hex_map.gd`](ui/hex_map.gd:624) that switch on `TerrainDef.Type`.
- **`ModelBaker` / `DustSprites` become catalog-driven:** instead of hard-coded
  `_register` calls, they iterate `TerrainLibrary` kinds and register from each
  kind's `render.model` / `render.sprite` block. Keying moves from the int enum
  to the string id. (These already gate on "model present," so a kind with no
  shipped asset simply falls back to the procedural prism/token — no regression.)

### 5.3 Save format

**Decided: no saves exist in the wild, so there is no migration.** `terrain{}` is
string-keyed from the start — serialize kind ids directly, no int→id remap, no
`SAVE_VERSION` dance. Do add the missing-dependency guard already used for
ships/guns ([`save_game.gd:_missing_dependency`](src/rules/save_game.gd)) so a
save that names a terrain kind (or map) no catalog provides — e.g. after a mod is
removed — declines cleanly instead of half-loading.

### 5.4 Loading mod assets from `user://mods/` (core — the modder path)

Since **modders author with 3d-gen and ship a pack** (§6), the game must *load*
that pack's assets, not just its JSON. Today `ModelBaker`/`DustSprites` scan
**`res://assets/...`** only; a released build's `res://` is packed read-only, so
a player's mod glbs/sprites can only live under `user://mods/<pack>/assets/`. Both
scanners therefore must **also** walk each mod pack's `assets/<dir>/`, keyed by
the same kind id the pack's `terrain.json` declares. This is a small, contained
addition (extend the dir list they scan), but it is **required**, not optional —
without it a mod map defines new kinds but renders them as procedural fallbacks.
(This is the loading half; 3d-gen authoring, §6, is the writing half.)

---

## 6. Phase 3 — Authoring maps in 3d-gen

3d-gen today exports one artifact at a time. A map is a *composition*, so this is
a new editor surface, not another `ArtifactDef`.

### 6.1 New "Maps" mode

- Add a top-level **Maps** tab (peer of the artifact category tabs from
  [`registry.CATEGORIES`](../3d-gen/src/artifacts/registry.ts)).
- **3D iso authoring (decided — 3d-gen has no 2D views).** Reuse the existing
  [`Viewport`](../3d-gen/src/viewport/Viewport.tsx): it already renders in the
  game-matched iso rig (`ISO_ELEVATION_DEG = 35`, the pointy-top `HexFootprint` on
  the `Y=0` plane, `OrbitControls`). The Maps view generalizes that single hex
  into a **hex grid** of `cols × rows` footprints on `Y=0`, and instances each
  painted kind's generated mesh at its hex world position — so authoring happens
  in the same 3D scene the game will show, no separate 2D renderer to build.
- **Painting = raycast against the ground plane.** Click maps a pointer ray to a
  hex cell; the selected kind is placed (or cleared) there. The deploy band is
  tinted (reuse the `HexMaskFill` translucent-fill idiom) so legal zones are
  visible while placing; `cols`/`rows` and the two deploy params are numeric
  inputs that resize the grid.
- The palette is the **terrain-kind set**, read from the same `terrain.json` the
  game loads (core kinds + any kinds defined in the pack being edited), so editor
  and game never drift.
- Preview each painted kind using its **existing generator** (`hillDef`,
  `towerDef`, `dustStormDef`, and any building generators already produce the real
  mesh/effect), so the map preview shows the actual in-game assets. Large grids:
  instance meshes and only regenerate a kind's geometry once, reused per cell.

### 6.1a Defining kinds in the editor (modders don't hand-edit JSON)

Because modders use 3d-gen as the sole authoring tool, the Maps surface must let
them **define a terrain/building kind**, not just place existing ones: pick a
generator (existing artifact) or a saved mesh, set the rule fields
(`blocks_los`, `spot_penalty`, `category`) and the render tuning
(`frame`/`span`/`look_y`/`anchor`), and add it to the pack's `terrain.json`. This
reuses the artifact generators 3d-gen already has; the new part is the small form
that writes a kind record. A kind with no rules set defaults to a passive,
non-blocking decoration.

### 6.2 Map data model (TS)

A `MapDoc` type mirroring the game schema (§4.1): `id`, `displayName`, `cols`,
`rows`, `deployZoneCols`, `deployMinSeparation`, `cells: {q,r,kind}[]`. A
serializer emits exactly the game's `maps.json` entry shape. A `MapDoc` can be
saved/loaded locally as `*.map.json` (reuse the [`presets`](../3d-gen/src/export/presets.ts)
download/upload pattern) so work-in-progress maps persist.

### 6.3 Export path — JSON merge, not file overwrite

The existing [`/api/save`](../3d-gen/vite-plugin-savefiles.ts) *overwrites* files
in `assets/<category>/`. A map must **merge into** `data/maps.json` by id (add or
replace one entry, keep the rest) and land in `data/`, not `assets/`. Two clean
options:

- **Extend the save plugin** with a `maps` category whose handler reads
  `data/maps.json`, upserts the entry by `id`, and writes it back (create the
  file if absent). Terrain assets the map references are exported through the
  *existing* per-artifact path, unchanged.
- **One-click "Export Map"** in the editor that (a) upserts the map JSON via the
  new endpoint, then (b) for each terrain kind used, runs the current glb/sprite
  export so the assets are present. Report which files were written, same as
  `ExportPanel` does today.

`CATEGORY_DIRS` in both [`saveToGame.ts`](../3d-gen/src/export/saveToGame.ts) and
the plugin gains a `maps → data` (JSON-merge) entry; the plugin branches on it to
the merge handler instead of the raw file write.

### 6.4 Pack export (primary modder deliverable)

Since 3d-gen is the modder's tool, **"Export as mod pack" is a first-class flow**,
not an afterthought: it writes a self-contained `user://mods/<pack>/` tree —
`maps.json`, `terrain.json` (the kinds the pack defines), and `assets/<dir>/…`
(the glbs/sprites those kinds reference) — matching exactly what the game-side
scanners load (§5.4) and the mod-catalog layering already expects
(`user://mods/<pack>/`). Dropping that one folder into another player's
`user://mods/` gives them the map, its kinds, and its art. The `data/`-merge path
(§6.3) is the same operation aimed at the author's own `res://data` during
development; pack export aims it at a fresh pack dir instead.

---

## 7. Testing

- **Parity:** a test asserts the bundled `dead_sea_bottom` `MapDef` reproduces
  exactly today's `map_cols/rows`, deploy consts, and the six terrain cells from
  `_place_terrain()`, and that the three core kinds in `terrain.json` reproduce
  today's `TerrainDef` rules + `ModelBaker` tuning — proves zero drift, same
  discipline as the ship parity test.
- **Catalog layering:** `MapCatalog.new(temp_dir)` over a throwaway mod folder —
  a new id adds, an existing id overrides in place, a malformed entry is rejected
  loudly and the rest survive (mirror `test_rules` catalog coverage).
- **Deploy zones:** every shipped map keeps the starting rosters legal
  (`setup_rosters` still deploys in-band) — reuse the existing deployment test.
- **Save round-trip:** save→load preserves string-id terrain; a save naming an
  unknown kind or map declines cleanly (the guard walks the flat `terrain` dict).
  No legacy-int migration (no saves exist — §0.9).
- **[CRITICAL regression]** convert `_test_terrain_los` / `_test_terrain_dust` /
  `_test_terrain_fire_preview` / `_test_model_baker` / `_test_dust_sprites`
  ([`test_rules.gd:768`](tests/test_rules.gd:768)+) from `TerrainDef.Type` enum to
  string ids and assert **identical** LOS/spotting/render outcomes — behavior
  parity across the representation change.
- **Referential integrity (§0.2):** a map citing an unknown kind drops that cell
  (or the map) loudly; the rest of the catalog survives.
- **Asset origin (§0.3):** pure path-resolution test — a kind with
  `source_root=user://mods/p` resolves to `p/assets/<dir>/<prefix>_N`.
- **Render-type classifier (§0.6):** `render.sprite`→sprite path,
  `render.model`→mesh path, else procedural — asserted without a live render.
- **Golden fixture (§0.10):** the shared example pack parses on the flyers side
  and round-trips on the 3d-gen side.
- **3d-gen (Vitest, §0.11):** `MapDoc → maps.json` serializer, golden-fixture
  round-trip, and the merge endpoint (upsert adds, same-id replaces, absent file
  is created, other entries preserved).

---

## 8. Suggested landing order

0. **glb-runtime spike (§0.4, §0.16).** Prove `GLTFDocument` can load a `user://`
   glb at runtime into a mountable `Node3D`. Cheap, and it de-risks the whole
   modder-asset story before any of it is built. Independent of steps 1–3.
1. **Foundation — data-driven kinds + shared loader (§5, §0.1, §0.8, §0.15).**
   `CatalogLoader` helper, `ShipCatalog` refactored onto it (parity-guarded),
   `terrain.json` loaded by `MapCatalog`, enum→string-id with the `StringName()`
   sentinel, all switch sites + `ModelBaker`/`DustSprites` catalog-driven, the
   parity + regression tests. **This is one indivisible commit** — the seams
   between "kinds" and "callers" and "baker" do not exist.
2. **Map catalog (§4).** `MapDef` + maps.json in the same `MapCatalog`,
   `apply_map`, `MapLibrary` facade, referential-integrity pass (§0.2),
   `DEFAULT_`-const/instance-var deploy split (§0.7), `map_id` in saves (§0.9).
3. **UI.** Map picker in battle config; `map_demo` uses it.
4. **Mod-asset loading (§5.4, §0.3).** `ModelBaker`/`DustSprites` resolve assets
   by each kind's source root, scanning `user://mods/<pack>/assets/`; mod glb uses
   the step-0 `GLTFDocument` path. The game half of the modder path.
5. **3d-gen authoring (§6, §0.11, §0.12).** Add Vitest; Maps editor (merged-grid +
   InstancedMesh painter) + kind-definition form; dev-save merge export; then
   **pack export** as its own downloadable-zip path (§0.5). End-to-end: modder
   defines a kind, paints a map, exports a pack, another player installs it.

---

## 9. Decisions (locked)

1. **Data-driven kinds are core, not deferred** — the map catalog (§4) and
   terrain-kind catalog (§5) land as one foundation, `terrain{}` string-keyed from
   day one, because the goal is to keep adding terrain and buildings. (§3.)
2. **Buildings are terrain kinds** bound to a `buildings/` asset dir — no separate
   catalog. (§3.)
3. **No save migration** — no saves exist in the wild; adopt string ids directly.
   (§5.3.)
4. **Core data lives in `res://data/`, mods in `user://mods/<pack>/`** — same
   split as ships/guns. (§4, §5, §6.4.)
5. **3d-gen authors in 3D iso**, reusing the existing viewport rig — 3d-gen has no
   2D views. (§6.1.)
6. **Kind schema leaves room for richer rules** — loader defaults unknown fields
   rather than rejecting, so LOS/movement-cost/etc. can be added later without a
   data-file rewrite. (§5.1, §6.1a.)
7. **Modders use 3d-gen**; pack export (§6.4) + mod-asset loading (§5.4) are the
   supported end-to-end modding path.

All prior "remaining for review" items are now resolved in §0 (shared loader →
§0.1; grid performance → §0.12).

---

## 10. What already exists (reused, not rebuilt)

- [`ShipCatalog`](src/rules/ship_catalog.gd) — layered load + mod scan + validate
  + last-writer-wins + `_drop_ships_with_unknown_guns`. **Refactored** onto the
  new shared `CatalogLoader` (§0.1); its integrity pass is the template for §0.2.
- [`ShipLibrary`](src/rules/ship_library.gd) static-facade + DI (`use_catalog`) —
  mirrored by `MapLibrary`.
- [`save_game.gd`](src/rules/save_game.gd) `var_to_str` round-trip + `_missing_dependency`
  — reused; the guard extends to terrain kinds/maps (§0.9).
- [`Viewport.tsx`](../3d-gen/src/viewport/Viewport.tsx) iso rig + `HexFootprint` +
  `HexMaskFill` — the seed the painter generalizes (§0.12).
- [`/api/save`](../3d-gen/vite-plugin-savefiles.ts) + artifact generators — reused
  for the dev-save loop; pack export is a **new** path (§0.5), not a retarget.
- The `ModelBaker`/`DustSprites` optional-asset scan — kept; keying moves from the
  enum to string ids, path resolution gains the source root (§0.3).

## 11. NOT in scope (considered, deferred)

- **In-game map editor / procedural in-game generation** — authoring is 3d-gen
  only.
- **Save migration** — no saves exist (§0.9); if that changes, a one-time int→id
  remap is the follow-up.
- **Mod glb beyond the spike** — if the `GLTFDocument` spike (§0.4) fails, mod
  kinds fall back to PNG sprites and glb mods become a separate effort.
- **Networked / Workshop distribution** — local `user://mods/` + zip only.
- **Richer terrain rules** (partial LOS, movement cost, cover) — schema leaves
  room (§0 decision list item 6) but none are implemented now.
- **`ModelBaker` bake-cache eviction** — see TODO below; not a v1 blocker.
- **Auto-binding render-tuning to a mesh hash** — mitigated by WYSIWYG authoring
  (§0.13); a checksum guard is a possible follow-up, not v1.

## 12. Failure modes (per new codepath)

| Codepath | Realistic failure | Test? | Handled? | User sees |
|---|---|---|---|---|
| `MapCatalog` referential pass | map cites removed mod kind | ✅ §0.2 | ✅ drop cell/map, `push_error` | map absent from picker, log line |
| Mod glb load from `user://` | no `.import` sidecar → `load()` fails | ✅ spike + path test | ⚠️ **depends on spike (§0.4)** | procedural fallback if unhandled |
| enum→string sentinel | `terrain.get(h,-1)` on string keys | ✅ regression | ✅ `StringName()` sentinel | wrong LOS if missed — regression guards |
| Save load w/ unknown kind | mod removed after save | ✅ §0.9 | ✅ declines cleanly | "can't load" message, not a crash |
| Merge endpoint upsert | partial write corrupts `maps.json` | ✅ Vitest §0.11 | ✅ read-modify-write by id | export error, catalog intact |
| Painter at 48×48 | thousands of draw calls | ✅ manual/perf | ✅ merged geo + instancing §0.12 | smooth vs. stutter |

**Critical-gap check:** the one path that is failure-without-a-guarantee is **mod
glb runtime load** — it has a test *plan* but the behavior is unproven until the
spike (§0.4) runs. That is why the spike is landing step 0 and gates only the
mod-asset story, not the data layer.

## 13. Parallelization (worktrees)

| Lane | Steps | Modules | Depends on |
|---|---|---|---|
| A | Step 0 glb spike | `ui/model_baker.gd` (throwaway probe) | — |
| B | Step 1 foundation | `src/rules/*` (catalog, terrain, engine), `ui/{model_baker,dust_sprites,hex_map}` | — |
| C | Step 5 Vitest + editor scaffold | 3d-gen `src/**` | — (schema fixture only) |

- **Launch A + B + C in parallel.** A is a tiny independent probe; C is a
  different repo; B is the flyers data layer.
- **Then sequential:** Step 2 (map catalog) → Step 3 (UI) both ride on B's
  string-id `terrain{}`, same `src/rules` + `ui` modules → **one lane after B**.
- **Merge A into B** before Step 4 (mod-asset loading needs the spike's
  `GLTFDocument` path).
- **Conflict flag:** Steps 1–4 all touch `ui/model_baker.gd` — keep them one
  sequential lane after the spike merges; do not parallelize within flyers `ui/`.

## 14. Implementation Tasks
Synthesized from this review's findings. Each derives from a specific finding.

- [x] **T1 (P1, human: ~3h / CC: ~30min)** — model_baker — glb-runtime spike ✅ **PASSED 2026-07-01**
  - Surfaced by: Outside voice #1 / §0.4 — `load()` can't read a `user://` glb
  - Files: [`tests/spike_runtime_glb.gd`](tests/spike_runtime_glb.gd) (kept as a regression guard)
  - Result: 10/10 checks — negative control confirmed (`ResourceLoader` refuses a
    sidecar-less `user://` glb), `GLTFDocument.append_from_file` + `generate_scene`
    loads it into a `Node3D` with real geometry (hill AABB 1.79×0.55×1.80), and
	`PackedScene.pack()` wraps the result — so `ModelBaker`'s `Array[PackedScene]`
	contract needs **zero type change** for mod kinds (only the construction path
	differs). Note: `pack()` requires setting `owner` on descendants first.
- [ ] **T2 (P1, human: ~1d / CC: ~1h)** — src/rules — shared `CatalogLoader` + `MapCatalog`
  - Surfaced by: Step 0 scope / §0.1 — three parallel catalog stacks
  - Files: `src/rules/catalog_loader.gd` (new), `ship_catalog.gd` (refactor), `map_catalog.gd` (new), `map_library.gd` (new), `map_def.gd` (new)
  - Verify: ship parity test still green; `MapCatalog` layering test passes
- [x] **T3 (P1, human: ~1d / CC: ~1h)** — src/rules+ui — enum→string-id ✅ **DONE (`ed36dce`)**
  - Surfaced by: §0.8 / Outside voice #4 — sentinel + hot-path callers
  - Files: `terrain_def.gd` (→ catalog facade), `turn_engine.gd`, `ui/hex_map.gd`, `ui/model_baker.gd`, `ui/map_demo.gd`, `terrain_kind_def.gd`, `data/terrain.json`, `tests/test_rules.gd`
  - Result: `terrain{}` now `Vector2i → StringName`; `TerrainDef` is a static facade over `MapLibrary.kind`; `ModelBaker` catalog-driven (keyed by id, source_root paths); `hex_map` branches on `is_sprite()` render-type, not a dust id; `render.footprint` data-drives the prism radius. `damage_resolver`/`ship_state`/`ship_ai` needed **no change** (they call `TerrainDef.los_clear/dust_along`, signatures unchanged). `_test_terrain_los/dust/fire` converted to string ids assert identical outcomes; suite **495/0**; `map_demo` boots and renders hills/tower/dust identically in overhead **and** isometric (3D bake + dust sprites verified visually). `DustSprites` per-kind sprite sheets + mod glb loading remain T5.
- [ ] **T4 (P1, human: ~3h / CC: ~20min)** — src/rules — referential integrity + `apply_map`
  - Surfaced by: Issue 1 / §0.2 — unknown-kind cell handling
  - Files: `map_catalog.gd`, `turn_engine.gd` (`apply_map`, `DEFAULT_` consts §0.7)
  - Verify: unknown-kind map drops loudly; `dead_sea_bottom` parity test
- [ ] **T5 (P2, human: ~4h / CC: ~30min)** — ui — asset-origin path resolution + render_type
  - Surfaced by: Issue 2 / Issue 5 / §0.3 / §0.6
  - Files: `ui/model_baker.gd`, `ui/dust_sprites.gd`, `ui/hex_map.gd`
  - Verify: path-resolution + render-type classifier unit tests
- [ ] **T6 (P2, human: ~3h / CC: ~30min)** — save — map_id + kind dependency guard
  - Surfaced by: §0.9 / Outside voice #3 — save consistency
  - Files: `src/rules/save_game.gd`
  - Verify: round-trip test; unknown-kind save declines
- [ ] **T7 (P1, human: ~1d / CC: ~2h)** — 3d-gen — Vitest + serializer + merge endpoint
  - Surfaced by: Issue 6 / §0.10 / §0.11 — no test infra; merge corrupts catalog
  - Files: 3d-gen `package.json`, `vitest.config.ts`, `src/export/*`, `vite-plugin-savefiles.ts`, shared golden fixture
  - Verify: serializer, golden round-trip, upsert-by-id tests green
- [ ] **T8 (P2, human: ~2-3d / CC: ~half-day)** — 3d-gen — Maps painter (merged grid + InstancedMesh)
  - Surfaced by: §6 / §0.12 / §0.14 — the 3D-iso authoring surface
  - Files: 3d-gen `src/viewport/*`, new `src/ui/MapsTab.tsx`, kind-definition form
  - Verify: paints/erases at 48×48 without frame drops; exports valid pack
- [ ] **T9 (P2, human: ~1d / CC: ~1h)** — 3d-gen — pack export (zip) + install docs
  - Surfaced by: Outside voice #2 / §0.5 — dev-save is source-only
  - Files: 3d-gen `src/export/*`, README (per-OS `user://mods/` path)
  - Verify: exported zip installs into `user://mods/` and the map loads in a shipped build

---

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 0 | — | — |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR (PLAN) | 10 issues, 0 critical gaps, all folded |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **Outside voice:** Codex not installed → Claude subagent ran. Surfaced 9 findings
  incl. **1 CRITICAL** (`user://` glb runtime-load impossible via `load()` — verified
  against `.import`/`.scn` mechanics) the section reviews missed. All folded into §0.
- **CROSS-MODEL:** one tension (#7, defer the 3D-iso painter) — user kept the painter
  in v1; all other outside-voice findings accepted (no disagreement).
- **VERDICT:** ENG CLEARED — plan hardened, ready to implement (spike §0.4 first).

NO UNRESOLVED DECISIONS
