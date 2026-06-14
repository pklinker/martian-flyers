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
signal fire_changed(ship: ShipState, fires: int, note: String)
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


## Legacy / zero-arg entry point: the classic scout-vs-cruiser duel centred on
## the large field (neither flyer anywhere near an edge). Existing tests and
## demos call setup(seed) and must boot unchanged — they opt into fleets by
## calling setup_fleet()/setup_rosters() instead.
func setup(seed_value: int = 0) -> void:
	setup_fleet([
		{ "ship_id": &"helium_scout", "side": 0, "hex": Vector2i(20, 10), "facing": 1 },
		{ "ship_id": &"zodanga_cruiser", "side": 1, "hex": Vector2i(32, 4), "facing": 4 },
	], seed_value)


## Fleet-driven setup: lay out an arbitrary roster of ships. `fleets` is a list
## of placement dictionaries — each
##   { ship_id: StringName, side: int, hex: Vector2i, facing: int }
## Placement is a rules concern, not a UI nicety: every ship must deploy on the
## board (map_contains) and no two ships may stack (the collision rule). A
## requested hex that is off-board or already taken is nudged to the nearest free
## legal hex, so any caller-supplied roster always deploys somewhere valid.
func setup_fleet(fleets: Array, seed_value: int = 0) -> void:
	if seed_value != 0:
		rng.seed = seed_value
	var built: Array[ShipState] = []
	var occupied: Array[Vector2i] = []
	for p in fleets:
		var want: Vector2i = p.get("hex", Vector2i(map_cols / 2, map_rows / 2))
		var hex := _deploy_hex(want, occupied)
		occupied.append(hex)
		built.append(ShipState.create(
				ShipLibrary.ship(p["ship_id"]),
				int(p.get("side", 0)), hex, int(p.get("facing", 0))))
	ships.assign(built)
	_place_terrain()
	_set_phase(Phase.ALLOCATION)


## Convenience for the common case: two rosters of ship ids laid out on opposing
## deployment lines either side of the field centre, each line facing the enemy.
## Builds placements and defers to setup_fleet (so the no-stack / on-board rules
## still apply).
func setup_rosters(side0: Array, side1: Array, seed_value: int = 0) -> void:
	var cx := map_cols / 2
	var placements: Array = []
	# Side 0 deploys west of centre facing NE (1) toward the enemy; side 1 east of
	# centre facing SW (4). Ships on a line are spread two hexes apart so the
	# deploy nudge rarely has to fire, but it still guards against any overlap.
	for i in side0.size():
		placements.append({ "ship_id": side0[i], "side": 0,
				"hex": Vector2i(cx - 6, 16 + i * 2), "facing": 1 })
	for i in side1.size():
		placements.append({ "ship_id": side1[i], "side": 1,
				"hex": Vector2i(cx + 6, 8 + i * 2), "facing": 4 })
	setup_fleet(placements, seed_value)


## The nearest legal, unoccupied deploy hex at or spiralling out from `want`.
## Respects map_contains and the no-stack rule (occupied list). Falls back to the
## requested hex only if the whole field is somehow full (never in practice).
func _deploy_hex(want: Vector2i, occupied: Array[Vector2i]) -> Vector2i:
	if map_contains(want) and not want in occupied:
		return want
	var max_radius := maxi(map_cols, map_rows)
	for radius in range(1, max_radius):
		for h in _hex_ring(want, radius):
			if map_contains(h) and not h in occupied:
				return h
	return want


