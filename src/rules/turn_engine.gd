class_name TurnEngine
extends RefCounted
## Orchestrates the turn sequence. Owns the game state; the UI and the AI are
## both clients that respond to its signals and feed it decisions.
##
## Turn sequence (simplified from SFB's 32 impulses to 8):
##   1. ALLOCATION  — each side assigns crew (guns / engine / damage control)
##   2. PLOT        — each side sets its speed change
##   3. MOVEMENT    — 8 impulses; ships move on impulses given by the chart,
##                    interleaved so faster ships weave around slower ones
##   4. FIRE        — declare and resolve gunnery (simultaneous: all shots
##                    declared before any damage is applied)
##   5. UPKEEP      — reload ticks, buoyancy enforcement, victory check

enum Phase { ALLOCATION, PLOT, MOVEMENT, FIRE, UPKEEP, GAME_OVER }

const IMPULSES_PER_TURN := 8

signal phase_changed(phase: Phase)
signal impulse_advanced(impulse: int, moved_ships: Array)
signal shot_resolved(report: Dictionary)
signal damage_control_repaired(ship: ShipState, tanks_remaining: int)
signal game_over(winning_side: int, reason: String)

var ships: Array[ShipState] = []
var turn_number: int = 1
var phase: Phase = Phase.ALLOCATION
var rng := RandomNumberGenerator.new()

## Terrain for this engagement: maps hex position to TerrainDef.Type.
## Hills and towers block LOS (shots declared through them do not fire).
## Dust storms add a spotting penalty to the to-hit roll (cancelled by
## lookout crew in the firer's allocation).
var terrain: Dictionary = {}

## Playfield: a roughly rectangular hex field. Column q holds rows
## r in [map_row_offset(q) .. +map_rows-1]. Ships may not leave it — this is a
## rule (enforced in legal_moves_for), not a UI nicety. It is large on purpose:
## the camera follows the ships, so the edge is effectively never in view and
## the field reads as open, while a finite board keeps movement deterministic
## and stops a crippled flyer from fleeing forever.
var map_cols: int = 48
var map_rows: int = 48

## Movement sequencer state, owned here so every client (UI, AI, tests) shares
## one impulse sequence. Driven via begin_movement()/next_mover().
var current_impulse: int = 0
var _movement_queue: Array[ShipState] = []

## Pending simultaneous fire declarations:
## Array of { "firer": ShipState, "mount": int, "target": ShipState }
var _fire_queue: Array[Dictionary] = []


func setup(seed_value: int = 0) -> void:
	if seed_value != 0:
		rng.seed = seed_value
	# Start well inside the large field (same relative pose as before, shifted to
	# the middle) so neither flyer is anywhere near an edge.
	ships.assign([
		ShipState.create(ShipLibrary.ship(&"helium_scout"), 0, Vector2i(20, 10), 1),
		ShipState.create(ShipLibrary.ship(&"zodanga_cruiser"), 1, Vector2i(32, 4), 4),
	])
	_place_terrain()
	_set_phase(Phase.ALLOCATION)


func _place_terrain() -> void:
	terrain.clear()
	# Hill ridge crossing the main approach lane between the starting positions.
	# Ships at (20,10) and (32,4) converge through roughly (26,7); the ridge
	# forces each captain to decide whether to punch through (and eat a shot
	# from the exposed side) or bank around the flanks.
	terrain[Vector2i(25, 7)] = TerrainDef.Type.HILL
	terrain[Vector2i(26, 7)] = TerrainDef.Type.HILL
	# Ruined tower on the NE flank — blocks LOS and gives cover to a flanking
	# scout trying to work around the cruiser.
	terrain[Vector2i(27, 5)] = TerrainDef.Type.TOWER
	# Dust storm region near the cruiser's side. Flying through here costs a
	# +1 per hex on every shot, but lookout crew cancel it — good position for
	# the scout's torpedo run if the cruiser retreats into the dust.
	terrain[Vector2i(28, 8)] = TerrainDef.Type.DUST_STORM
	terrain[Vector2i(29, 8)] = TerrainDef.Type.DUST_STORM
	terrain[Vector2i(29, 7)] = TerrainDef.Type.DUST_STORM


# ---------------------------------------------------------------------------
# Movement: the impulse chart. A ship at speed S moves on impulse i when the
# cumulative fraction S*i/8 crosses an integer — the classic SFB distribution,
# so a speed-4 ship moves on impulses 2,4,6,8 and a speed-8 ship on all eight.
# ---------------------------------------------------------------------------

static func moves_on_impulse(speed: int, impulse: int) -> bool:
	return (speed * impulse) / IMPULSES_PER_TURN > (speed * (impulse - 1)) / IMPULSES_PER_TURN

## Legal moves for one ship on its impulse. Returns an array of
## { "hex": Vector2i, "facing": int, "kind": "straight"|"port"|"starboard" }.
## `blocked` hexes (other ships) cannot be entered — flyers collide.
static func legal_moves(ship: ShipState, blocked: Array[Vector2i] = []) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if ship.grounded or ship.is_destroyed:
		return out
	# Continue straight, if the hex is clear.
	var ahead := HexMath.neighbor(ship.hex, ship.facing)
	if not ahead in blocked:
		out.append({ "hex": ahead, "facing": ship.facing, "kind": "straight" })
	# Turning requires satisfying turn mode; a turn is a facing change of 1
	# combined with moving into the NEW facing's hex.
	if ship.can_turn():
		var port := (ship.facing + 5) % 6
		var stbd := (ship.facing + 1) % 6
		var port_hex := HexMath.neighbor(ship.hex, port)
		var stbd_hex := HexMath.neighbor(ship.hex, stbd)
		if not port_hex in blocked:
			out.append({ "hex": port_hex, "facing": port, "kind": "port" })
		if not stbd_hex in blocked:
			out.append({ "hex": stbd_hex, "facing": stbd, "kind": "starboard" })
	return out

