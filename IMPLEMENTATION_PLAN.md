# Barsoom Flyers — Implementation Plan

*Status as of June 2026. Companion document: `GAME_DESIGN.md`.*

A turn-based, single-player tactical game for macOS in the style of Star Fleet
Battles, using flyers from the John Carter of Mars novels. Built in **Godot 4**
(developed against 4.6.x) with GDScript.

---

## 1. Architecture

The non-negotiable principle: **a pure rules engine with the UI and AI as
clients.** The engine never renders or reads input; UI scenes never compute
rules — they ask the engine and draw the answers. The AI consumes the same
public API the UI does.

```
rules/   pure game logic, no rendering, no input, fully headless-testable
ai/      ShipAI — a doctrine-driven client; reads engine state, returns decisions
ui/      Control-based scenes that observe engine state via signals
tests/   headless SceneTree test runner (CI-friendly exit codes)
docs/    this plan + game design document
```

Key structural decisions already in force:

- **Template vs. state split.** `ShipDef`/`GunDef` are immutable Resources
  (the blank printed SSD). `ShipState` is the marked-up copy in play. This
  makes new-game, save/load, and AI lookahead (clone state, simulate) cheap.
- **Damage is capability erosion, never hit points.** All combat effects flow
  through derived-capability queries on `ShipState`:
  `effective_max_speed()` (engine-box ceiling), `usable_max_speed()`
  (that ceiling gated by engine-room crew this turn), `turn_mode()`,
  `is_buoyant()`, `guns_bearing()`, `max_speed_change()`. UI and AI call these;
  nothing computes rules locally.
- **Seeded RNG injected everywhere** (`RandomNumberGenerator` passed into
  `DamageResolver`, owned by `TurnEngine`). Deterministic replays,
  reproducible bug reports, Monte Carlo AI evaluation.
- **Simultaneous fire.** All declarations collected into a queue, then
  resolved; destruction does not cancel already-declared return fire.
- **Signals are the engine→UI channel:** `ShipState.damage_taken`,
  `ShipState.destroyed`, `TurnEngine.shot_resolved`,
  `TurnEngine.damage_control_repaired` (a buoyancy tank patched at upkeep — so
  the sheet's tank count recovering isn't mistaken for a glitch),
  `TurnEngine.phase_changed`, `TurnEngine.game_over`,
  `TurnEngine.impulse_advanced` (emitted by the engine's movement sequencer as
  each impulse opens).

## 2. File inventory (DONE)

### rules/