## The hexes exactly `radius` away from `center`. Used only by deploy placement,
## so a simple bounding-box scan (correct, tiny radii) beats a clever ring walk.
func _hex_ring(center: Vector2i, radius: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dq in range(-radius, radius + 1):
		for dr in range(-radius, radius + 1):
			var h := center + Vector2i(dq, dr)
			if HexMath.distance(center, h) == radius:
				out.append(h)
	return out


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
		# A fouled rudder works itself free a little each turn.
		if s.steering_jammed > 0:
			s.steering_jammed -= 1
		_run_damage_control(s)
		_burn_fires(s)
		# ...then settle onto the dead sea bottom if still at/below the line.
		s.enforce_buoyancy()
	turn_number += 1
	_check_victory()
	if phase != Phase.GAME_OVER:
		_set_phase(Phase.ALLOCATION)


## Damage control runs BEFORE the falling-line check (so a flyer on the line can
## claw back) and BEFORE fires burn (so a crew can save a box). Each allocated DC
## crew acts once: while any fire burns it fights the fire (priority — a fire
## spreads), otherwise it patches a buoyancy tank. Armor is never repairable.
func _run_damage_control(s: ShipState) -> void:
	var buoy_total := s.def.system_count(ShipDef.SystemType.BUOYANCY)
	# A station shot away can't work damage control — cap effective parties at the
	# surviving DC boxes (apply_allocation already gates the allocation; this keeps
	# the rule true even if state is set up directly, e.g. in tests or on load).
	var dc_crew: int = mini(int(s.allocation.get("damage_control", 0)), s.damage_control_capacity())
	for _i in dc_crew:
		if s.fires > 0:
			if rng.randi_range(1, 6) >= DamageResolver.FIRE_DOUSE_ROLL:
				s.fires -= 1
				fire_changed.emit(s, s.fires, "damage control beats out a fire")
		elif s.sys(ShipDef.SystemType.BUOYANCY) < buoy_total and rng.randi_range(1, 6) >= 5:
			s.systems_remaining[ShipDef.SystemType.BUOYANCY] += 1
			# Patch the lower side to reduce the list; port first when equal.
			if s.port_buoyancy <= s.stbd_buoyancy:
				s.port_buoyancy += 1
			else:
				s.stbd_buoyancy += 1
			damage_control_repaired.emit(s, s.sys(ShipDef.SystemType.BUOYANCY))


## Each fire still burning after damage control eats one internal box (via the
## DAC) and may spread to a fresh fire. Snapshot the count so fires born this
## turn (by spread) wait until next turn to burn.
func _burn_fires(s: ShipState) -> void:
	var burning := s.fires
	for _i in burning:
		if s.is_destroyed or s.fires == 0:
			break
		var rep := DamageResolver.apply_fire_damage(s, rng)
		var note := "fire burns"
		var internals := rep["internals"] as Array
		if not internals.is_empty():
			note = "fire burns — %s: %s" % [internals[0]["system"], internals[0]["effect"]]
		fire_changed.emit(s, s.fires, note)
		if not s.is_destroyed and s.fires < DamageResolver.MAX_FIRES \
				and rng.randi_range(1, 6) >= DamageResolver.FIRE_SPREAD_ROLL:
			s.fires += 1
			fire_changed.emit(s, s.fires, "the fire spreads")

## A ship out of action is one that's been destroyed, grounded, or had its crew
## wiped (no one left to fly it). The single predicate the victory check and the
## living-ship queries share, so UI/AI never re-derive "is this ship done".
func is_out_of_action(s: ShipState) -> bool:
	return s.is_destroyed or s.grounded or s.crew_pool() == 0

## The ships still flying for a side (empty when the whole side is out).
func living_ships(side: int) -> Array[ShipState]:
	var out: Array[ShipState] = []
	for s in ships:
		if s.side == side and not is_out_of_action(s):
			out.append(s)
	return out

## Does a side still have at least one flyer in the fight?
func side_alive(side: int) -> bool:
	for s in ships:
		if s.side == side and not is_out_of_action(s):
			return true
	return false

## Victory is now side-based: the engagement ends only when an entire side is
## out of action, not the instant one ship falls. A crew-wiped ship is first
## marked destroyed (so it wrecks and signals like any loss), then we tally which
## sides still have a flyer. One side left → it wins; both emptied in the same
## resolution → a draw (side -1).
func _check_victory() -> void:
	if phase == Phase.GAME_OVER:
		return
	# Crew wiped out — no one left to fly the ship; mark it a loss.
	for s in ships:
		if not s.is_destroyed and not s.grounded and s.crew_pool() == 0:
			s.is_destroyed = true
	# Which sides are present, and which of them still have a live ship?
	var side_has_live: Dictionary = {}
	for s in ships:
		if not side_has_live.has(s.side):
			side_has_live[s.side] = false
		if not is_out_of_action(s):
			side_has_live[s.side] = true
	if side_has_live.size() < 2:
		return   # a single-side (or empty) field has nothing to win against
	var alive_sides: Array[int] = []
	for side in side_has_live:
		if side_has_live[side]:
			alive_sides.append(side)
	if alive_sides.size() >= 2:
		return   # at least two sides still flying — the battle continues
	_set_phase(Phase.GAME_OVER)
	if alive_sides.size() == 1:
		game_over.emit(alive_sides[0], _victory_reason(alive_sides[0]))
	else:
		# Mutual wipeout in the same resolution — neither side is left standing.
		game_over.emit(-1, "Both fleets are wiped out — a mutual rout")


## Genre-voice summary of the defeated side for the combat log / game-over modal.
func _victory_reason(winner: int) -> String:
	var lost: Array[String] = []
	for s in ships:
		if s.side != winner:
			lost.append(s.def.display_name)
	if lost.size() == 1:
		return "%s out of action" % lost[0]
	return "the opposing fleet is out of action"

func _set_phase(p: Phase) -> void:
	phase = p
	phase_changed.emit(p)
