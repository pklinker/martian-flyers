# Barsoom Flyers — Rules Engine Data Model (v1)

A pure rules engine for a Star Fleet Battles–style tactical game using John
Carter flyers. No rendering, no input handling — the Godot UI scenes and the
AI player are both *clients* of this engine.

## Files

| File | Role |
|---|---|
| `rules/hex_math.gd` | Static hex grid math: distance, bearings, firing arcs, struck facings |
| `rules/gun_def.gd` | Static template for a gun type (range brackets, reload, crew) |
| `rules/ship_def.gd` | Static template for a ship class — the blank SSD sheet |
| `rules/ship_state.gd` | Runtime state — the pencil marks on the SSD, plus position/speed |
| `rules/damage_resolver.gd` | Gunnery rolls, armor absorption, the Damage Allocation Chart |
| `rules/ship_library.gd` | Concrete data: 3 gun sizes, Helium Scout, Zodangan Cruiser |
| `rules/turn_engine.gd` | Turn/phase orchestration, impulse movement chart, victory |

## Core design decisions

**Template vs. state.** `ShipDef`/`GunDef` are immutable Resources (the
printed SSD); `ShipState` is the marked-up copy in play. This makes "new
game," save/load, and AI lookahead (clone the state, simulate) all trivial.

**Damage is capability erosion, never hit points.** All combat effects flow
through derived-capability functions on `ShipState`: `effective_max_speed()`
(engine-box ceiling), `usable_max_speed()` (gated by engine-room crew this
turn), `turn_mode()`, `is_buoyant()`, `guns_bearing()`, `fire_preview()`. The
UI asks these questions; it never computes rules itself.

**Armor = directional facings (per your change).** Six facings indexed by
relative bearing, absorbs first, never repairs, never hit internally.

**Buoyancy = the hull.** The DAC's most common result. Each ship class has a
grounding threshold (its "falling line"); holed down to it, the ship is
*grounded*, which is a loss condition — fights can end with a crippled flyer
settling onto the dead sea bottom rather than exploding.

**Seeded RNG injected everywhere.** Deterministic replays, reproducible bug
reports, and Monte Carlo AI evaluation come free.

**Simultaneous fire.** All shots declared, then resolved — no first-mover
advantage inside a fire phase.

**Crew as the energy-allocation analog.** Each turn crew boxes are assigned
to gun mounts (required to fire), the engine room (`usable_max_speed` =
`engine_crew × speed_per_engine_crew`, capped by the engine-box ceiling), and
damage control. You can't run the engine flat-out *and* man every gun *and*
patch tanks — pick. Crew casualties from the DAC shrink the pool — the SFB
power-curve feel, in Barsoom terms.

## Deliberately deferred

- Terrain (hills, ruined towers) and map bounds
- Boarding actions at range 0 (the endgame Barsoom demands)
- Port/starboard tank split for listing/trim penalties
- Multiple ships per side; points-based fleet building
- `.tres` resource files instead of code-built ship library

## Wiring it into Godot 4

Drop `rules/` into the project; all classes use `class_name` so they're
globally available. `TurnEngine` is the single entry point:

```gdscript
var engine := TurnEngine.new()
engine.shot_resolved.connect(_on_shot)   # combat log / SSD updates
engine.game_over.connect(_on_game_over)
engine.setup(12345)                       # seed for reproducibility
```