| File | Contents | State |
|---|---|---|
| `hex_math.gd` | Static hex math: axial coords (flat-top, facing 0 = north, clockwise 0..5), `distance`, `neighbor`, `bearing` (snaps to nearest of 6 sectors), `relative_bearing`, `struck_facing` | Done, tested |
| `gun_def.gd` | `GunDef` Resource: size enum (L/M/H), `reload_turns`, `crew_required`, range brackets `{max_range, to_hit, damage}`, `bracket_for_range()`, `max_range()`, plus **torpedo flags** (`is_torpedo`, `ammo`, `armor_piercing`) so a tube reuses the entire gun path | Done, tested |
| `ship_def.gd` | `ShipDef` Resource: `SystemType` enum (BUOYANCY, ENGINE, PROPELLER, RUDDER, BRIDGE, CREW, MAGAZINE, DAMAGE_CONTROL), per-facing armor array, system box counts, gun mounts (gun id + arc list + label), base speed, `speed_per_engine_crew` (engine-crew power rate), grounding threshold (the "falling line"), turn-mode-by-speed table, **named `officers` roster** (struck down on bridge/crew criticals) | Done, tested |
| `ship_state.gd` | Runtime state: position/facing/speed, armor remaining per facing, system boxes remaining, gun mount states (destroyed/reload/manned), crew allocation, derived-capability functions: `effective_max_speed()` / `usable_max_speed()` (engine-crew gated) / `engine_crew_for_speed()`, `guns_bearing()`, `fire_preview()` (per-mount shot preview with reason when it can't fire), `apply_allocation()`, `tick_reloads()`, `enforce_buoyancy()` (grounds the ship at/below the falling line); per-mount **torpedo ammo** in `gun_states[i]["ammo"]` (-1 = a gun's infinite supply), gating empty tubes in `gun_ready`/`fire_preview`; **critical state** (`fires`, `steering_jammed` — gates `can_turn()`, `officers` roster + `pop_officer()`) | Done, tested |
| `damage_resolver.gd` | Gunnery: to-hit roll per range bracket, armor absorption on struck facing (never repairs, never negative), **armour-piercing bypass for torpedoes** (AP points punch through plating without marking it off), overflow rolls on the weighted DAC, magazine explosion (5+ on d6 per magazine hit), hulk rule, reload start, **torpedo ammo consumed on launch**, **secondary criticals** (engine/magazine fire on 6, rudder jam on 5+, named officer struck on bridge/crew hits) + `apply_fire_damage` (a fire's per-upkeep burn, no chain-ignite); each report carries `firer_hex`/`target_hex` (UI tracer endpoints, never read back by rules). Static, RNG injected | Done, tested |
| `ship_library.gd` | Concrete v1 data built in code (static vars + lazy build): light/medium/heavy radium guns, **aerial radium torpedo** (3-shot, AP 3, dmg 6/6/5 to range 11, 3-turn reload), four ship classes — Helium Scout Flyer (bow torpedo tube), Zodangan Patrol Cruiser, **One-Man Flyer** (fast, eggshell, one light gun), **Helium Battleship** (five-heavy broadside, deep crew) — each with an officer roster. Migration path to `.tres` noted | Done, tested |
| `save_game.gd` | `SaveGame` — the engine's persistence layer. Serializes a `TurnEngine` (every `ShipState`, RNG seed+state, turn/phase, terrain, in-flight movement/fire queues as ship indices) to a Dictionary / string / file and restores it; `ShipDef` rebuilt from `ShipLibrary` by id, never serialized. `var_to_str` wire format (round-trips `Vector2i`/int-keyed dicts), `SAVE_VERSION` guard rejects corrupt input. Pure, no rendering/input | Done, tested |
| `turn_engine.gd` | Phase enum (ALLOCATION/PLOT/MOVEMENT/FIRE/UPKEEP/GAME_OVER), 8-impulse chart (`moves_on_impulse`: SFB fractional distribution), engine-owned movement sequencer (`begin_movement`/`next_mover`, emits `impulse_advanced`), playfield bounds rule (`map_cols`/`map_rows`/`map_contains`), `legal_moves(ship, blocked)` with collision blocking + `legal_moves_for(ship)` (collision **and** bounds filtered), turn-mode enforcement via `straight_moved`, fire queue, upkeep (reloads, **steering-jam tick**, then damage control — **fires first** (douse at 4+) then buoyancy patch at 5+ (emits `damage_control_repaired`), then **fires burn** via the DAC and may spread (emits `fire_changed`), **then** the falling-line grounding check so a flyer on the line can claw back), victory check (destroyed OR grounded) | Done, tested |

### ai/

| File | Contents | State |
|---|---|---|
| `ship_ai.gd` | `ShipAI` — a doctrine-driven opponent and pure client of the engine. Per-class doctrine weight table (`for_ship`, with entries for all four classes); one-ply positional utility evaluator `_eval_position` (range-band fit, own guns bearing, enemy guns denied, weak-facing protection, **armour awareness**: `w_penetrate` aims at the enemy's thinnest/already-breached facing — since internals only flow once a facing is stripped — and `w_hole` refuses to present an own holed facing); per-turn `allocate` (engine crew for desired speed → **a hand reserved per active fire** → guns → DC), `plot`, `choose_move` (best resulting position), `choose_fire` (**every bearing deck gun — chipping armour is never wasted**; a finite **torpedo only on ≤4 to-hit AND against hard armour ≥3** — once a facing is breached the deck guns exploit it for free, so the AP fish is hoarded for plating they can't crack). `allocate` **mans a torpedo tube first when the enemy is within reach** (the scout's main punch earns crew before the deck guns). `noise` hook + per-class weights = difficulty lever; deeper lookahead/Monte-Carlo is future | Done, tested |

### tests/

| File | Contents | State |
|---|---|---|
| `test_rules.gd` | `extends SceneTree` headless runner, 115 assertions across: hex math, impulse chart, turn mode + collision blocking, **map bounds (engine rule prunes off-field moves), impulse sequencer (`begin_movement`/`next_mover` cadence + `impulse_advanced` emission)**, range brackets, arcs, `guns_bearing_from`, `fire_preview` (bears/reasons/to-hit), engine-crew speed gate (`usable_max_speed`), reload/crew allocation, armor absorption, DAC determinism, magazine explosion, **torpedoes (armour-piercing bypass + plate not marked off; finite-ammo depletion, empty-tube gating, "no torpedoes" preview, deck guns unaffected)**, buoyancy grounding at the falling line, **DC repair feedback (`damage_control_repaired` fires per tank) + claw-back ordering (DC patches before the grounding check)**, capability erosion, **criticals (steering jam gates `can_turn`/legal moves + upkeep tick-down; fire ignition/burn/spread/douse; named officer casualties from bridge & crew hits), new ship classes (one-man flyer + battleship invariants and seeded AI battles)**, **AI evaluator doctrine preferences (incl. armour awareness: presses a stripped enemy facing, hides own holes, hoards AP torpedoes for hard armour) + a 5-seed ShipAI-vs-ShipAI battle (decisive, no deadlock, invariants)**, **save/load (field-by-field engine round-trip, RNG determinism across a save boundary, file I/O, version/garbage rejection)**, **shot-report tracer metadata (`firer_hex`/`target_hex`)**, and a full greedy smoke battle. Exit code 0/1 | Done, **231/231 passing** on Godot 4.6.3 |
| `ai_scan.gd` | Dev tool (not part of the suite): runs N ShipAI-vs-ShipAI battles on the engine's own bounded field (`engine.legal_moves_for`) and prints the win split / timeouts / avg turns. `-- N` for count, `-- 1 v` to trace one. The "200-seed battle scan" the validation methodology calls for. Baseline after criticals + armour-aware AI: **scout 8% / cruiser 92%, ~0.5% timeout, avg ~10 turns** | Tool |

Run: `godot --headless --path . -s res://tests/test_rules.gd`

### ui/

| File | Contents | State |
|---|---|---|
| `ssd_panel.gd` | `SSDPanel` (Control, custom `_draw`): data-driven SSD sheet for any `ShipState`. Spatial armor layout (bow top / stern bottom / port left / stbd right), system box rows, gun rows with 6-sector arc roses, reload pips, manned dots, destroyed strike-through; **torpedo tubes shown as `[T]` with an AP note and ammo diamonds** (filled = racked, hollow = loosed); pencil-shaded boxes with red X marked off from the right; struck-facing flash (0.6 s); live status footer (**plus a red FIRES / STEERING JAMMED critical line**); DESTROYED/GROUNDED banner; **a top-down hull armor diagram** (the ship outline drawn down the middle with each facing's plating laid against the matching hull edge; authored `assets/ships/<id>_profile.{png,svg}` overrides the drawn hull). Zero rules logic | Done, renders |
| `ssd_demo.gd` / `ssd_demo.tscn` | Two ships nose-to-nose at range 2; volley / exchange / next-turn / new-game buttons; combat log. All through engine signals | Done |
| `hex_map.gd` | `HexMapView` (Control): flat-top grid matching `HexMath` geometry exactly, a **follow-camera** that frames the live ships each draw (holds a comfortable default zoom and scrolls to keep them centered, zooming out only when they separate; grid culled to the viewport, `clip_contents`), pixel↔hex with cube rounding (round-trip verified), defers `contains()` to `engine.map_contains` (rules own the bounds), ship tokens (facing arrow, side color, active ring, wreck X), legal-move highlights with resulting-facing ticks, `move_clicked`/`hex_clicked`/`map_pressed` signals; **a transient combat-effects layer** (`add_tracer`/`add_flash`/`clear_effects`): fading firer→target shell/torpedo streaks and expanding hit/explosion bursts, animated on `_process` and self-stopping when idle. Zero rules logic | Done |
| `main_menu.gd` / `main_menu.tscn` | **Boot scene.** Parchment-and-ink title splash (scout/cruiser facing glyphs over an ink rule), Start Engagement → `change_scene_to_file` into the map, Quit. No rules or state — pure navigation | Done |
| `sound_bank.gd` | `SoundBank` (Node): loads procedurally-synthesized radium SFX from `assets/audio/` and plays them by name (`fire`/`hit`/`explosion`) on a small per-cue player pool with pitch jitter. Missing files degrade silently. Pure presentation, client of engine signals | Done |
| `map_demo.gd` / `map_demo.tscn` | **First playable build.** Player flies the Scout vs greedy AI cruiser. Flow: ALLOCATE (man guns / engine room → caps top speed / damage control against the crew pool; live budget + resulting top-speed readout, Confirm gated when over) → PLOT (speed +/- bounded by `max_speed_change` and `usable_max_speed`) → MOVE (8 impulses, click green hexes on player impulses, AI auto-moves) → FIRE (per-gun toggle with `fire_preview` to-hit/damage; out-of-arc/range/unmanned guns greyed with reason) → upkeep → repeat. Movement is driven by the engine's shared sequencer (`begin_movement`/`next_mover`). AI reserves engine crew for its intended speed, then mans guns, and fires everything bearing. Map fills the view; both SSDs in a toggleable right-edge overlay (Hide/Show Ships) so the hex field is never cut off; combat log bottom. A centered VICTORY/DEFEAT modal with a Play Again button closes the loop | Done, playable |

## 3. Hard-won GDScript conventions (READ BEFORE WRITING CODE)

These were each discovered as an actual bug. Do not regress them.

1. **Never assign an untyped array literal to a typed array variable or
   property.** `ship.armor = [3, 2, 1]` into an `Array[int]` can fail at
   runtime. Always use `typed_array.assign([...])` (used throughout
   `ship_library.gd` and `turn_engine.setup`).
2. **Lambdas capture locals by value.** Reassigning a captured `int`/`String`
   inside a signal-connected lambda does NOT propagate out. Mutate a captured
   Dictionary/Array instead (see `result["winner"]` in the smoke test).
3. **Don't index raw array literals where typed inference matters.**
   `["L","M","H"][gun.size]` caused trouble; use
   `PackedStringArray(["L","M","H"])[gun.size]` (fix is in `ssd_panel.gd`).
4. **Greedy `min()` tie-breaking caused a real emergent deadlock:** two ships
   that joust past each other never turn around (straight always wins ties)
   and fly apart forever. Movement scoring must include a
   nose-on-target tiebreak: `distance * 10 + min(rb, 6 - rb)`.
5. **Ships must not stack.** `legal_moves` takes a `blocked` hex list;
   at range 0 `relative_bearing` returns -1 and no gun bears. Use
   `legal_moves_for()` which blocks all live ships.
6. **Integer division** `/` on two ints is integer division in GDScript
   (relied on by the impulse chart) — keep operands typed int.
7. Headless `-s` runs leave `ShipLibrary` statics populated at exit → benign
   "ObjectDB instances leaked / resources still in use" warnings. Ignore, or
   add `ShipLibrary.reset()` before `quit()` if the noise matters.
8. Tests may call underscore-prefixed methods (`DamageResolver._apply_damage`,
   `_roll_internal`) for determinism. Tests only; clients never do.

## 4. Validation methodology

- Unit + integration tests in `tests/test_rules.gd`; keep extending it with
  every new rule. The smoke battle doubles as an invariant fuzzer (no
  negative box counts) and a balance probe.
- When Godot can't be executed where you're working, cross-validate hand
  computations by porting the formula to Python and running it (this caught
  multiple arithmetic and logic issues). A 200-seed Python battle scan
  produced: **cruiser 88% / scout 10% / ~2% timeout** under greedy AI — not a
  balance verdict (greedy AI charges into heavy-gun range), but the baseline
  to beat.

## 5. Roadmap (TO DO)

### Phase A — finish the playable core

*(June 2026: altitude bands were cut from the design — buoyancy now grounds a
ship directly at its per-class falling line. See GAME_DESIGN.md §2/§3.)*

- [x] **Crew allocation UI** for the player — ALLOCATE phase in `map_demo`:
	  per-gun manning toggles (cost shown) + **engine-room stepper** (caps this
	  turn's top speed via `usable_max_speed`) + damage-control stepper against
	  the crew pool, live `used / pool` budget and resulting top-speed readout,
	  Confirm gated when over. Engine crew now powers speed (`speed ≤
	  engine_crew × speed_per_engine_crew`), so the scout can't run flat-out and
	  man every gun — the SFB power economy in crew terms.
- [x] **Per-gun fire declaration UI** — FIRE phase: one toggle per gun that
	  bears, captioned with `fire_preview` (range, to-hit, damage); guns that
	  can't fire are greyed with the reason (out of arc / range / unmanned /
	  reloading). Holding a heavy keeps it off cooldown. (Target picking is
	  trivial in 1v1; revisit when multiple enemies exist.)
- [x] Emit and use `TurnEngine.impulse_advanced`; movement driver moved into
	  the engine (`begin_movement()` / `next_mover()`) so the UI, AI and tests
	  share one impulse sequencer. The demo's loop now just executes (AI) or
	  hands off (player) each ship the engine hands back; `impulse_advanced` is
	  emitted as each impulse opens.
- [x] Map bounds as a real rule — the playfield rectangle lives in `TurnEngine`
	  (`map_cols`/`map_rows`, `map_contains`); `legal_moves_for` drops any move
	  that would leave the field. The view reads its field from the engine and
	  defers `contains()` to `map_contains`; no UI-side bounds filtering remains.
	  The field is now **large (48×48) with ships starting centred**, and the
	  view's follow-camera keeps the edge out of frame — so it reads as open sky
	  while a flyer can never get pinned against a wall with no legal move (the
	  original cramped 16×12 board could box a ship into the corner).
- [x] End-of-game screen / restart flow — centered VICTORY/DEFEAT modal with
	  genre-voice flavor, plus Play Again and Main Menu buttons (`map_demo`).
- [x] Basic main menu — `main_menu` is now the boot scene (parchment-and-ink
	  splash, scout/cruiser glyphs, Start Engagement / Quit). The map demo gains
	  a top-bar **Menu** button and a Main Menu option on the game-over modal, so
	  the menu↔match loop is reachable both ways.

### Phase B — depth
- [x] **Torpedoes** — the scout's answer to armor and the fix for the Phase C
	  balance finding. Implemented as a **flag on `GunDef`** (`is_torpedo`,
	  `ammo`, `armor_piercing`) rather than a parallel class, so tubes reuse the
	  whole gun path — arcs, `guns_bearing`, `fire_preview`, `resolve_shot`.
	  **Finite ammo** lives per-mount in `ShipState.gun_states[i]["ammo"]`
	  (-1 = a gun's infinite supply), consumed on launch, gated by `gun_ready`
	  (empty tube can't fire; preview reason "no torpedoes"). **Armour-piercing**
	  threads through `_apply_damage`: AP points bypass plating on the struck
	  facing (and aren't marked off — the armour is punched through, not
	  destroyed). The **Aerial Radium Torpedo** (`aerial_torpedo`): 3-shot rack,
	  AP 3, dmg 6/6/5 out to range 11, 3-turn reload, 2 crew; a bow tube on the
	  scout. SSD draws a `[T]` mount with AP note and **ammo diamonds** (filled =
	  racked, hollow = loosed); fire UI labels the shot `AP/[n left]` and leaves
	  it **off by default** (spending a torpedo is deliberate); `ShipAI` mans the
	  tube first when in reach and looses only on ≤4 to-hit (salvo discipline).
	  **Result: scout 2% → ~9–10%** in the 200-battle scan — a real threat, the
	  cruiser still favoured, deck-gun numbers untouched. Keep d6.
- [x] **Terrain**: hills (block LOS), ruined towers, dust storms (spotting
	  penalties; pairs with lookout crew allocation). Six terrain hexes placed
	  across the midfield: a two-hex hill ridge + one ruined tower blocking
	  the direct approach, three-hex dust storm on the cruiser's flank.
	  `TerrainDef` (new `rules/terrain_def.gd`): Type enum (HILL/TOWER/DUST_STORM),
	  `los_clear`, `dust_along`, `blocks_los`, `spot_penalty`, render colors.
	  `HexMath.line_hexes`: lerp-and-round LOS path with vertex-tie nudge.
	  `fire_preview`/`guns_bearing(_from)` accept optional `terrain` dict; LOS-
	  blocked shots report reason "LOS blocked" and drop out of bearing lists.
	  Dust penalty = +1 to-hit per dust hex along the LOS path (target hex
	  included); lookout crew (new allocation key) cancel it 1-for-1.
	  `DamageResolver.resolve_shot` takes terrain: LOS-blocked shots return
	  without consuming ammo or starting reload. `ShipAI._eval_position` and
	  `choose_fire` are terrain-aware. `HexMapView` renders terrain tiles with
	  fill color, heavier border on LOS-blocking types, and a letter label.
	  `map_demo` gains a lookout stepper (shown when dust is on the field).
	  24 new terrain assertions in `test_rules.gd` — suite now 139/139.
- [x] **Port/starboard buoyancy split** → listing: tank imbalance imposes
	  maneuver penalties (the mid-fight cost of buoyancy damage).
- [x] **Critical-hit color** — secondary criticals layered onto the DAC, all
	  still capability erosion on the same sheet, all d6. **Steering jams**: a
	  rudder internal hit on 5+ fouls the rudder (`ShipState.steering_jammed`);
	  `can_turn()` returns false while jammed, so the flyer can only fly straight
	  until it works free (ticked down at upkeep). **Fires**: an engine or (non-
	  exploding) magazine hit on a 6 ignites a fire (`ShipState.fires`, capped at
	  `MAX_FIRES`); each fire burns one internal box via the DAC at upkeep and may
	  spread (6) — `DamageResolver.apply_fire_damage` (which can't itself ignite,
	  so no chain-reaction) routes the burn through the normal `damage_taken`
	  signal. Damage control fights fires **before** patching tanks (a spreading
	  fire is the worse threat), each DC crew dousing one fire on 4+; the AI
	  reserves a hand per active fire before manning guns. **Named officers**: a
	  `ShipDef.officers` roster — a bridge hit always strikes one down by name, a
	  crew hit claims one on a 6; the box loss is the mechanical effect, the name
	  is genre-voice narration in the report `effect`. New `TurnEngine.fire_changed`
	  signal feeds the combat log; `SSDPanel` shows a red FIRES/STEERING JAMMED
	  line. 17 new assertions in `test_rules.gd`.
- [x] **More ship classes** — two hulls added to `ShipLibrary` (data-driven, so
	  each gets a working SSD and AI for free): the **One-Man Flyer** (`one_man_flyer`,
	  base speed 9, crew 3, one light bow gun — the extreme end of the scout's
	  crew squeeze) and the **Helium Battleship** (`helium_battleship`, armour
	  7/6/6/5/6/6, a five-heavy broadside + stern medium, crew 20, sluggish turn
	  table — the heavy brawler). Both carry officer rosters and a `ShipAI`
	  doctrine (one-man kites the light gun's outer band; battleship brawls
	  broadside-on). `.tres` migration stays deferred until editing stats outside
	  code is actually wanted (the mechanism in the plan, not a need yet). Tests
	  cover class invariants and seeded AI battles (battleship-vs-cruiser
	  decisive; one-man-vs-scout clean). Also **fixed the stale `ai_scan.gd`**: it
	  still re-derived the old cramped 16×12 board and froze every ship at the new
	  centred starts — it now defers to `engine.legal_moves_for`. Post-criticals
	  scan: **scout 7% / cruiser 92%, 2 timeouts, avg 10.5 turns** (criticals
	  restored the scout from the open-board ~0% — fires and torpedo crits make
	  the cruiser bleed).
	  **Multi-ship fleets and the points-buy that composes them are now their own
	  phase — see Phase F.**

### Phase C — a real AI
- [x] Replaced greedy scoring with a utility evaluator (`ai/ship_ai.gd`):
	  preferred range band per ship (kite vs brawl), arc-keeping (keep broadsides
	  bearing / deny enemy arcs), protect weakest facing, withdraw when crippled.
	  The cruiser now actively turns to present its broadside; the band term cured
	  the old fly-apart deadlock (0 timeouts over 200 battles).
- [x] **Armour-aware combat doctrine.** Damage is per-facing ablative — armour
	  on the struck facing absorbs (and depletes) and **no internal damage flows
	  until that facing is stripped to zero** (overflow on the breaking shot is
	  kept; AP torpedoes and fires bypass by design). The evaluator now exploits
	  this: `w_penetrate` rewards striking the enemy's thinnest/already-breached
	  facing (so the AI keeps pounding one facing until it caves rather than
	  circling onto fresh plate), `w_hole` refuses to present an own holed facing,
	  and `choose_fire` fires **every** bearing deck gun (chipping armour is never
	  wasted) but spends a finite AP torpedo only on hard armour (≥3) the guns
	  can't crack — hoarding the fish and letting deck guns exploit a breach.
	  Scan after the change: **scout 8% / cruiser 92%, ~0.5% timeout, avg ~10
	  turns** (cruiser still rightly dominant; the scout is a slightly bigger
	  threat for spending torpedoes more wisely). 5 new assertions.
- [ ] Use the seeded engine for shallow lookahead / Monte Carlo rollouts
	  (clone `ShipState`s, simulate candidate plots, score). *Framework is ready
	  (the `noise` hook + cloneable state); the 1-ply evaluator above is what's
	  built.*
- [ ] Difficulty levels = evaluator weights + lookahead depth. *Weights are
	  per-class data and `noise` is wired; presets/menu not yet exposed.*

> **Balance finding (the reason this phase existed).** With the AI now expressing
> doctrine, `ai_scan.gd` reports the **cruiser winning ~98%** of mirror battles —
> *worse* for the scout than the greedy 88% baseline. Tracing shows why, and it's
> a **ship-balance** problem, not an AI one:
> - The scout's light guns do 1 damage at range 5–8, which the cruiser's 4–5
>   armor per facing absorbs completely — **the scout cannot penetrate while
>   kiting.**
> - The cruiser's heavy guns reach **range 18**, so kiting at 5–8 doesn't escape
>   them; the cruiser orbits presenting a broadside and bombards for 5/hit.
>
> This is *working as intended*, not a bug to balance away: a scout has no
> business out-dueling a cruiser with deck guns. The fix is **asymmetric punch —
> give the scout torpedoes** (Phase B, item 1; GDD §7 item 1): a limited-ammo,
> armor-piercing weapon it looses from range, then kites away. The gun/armor
> numbers stay cruiser-favored on purpose. **Do not** rebalance the deck guns to
> let the scout win the brawl — that breaks both ships' identities.
>
> **Torpedoes shipped (Phase B).** With the scout carrying a 3-shot AP torpedo
> tube and the AI using it (man-the-tube-first when in reach, loose on ≤4
> to-hit), the scout has a real mechanism to make a cruiser bleed, the cruiser
> stays the favourite, and the deck-gun/armour numbers were never touched.
>
> **Open-board caveat (after the follow-camera change).** Moving from the
> cramped 16×12 board to the large 48×48 field dropped the scan from **scout
> ~9–10% to ~0%**. The walls had been doing balance work: a boxed-in board
> forced engagements (and the scout's lucky torpedo exchanges) that an open
> field doesn't. On the open board the scout AI kites at the outer edge of its
> band where torpedoes need 5+ to-hit (held by salvo discipline), so it rarely
> looses them. **This is an AI-doctrine / torpedo-tuning gap, not a movement
> bug** — battles still resolve decisively (0 timeouts, avg ~19 turns), the
> *player*-flown scout closes and fires torpedoes fine, and the deck-gun matchup
> is unchanged. Restoring the scout as a credible AI threat on the open board is
> the next balance task: tune the scout doctrine to close into torpedo's ≤4
> bracket (lower `preferred_max`, or a "torpedo run" range when the tube is
> manned and loaded), and/or strengthen the tube (rack/reload/AP). **Do not**
> shrink the board to paper over it — open sky is the intended feel.

### Phase D — polish & ship it
- [x] **Save/load** — `rules/save_game.gd` (`SaveGame`, pure & headless-testable,
	  the engine's persistence layer). Serializes a `TurnEngine` — every
	  `ShipState` (position/facing/speed, per-facing armor, system boxes,
	  gun-mount states incl. **torpedo ammo/reload/manned**, criticals
	  `fires`/`steering_jammed`/`officers`, port/stbd buoyancy, this turn's
	  `allocation`), the **RNG seed + state**, `turn_number`/`phase`, terrain,
	  and the in-flight **movement & fire queues** (stored as indices into
	  `ships`, restored to live references) — to a plain Dictionary, a string,
	  or a file. Wire format is `var_to_str`/`str_to_var` (not JSON) so
	  `Vector2i` keys, nested dicts, and the `SystemType`-keyed system map
	  round-trip natively; the immutable `ShipDef` is **rebuilt from
	  `ShipLibrary` by id**, never serialized (template vs. state split). A
	  `SAVE_VERSION` guard rejects unknown/corrupt input (returns null, never
	  crashes). `map_demo` gains top-bar **Save / Load** buttons (single
	  `user://` quickslot); load re-binds the engine's signals and re-opens
	  ALLOCATE with the saved crew plan carried forward. 28 assertions in
	  `test_rules.gd` (field-by-field round-trip incl. typed-array element types,
	  **RNG determinism** — a restored engine reproduces the next rolls and a
	  saved fire queue resolves to identical damage, file I/O, version/garbage
	  rejection). Suite now **229/229**.
- [x] **Sound, hit flashes, shell tracers.** All presentation, driven by engine
	  signals (the engine gained nothing but two positional fields). `HexMapView`
	  has a transient-effects layer (`add_tracer`/`add_flash`/`clear_effects`):
	  fading firer→target streaks (torpedoes a cooler, thicker bolt) and
	  expanding hit/explosion bursts, animated on `_process` and self-stopping
	  when none are alive. `DamageResolver` now stamps each shot report with
	  `firer_hex`/`target_hex` (UI tracer endpoints, never read back by rules —
	  fleet-safe, no name-matching). `ui/sound_bank.gd` (`SoundBank`) plays
	  procedurally-synthesized radium cues (`assets/audio/{fire,hit,explosion}.wav`,
	  generated CC0, pooled players + pitch jitter, missing files degrade
	  silently). `map_demo._play_shot_effects` wires it all to `shot_resolved`
	  (tracer + fire cue per shot, hit/explosion flash + cue on damage), with a
	  final burst over the stricken flyer at game over (the only effect for a
	  grounding).
- [x] **SSD art pass.** The ARMOR section is now a **top-down hull diagram**
	  (`_draw_armor_diagram`): the ship outline is drawn down the middle and each
	  facing's plating is laid **against the matching hull edge** — bow on the
	  nose, fwd/aft port down the left flank, fwd/aft starboard down the right,
	  stern on the tail. A shared half-beam profile (`HULL_FR`/`HULL_WF`,
	  `_hull_half_beam`) drives both the drawn outline and where the box rows
	  anchor, so plating always hugs the hull; hull length and beam scale with
	  size so each class reads as itself. The code-drawn fallback
	  (`_draw_topdown_hull`: pointed-bow hull, centerline, forward bridge ring,
	  twin aft propeller discs) is overridden by an authored
	  `assets/ships/<id>_profile.{png,svg}` (top-down, nose up) when present.
	  `_layout_height` grew to fit the taller diagram. **See `ART_PLAN.md §5`**
	  for the authoring contract; the remaining items there (tokens, fonts,
	  banners, terrain tiles) are offline art tasks.
- [x] **macOS export preset, icon.** `export_presets.cfg` carries a universal
	  macOS preset (bundle id, version, hardened-runtime entitlements all off —
	  the game needs none, codesign/notarization toggles off with documented
	  placeholders). New ink-and-parchment app icon (`assets/ui/app_icon.svg`, a
	  Helium flyer over a hex; also the project window icon). **Notarization** is
	  Apple-credential- and export-template-gated (templates aren't installed in
	  this environment), so the full signed-build + `notarytool` procedure is
	  documented step-by-step in **`SHIP_MACOS.md`** rather than executed.
### Phase E — Boarding: the deck-battle minigame

The Barsoom endgame and the payoff for the whole crew-allocation economy: when
flyers close to a hexside apart, it comes to grapnels and swords. Two ships lock
together and the camera drops from the open sky to the **decks** — a tactical
sub-battle where the player moves boarding parties against the enemy crew, fights
for the bridge and the key stations, and wins the ship by **capture** rather than
sinking it. This is the one victory condition that *keeps* the enemy hull instead
of destroying it (it becomes a prize you fly — see Phase F).

**Design principles (don't break the spine for the minigame):**
- **Boarding damage is still capability erosion on the same sheet.** Seizing or
  spiking a station marks off the *same* `ShipState` systems the DAC touches —
  spike a gun → that mount goes unmanned/destroyed; take the helm → movement
  control transfers; flood the buoyancy controls → tanks marked off toward the
  falling line; take the bridge → the ship strikes. No parallel hit-point model;
  the deck battle just inflicts the erosion with cutlasses instead of shells.
- **Mirror the engine architecture.** A headless `BoardingEngine` + `DeckState`
  pair, exactly like `TurnEngine`/`ShipState`: pure rules, no rendering/input,
  fully testable; the UI and a deck AI are clients. Deck layouts are data
  (`DeckDef`, a Resource like `ShipDef`) so each hull boards differently. Seeded
  `rng` injected; deterministic replays.
- **Keep d6 and the crew economy.** Every melee roll is a d6. Boarding parties
  are **a crew allocation** competing with guns/engine/DC for the same pool
  (`apply_allocation` already foreshadows it: "later: boarding parties") — send a
  strong party and you can't also fight the air battle. The squeeze holds.
- **Theme test passes hard.** Grapnels, gangway choke-points, swordplay on the
  deck, striking colors, scuttling a doomed prize — this is the most Burroughs
  feature in the game. Lean into the genre voice in the log.

#### E1 — Grapple & break-off (the bridge from air battle to deck battle)

- [ ] **Boarding party as an allocation type.** New `allocation["boarding"]`
	  crew key (alongside `guns`/`engine`/`damage_control`/`lookout`); these are
	  the swordsmen set aside this turn, unavailable to guns or the engine room.
	  Surface it in the ALLOCATE bar with the same live-budget gating.
- [ ] **Grapple declaration & roll (range 1).** Ships can't stack (collision
	  rule), so boarding happens **across a shared hexside** at `HexMath.distance
	  == 1`. Add a grapple action (a new sub-step after FIRE, or a declaration in
	  it): the attacker rolls d6 to hook on, **modified by the speed differential**
	  — a fast-moving target is hard to grapnel (relative speed as the to-hook
	  penalty), a near-stationary one easy. This gives the slow brawler a reason
	  to *want* the clinch and the fast scout a way to refuse it.
- [ ] **Counter-play.** The defender may resist: allocate crew to **cut the
	  grapnel lines** (opposed d6) or use speed to **tear free** at next plot. A
	  ship that doesn't want to be boarded has levers; a ship that does (the
	  cruiser) commits to the clinch.
- [ ] **Grappled state.** Once hooked, the two `ShipState`s are linked: movement
	  frozen (or dragged together as one body), and `BoardingEngine` opens with a
	  `DeckState` for each. Either side may attempt **break-off** at upkeep to drop
	  back into the air duel.

#### E2 — The deck plan & crew squads (the board and the pieces)

- [ ] **`DeckDef` (Resource, data-driven per class).** A small grid (hex or
	  square) laying out the ship's **stations as physical locations**, each mapped
	  to a `ShipDef.SystemType` or gun mount: bridge (command), the gun positions,
	  engine room, magazine, buoyancy/helm controls, and the rail hexes where
	  grapnels attach (the boarding "gangway"). Spawn points for the ship's own
	  crew. Authored per hull so a cruiser's deck is bigger and more defensible
	  than a scout's.
- [ ] **`DeckState` + crew squads.** Runtime state: squad tokens on the grid,
	  each with a **headcount** (drawn from the crew pool / boarding allocation)
	  and a side. Boarders enter across the grappled gangway hex; defenders start
	  at their stations. Squad strength erodes as crew fall — and those losses are
	  the *same* crew that the air-battle `crew_pool()` counts, so a bloody repel
	  still costs you allocation next turn.
- [ ] **Choke points.** Gangways, hatches, and ladders where only N squads can
	  fight abreast — the naval/SFB "hold the breach" mechanic and the defender's
	  main edge. A handful of guards can hold a doorway against a crowd; taking the
	  ship means forcing the choke.

#### E3 — Melee resolution & objectives (the sub-battle rules)

- [ ] **Turn loop & melee (all d6).** Alternating or simultaneous activation:
	  move squads, attack into adjacent enemy squads. Resolve as an opposed/
	  threshold d6 roll weighted by relative headcount (and a defender-on-own-deck
	  edge); losers take casualties removed from the squad. Keep it deterministic
	  through the injected `rng`, like `DamageResolver`.
- [ ] **Station objectives = capability erosion.** Reaching and holding a station
	  for a beat applies its effect to the underlying `ShipState`: **bridge →**
	  command lost, the ship strikes (capture); **gun position →** spike it (mount
	  destroyed/unmanned); **helm →** seize movement control; **engine room →**
	  cut the speed; **magazine →** threaten detonation. Same boxes, marked off the
	  same way the gunnery path marks them.
- [ ] **Morale & striking colors.** When a side's effective deck strength drops
	  below a threshold (or its bridge falls), it **strikes** — surrender ends the
	  deck battle in the boarder's favor without fighting to the last man. A clean,
	  readable end state that isn't a grind.

#### E4 — Outcomes: capture, repel, scuttle (back to the air battle)

- [ ] **Capture.** Boarders win → the enemy hull becomes a **prize**: side flips,
	  surviving boarders crew it, and you now fly it (this is where Phase F's
	  multi-ship control pays off — a capture is just gaining a ship). A capture is
	  a victory condition in scenarios that allow it.
- [ ] **Repel.** Defenders win → surviving boarders are lost or retreat across the
	  gangway; both ships resume the air duel at their (reduced) crew pools.
- [ ] **Scuttle — deny the prize.** A losing defender may **flood buoyancy / fire
	  the magazine** rather than be taken (mark tanks to the falling line, or roll
	  the magazine detonation) — losing the ship but denying the capture. Pure
	  Burroughs drama and a real defender's choice.
- [ ] **Casualty write-back.** Whatever the outcome, deck losses reduce
	  `crew_pool()` for both ships when the air battle resumes — boarding is never
	  free, even when you win.

#### E5 — Deck AI

- [ ] **A deck-tactics client** (a small `BoardingAI`, or a doctrine mode on
	  `ShipAI`): defenders hold the bridge and the chokes and counterattack;
	  attackers mass at the gangway and push the shortest path to the bridge.
	  Doctrine weights + injected noise = difficulty, same pattern as `ship_ai.gd`.
	  Decides grapple/break-off intent too (the cruiser seeks the clinch; the scout
	  cuts free).

#### E6 — Presentation & integration

- [ ] **Deck view.** Reuse the grid renderer for the two decks side by side
	  (joined at the gangway), parchment aesthetic, crew squads as tokens with
	  headcount, station icons that mark off as they're taken — visually echoing the
	  SSD so the player reads boarding as the same kind of erosion. A clear
	  **enter/exit transition** between the air-battle map and the deck minigame.
- [ ] **Genre-voice log.** "Grapnels bite — the cruiser is hooked"; "the Helium
	  guard holds the gangway"; "they have the bridge — she strikes her colors";
	  "rather than yield, her captain fires the magazine."
- [ ] **Scenario hook.** Capture-victory scenarios (cut out a flyer, take the
	  flagship) belong in the Phase F scenario/fleet layer; boarding is the
	  mechanism they're built on.

#### Tests (`test_rules.gd`)

- [ ] Grapple roll vs. speed differential (fast target resists; stationary hooks);
	  cut-lines counter-roll; grappled-state linkage and break-off.
- [ ] Deck melee determinism under a fixed seed; choke-point cap (N-abreast);
	  casualty write-back into `crew_pool()`.
- [ ] Station effects map to the right `ShipState` erosion (spike→mount,
	  bridge→strike, helm→movement, buoyancy→falling line, magazine→detonation).
- [ ] Capture flips the hull's side and it's controllable; scuttle denies the
	  prize; morale/strike threshold ends the battle cleanly.
- [ ] A seeded end-to-end boarding battle (grapple → deck fight → capture) with
	  invariants (no negative headcounts, crew conserved across the boundary).

### Phase F — Multiple ships & points-buy fleets

The leap from a fixed 1v1 to *N*v*M* engagements, and the force-composition
system that decides what those fleets are. Sequence F1 before F2 (the cost
function wants real fleets to validate against), and land both before the
Phase D "ship it" polish — save/load and the SSD art pass should already assume
fleets.

**What is already fleet-ready (do not rebuild):** the engine never assumed two
ships. `TurnEngine.ships` is an `Array[ShipState]`; the impulse sequencer
(`begin_movement`/`next_mover`) collects *all* movers per impulse; the fire
queue (`declare_fire`/`resolve_fire_phase`) is already a list; `legal_moves_for`
blocks against every live ship; and `ShipAI._enemy` already returns the
nearest living enemy ("ready for fleet scenarios"). The work is narrower than it
looks — it lives in setup, the victory rule, the turn-loop drivers, and the UI.

#### F1 — Multiple ships per side

- [x] **Fleet-driven `TurnEngine.setup`.** `setup_fleet(fleets, seed)` takes a
	  list of `{ ship_id, side, hex, facing }` placements; `setup_rosters(side0,
	  side1, seed)` is the convenience that lays two `Array[StringName]` rosters on
	  opposing deployment lines. The legacy zero-arg/seed-only `setup(seed)` now
	  delegates to `setup_fleet` with the classic scout-vs-cruiser pairing, so all
	  existing tests and demos boot unchanged. Deployment placement is a rules
	  concern: `_deploy_hex` spirals out from the requested hex to the nearest free
	  legal hex, respecting `map_contains` and the no-stack collision rule. Tests
	  cover legacy boot, explicit fleets (on-board, no stack, sides/facings),
	  same-hex nudge, off-board nudge, and an N-v-M roster layout (20 assertions).
- [x] **Side-based victory in `_check_victory`.** The one true rules change.
	  `_check_victory` now marks crew-wiped ships destroyed (as before), then
	  tallies which **sides** still have a live ship and declares `game_over` only
	  when an entire side is out of action — losing one ship of several no longer
	  ends the game. The winner is the lone surviving side; a mutual wipeout in the
	  same resolution emits a draw (`side = -1`). A shared `is_out_of_action(ship)`
	  predicate (destroyed / grounded / crew-zero) backs new `living_ships(side)`
	  and `side_alive(side)` queries so UI and AI never re-derive it; an early
	  GAME_OVER guard stops re-declaration. 1v1 behaviour is unchanged (a one-ship
	  side empties on that ship's loss). 14 assertions: queries, no-end-on-partial-
	  loss, full-side wipeout, draw, crew-wipe, and no re-fire.
- [x] **Multi-ship turn loop in `map_demo`.** The scene now fields a fixed 2-v-2
	  (your Scout + One-Man Flyer vs an AI Cruiser + Battleship) and the per-phase
	  loop iterates the player's living ships:
	  - **ALLOCATE / PLOT / FIRE** are per-ship, driven by a **roster strip** (one
		button per living player ship) plus clicking a friendly token on the map.
		Each ship's plan is held in `_alloc`/`_plot_base`/`_fire_choice`+
		`_fire_targets` so the player can revisit any ship before proceeding.
		ALLOCATE tracks per-ship commit (Commit Ship → next uncommitted; Begin
		Plot gated until **every** ship is committed and in budget).
	  - **MOVE** interleaves through `next_mover`; when the engine hands back a
		player ship the scene sets it active, highlights *its* `legal_moves_for`,
		and `_on_move_clicked` executes the awaited ship's move.
	  - **FIRE target picking**: each mount defaults to the nearest enemy it bears
		on (engine `fire_preview`); clicking an enemy token retargets the active
		ship's bearing mounts; reticles mark the chosen targets; `declare_fire`
		resolves every player ship's picks plus every AI ship's. Driven through a
		full 2-v-2 battle headless (all phases, decisive end, no runtime errors).
- [x] **One `ShipAI` per AI ship.** `_bind_engine` builds a `ShipAI.for_ship(def)`
	  per AI-side ship into `ais`; the loop runs each one's `allocate`/`plot`/
	  `choose_move`/`choose_fire` against its nearest enemy. (Focus-fire vs. split
	  across multiple targets stays a future doctrine refinement.)
- [x] **UI rendering for fleets.** `hex_map` gained `set_active_ship` (rings the
	  edited ship outside MOVE) and `set_fire_targets` (red reticles on FIRE
	  targets); ship selection/targeting routes through the existing `hex_clicked`
	  → `_on_hex_clicked` (own ship selects, enemy retargets in FIRE). The SSD
	  overlay grew from two fixed panels to one panel **per ship**, rebuilt per
	  game and scrollable; dead ships stay inspectable (wreck X on the map, sheet
	  still shown). The selectable-thumbnail/tab styling is left as polish.
- [x] **Tests (`test_rules.gd`).** A new **Fleets** suite (40 assertions):
	  `setup_fleet`/`setup_rosters` placement (on-board, no stack, same-hex and
	  off-board nudge, N-v-M rosters); side-based victory (a side with one of two
	  ships left has *not* lost; ends only on full-side wipeout; mutual-wipeout
	  draw; crew-wipe; no re-fire after game over); `living_ships`/`side_alive`
	  queries; a 4-ship mixed-speed `next_mover` cadence (each ship offered its
	  exact chart count, all 8 impulses, impulse-1 and impulse-8 mover counts); and
	  a seeded **2v2 ShipAI battle** through the shared sequencer (5/5 decisive,
	  invariants hold). `ai_scan.gd` gained an `f` flag for a 2v2 NvM scan
	  (side-based win split; baseline: red 100% / blue 0%, 0 timeouts, avg ~6
	  turns — the heavy squadron dominates, the same intended asymmetry as 1v1).

#### F2 — Points-buy fleet composition

Goal: a budget in points; each side spends it on hulls from `ShipLibrary` to
build a fleet. Cost is **derived from the ship's own stats** so every new class
is priced automatically (no hand-tuned number to forget), and the formula is
**deliberately non-linear**. Balance is explicitly *not* a goal yet (per the
design note) — the cost only needs to be monotone in the obvious way (a cruiser
must cost more than a scout) and stable/deterministic.

- [ ] **`ShipDef.point_cost()` — a derived, non-linear cost.** Add a pure
	  function on `ShipDef` (no stored magic number; an optional
	  `@export var point_cost_override` may pin a class later if desired). Sum
	  three capability scores, then bend the curve:
	  - **Offensive capacity.** Over every gun mount, value
		`expected_damage_per_turn × reach × arc_coverage`, where expected damage
		uses the `GunDef` range brackets (`damage` weighted by `to_hit`
		probability), divided by `reload_turns` (a heavy that fires every third
		turn is worth less per turn than its single-shot punch), times the arc
		count (a broadside-and-bow gun is worth more than a fixed bow gun).
		**Torpedoes** price their burst specially: `is_torpedo` × `armor_piercing`
		(AP defeats the armor term entirely, so it is valued at full damage) ×
		finite `ammo` (a 3-shot rack is a fraction of an infinite gun's
		sustained value, but its alpha strike is weighted up).
	  - **Damage absorption.** Total `armor` across facings (this is what makes a
		cruiser expensive), plus buoyancy-tank count (effective hit points before
		grounding) and the key internals (`ENGINE`, `BRIDGE`, `CREW`,
		`DAMAGE_CONTROL`) that keep capability online. `MAGAZINE` is a *liability*
		term (explosion risk) — it may shave cost slightly rather than add.
	  - **Other metrics.** Mobility and command: `base_max_speed` and
		`speed_per_engine_crew` (a flyer that can both run fast *and* fight is
		dear), turn quality from `turn_mode_by_speed` (lower = nimbler = costlier),
		`PROPELLER`/`RUDDER` boxes, and `CREW` pool size (it powers everything via
		allocation).
	  - **Non-linearity (the point of "need not be linear").** Apply convex
		scaling so concentrated power costs a premium: e.g. raise the offensive
		and defensive subtotals to an exponent >1 (or add a quadratic cross-term
		`offense × defense` — a ship that hits hard *and* survives is worth more
		than the sum, the classic glass-cannon-vs-brick asymmetry). This makes one
		cruiser cost *more* than the two scouts whose stats it dominates, which is
		the intended buy-decision tension. Document the exact weights/exponents
		inline as tunables (a `const` weight block), since this phase's job is the
		*mechanism*, not the values.
- [ ] **`FleetBuilder` (rules/, headless).** A pure helper:
	  `available_classes()` (ids + `display_name` + `point_cost`), validate a
	  roster against a budget (`total_cost ≤ budget`), and **AI roster
	  generation** — greedily/randomly fill a budget from the catalog (seeded RNG
	  for reproducibility) so the computer fields a points-matched fleet. No UI,
	  no rendering — tests and the AI driver both call it.
- [ ] **Fleet-builder screen (`ui/`).** A pre-battle scenario screen reachable
	  from `main_menu` (and the game-over "rematch" path): pick a points budget,
	  add/remove hulls for the player side with a live "X / budget spent"
	  readout and the per-class `point_cost` shown on each card; the engine builds
	  the AI's roster via `FleetBuilder` to the same budget. "Launch" hands the
	  two rosters to `TurnEngine.setup(fleets)` (F1). Keep a "Quick Battle"
	  shortcut that skips the builder with a default fleet so the fast path
	  survives.
- [ ] **Tests.** `point_cost()` determinism and ordering (cruiser > scout;
	  adding a gun/armor raises cost; the non-linear term makes one strong hull
	  cost more than two weak hulls summing to the same raw stats); `FleetBuilder`
	  budget validation (rejects over-budget rosters) and seeded AI roster
	  generation (deterministic, within budget, non-empty).

## 6. Working agreements for Claude Code sessions

- Run the test suite before and after every change:
  `godot --headless --path . -s res://tests/test_rules.gd`
- New rules logic goes in `rules/` with tests in the same commit. UI gets no
  rules logic, ever — if a scene needs a fact, add a query to `ShipState` or
  `TurnEngine`.
- Preserve determinism: any new randomness goes through the injected RNG.
- Respect the conventions in §3; they are all regression-tested experience.