## The playfield rectangle: column q runs from map_row_offset(q) for map_rows.
func map_row_offset(q: int) -> int:
	return -(q >> 1)

## Is this hex on the board? A movement rule — a flyer can't leave the field.
func map_contains(hex: Vector2i) -> bool:
	if hex.x < 0 or hex.x >= map_cols:
		return false
	var off := map_row_offset(hex.x)
	return hex.y >= off and hex.y < off + map_rows

## Convenience: legal moves with every other live ship's hex blocked AND any
## move that would leave the playfield dropped. The bounded set the UI and AI
## both act on.
func legal_moves_for(ship: ShipState) -> Array[Dictionary]:
	var blocked: Array[Vector2i] = []
	for s in ships:
		if s != ship and not s.is_destroyed:
			blocked.append(s.hex)
	var out: Array[Dictionary] = []
	for m in legal_moves(ship, blocked):
		if map_contains(m["hex"]):
			out.append(m)
	return out

func execute_move(ship: ShipState, move: Dictionary) -> void:
	if move["facing"] == ship.facing:
		ship.straight_moved += 1
	else:
		ship.straight_moved = 0
	ship.hex = move["hex"]
	ship.facing = move["facing"]


# ---------------------------------------------------------------------------
# Impulse sequencer. The engine owns the 8-impulse cadence so the UI, AI and
# tests all step through one shared sequence instead of each re-deriving it.
# Drive it as: begin_movement(), then repeatedly next_mover() — each call hands
# back the next ship that must move (caller picks/executes the move, AI or
# player), or null when the turn's impulses are spent.
# ---------------------------------------------------------------------------

func begin_movement() -> void:
	current_impulse = 0
	_movement_queue = []
	_set_phase(Phase.MOVEMENT)

## The next ship owed a move, advancing the impulse counter as needed. Emits
## impulse_advanced(impulse, movers) as each new impulse opens. Returns null
## once all IMPULSES_PER_TURN impulses are exhausted. Ships destroyed/grounded
## mid-turn are skipped; a returned ship may still have no legal move (boxed in
## or hard against the map edge) — the caller checks legal_moves_for and, if
## empty, simply calls next_mover() again.
func next_mover() -> ShipState:
	while true:
		if _movement_queue.is_empty():
			current_impulse += 1
			if current_impulse > IMPULSES_PER_TURN:
				return null
			var movers: Array[ShipState] = []
			for s in ships:
				if moves_on_impulse(s.speed, current_impulse) \
						and not s.is_destroyed and not s.grounded:
					movers.append(s)
			_movement_queue = movers
			impulse_advanced.emit(current_impulse, movers)
			continue
		var s: ShipState = _movement_queue.pop_front()
		if s.is_destroyed or s.grounded:
			continue
		return s
	return null   # unreachable; satisfies the typed-return analyzer


# ---------------------------------------------------------------------------
# Fire phase: declarations are collected from both sides, then resolved
# together so neither side gets a "shoot first, remove return fire" edge.
# ---------------------------------------------------------------------------

func declare_fire(firer: ShipState, mount_index: int, target: ShipState) -> void:
	_fire_queue.append({ "firer": firer, "mount": mount_index, "target": target })

func resolve_fire_phase() -> void:
	# Snapshot validity at declaration time is already guaranteed by
	# guns_bearing(); resolution applies damage in declaration order but no
	# ship's destruction cancels already-declared return fire.
	for decl in _fire_queue:
		var report := DamageResolver.resolve_shot(
				decl["firer"], decl["mount"], decl["target"], rng, terrain)
		shot_resolved.emit(report)
	_fire_queue.clear()
	_check_victory()


# ---------------------------------------------------------------------------
# Upkeep and victory
# ---------------------------------------------------------------------------

func run_upkeep() -> void:
	for s in ships:
		s.tick_reloads()
		# Damage control runs BEFORE the falling-line check: each allocated DC
		# crew gives a 1-in-3 chance to patch one buoyancy tank (armor is never
		# repairable). A flyer sitting right on its falling line can thus be
		# lifted back above it this turn — clawing back from the brink — rather
		# than settling while its crew still has the tanks half-patched.
		for _i in int(s.allocation.get("damage_control", 0)):
			if s.sys(ShipDef.SystemType.BUOYANCY) < s.def.system_count(ShipDef.SystemType.BUOYANCY) \
					and rng.randi_range(1, 6) >= 5:
				s.systems_remaining[ShipDef.SystemType.BUOYANCY] += 1
				# Patch the lower side to reduce the list; port first when equal.
				if s.port_buoyancy <= s.stbd_buoyancy:
					s.port_buoyancy += 1
				else:
					s.stbd_buoyancy += 1
				damage_control_repaired.emit(s, s.sys(ShipDef.SystemType.BUOYANCY))
		# ...then settle onto the dead sea bottom if still at/below the line.
		s.enforce_buoyancy()
	turn_number += 1
	_check_victory()
	if phase != Phase.GAME_OVER:
		_set_phase(Phase.ALLOCATION)

func _check_victory() -> void:
	for s in ships:
		# Crew wiped out — no one left to fly the ship.
		if not s.is_destroyed and not s.grounded and s.crew_pool() == 0:
			s.is_destroyed = true
		if s.is_destroyed or s.grounded:
			var winner := 1 - s.side
			_set_phase(Phase.GAME_OVER)
			game_over.emit(winner,
					"%s %s" % [s.def.display_name,
					"destroyed" if s.is_destroyed else "forced to ground"])
			return

func _set_phase(p: Phase) -> void:
	phase = p
	phase_changed.emit(p)
