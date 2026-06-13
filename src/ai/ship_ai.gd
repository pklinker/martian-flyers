class_name ShipAI
extends RefCounted
## A doctrine-driven opponent. A *client* of the engine — it reads ship state
## and the same public queries the UI uses, and returns decisions; it never
## mutates rules state directly except through ShipState/TurnEngine methods.
##
## The brain is a one-ply positional utility evaluator. Each turn it:
##   - allocates crew toward the speed its doctrine wants, then mans guns,
##   - plots speed toward its preferred range band,
##   - per movement impulse, picks the legal move that maximises a weighted
##     utility (range-band fit, own guns bearing, enemy guns denied, weak-facing
##     protection), and
##   - fires every gun that bears.
##
## Doctrine is a weight table (see `_doctrine_for`). Difficulty is expressed as
## those weights plus optional score noise — deeper lookahead is a future lever.

var doctrine: Dictionary
var noise := 0.0                       # >0 = sloppier play (easy mode)
var _rng := RandomNumberGenerator.new()

## Salvo discipline: don't spend a finite torpedo on a shot needing worse than
## this on the die. Guns fire freely; torpedoes are hoarded for good odds.
const TORPEDO_MAX_TO_HIT := 4
## Start manning a tube once the enemy is within this margin of its reach, so
## it's loaded and ready as the scout closes rather than a turn late.
const TORPEDO_ARM_MARGIN := 2


static func for_ship(def: ShipDef) -> ShipAI:
	var ai := ShipAI.new()
	ai.doctrine = _doctrine_for(def.id)
	return ai


## Per-class doctrine. Kiters want the outer edge of their gun reach and fear
## being shot; brawlers want to be close with broadsides bearing and shrug off
## return fire. Unknown ships get a balanced mid-range default.
static func _doctrine_for(id: StringName) -> Dictionary:
	match id:
		&"helium_scout":
			# Two-phase torpedo doctrine:
			#   torpedo_run (tube armed: ammo>0 AND reload=0) — close to 3–7 for
			#     a 4+ shot (range≤8) at favorable odds; torpedo_run_w_too_far
			#     overrides the normal "too far" weight so closing overcomes the
			#     enemy-gun avoidance penalty.
			#   default (dry or reloading) — kite at 5–8, the gun band.
			# in_band_speed_fraction 0.75 → cruise speed 6, one faster than the
			#   cruiser's 5, so the scout can hold its band without being pushed out.
			return {
				"preferred_min": 5, "preferred_max": 8,
				"torpedo_run_min": 3, "torpedo_run_max": 7,
				"torpedo_run_w_too_far": 4.0,
				"in_band_speed_fraction": 0.75,
				"w_too_close": 3.0, "w_too_far": 1.5,
				"w_my_guns": 2.0, "w_enemy_guns": 2.5, "w_expose": 1.0,
				"flee_buoyancy_frac": 0.34,
			}
		&"zodanga_cruiser":
			return {
				"preferred_min": 1, "preferred_max": 4,
				"w_too_close": 0.5, "w_too_far": 2.0,
				"w_my_guns": 3.0, "w_enemy_guns": 0.5, "w_expose": 0.5,
				"flee_buoyancy_frac": 0.20,
			}
		&"one_man_flyer":
			# A pure kiter with no torpedo: hold the light gun's outer band and
			# stay out of arc. Fast enough to dictate the range.
			return {
				"preferred_min": 4, "preferred_max": 7,
				"in_band_speed_fraction": 0.75,
				"w_too_close": 3.0, "w_too_far": 1.5,
				"w_my_guns": 2.0, "w_enemy_guns": 2.5, "w_expose": 1.0,
				"flee_buoyancy_frac": 0.34,
			}
		&"helium_battleship":
			# The heaviest brawler: wants its broadside on the target and shrugs
			# off return fire even harder than the cruiser.
			return {
				"preferred_min": 1, "preferred_max": 6,
				"w_too_close": 0.4, "w_too_far": 2.0,
				"w_my_guns": 3.5, "w_enemy_guns": 0.4, "w_expose": 0.5,
				"flee_buoyancy_frac": 0.15,
			}
		_:
			return {
				"preferred_min": 2, "preferred_max": 6,
				"w_too_close": 1.0, "w_too_far": 1.0,
				"w_my_guns": 2.0, "w_enemy_guns": 1.0, "w_expose": 0.5,
				"flee_buoyancy_frac": 0.25,
			}


# ---------------------------------------------------------------------------
# Turn decisions (called by whoever drives the turn loop — demo or test)
# ---------------------------------------------------------------------------

## ALLOCATE: reserve engine crew for the speed doctrine wants, man guns with the
## rest (cheapest first), remainder to damage control.
func allocate(engine: TurnEngine, s: ShipState) -> void:
	var enemy := _enemy(engine, s)
	var want := _desired_speed(s, enemy)
	var pool := s.crew_pool()
	var eng: int = mini(s.engine_crew_for_speed(want), pool)
	var left := pool - eng
	# Hold back a hand per active fire before manning guns — a spreading fire is
	# a worse threat than one more gun this turn. Returned to the gun budget's
	# leftover (it all becomes damage_control) so no crew is wasted.
	var dc_reserve: int = mini(s.fires, left)
	left -= dc_reserve
	var picks: Array[int] = []
	# Priority 1: a torpedo tube that could loose this turn (enemy within reach,
	# rack not empty) earns crew before the deck guns — it's the main punch.
	if enemy != null:
		var dist := HexMath.distance(s.hex, enemy.hex)
		for i in s.def.gun_mounts.size():
			if s.gun_states[i]["destroyed"]:
				continue
			var gun: GunDef = ShipLibrary.gun(s.def.gun_mounts[i]["gun_id"])
			if not gun.is_torpedo or int(s.gun_states[i].get("ammo", 0)) <= 0:
				continue
			if dist <= gun.max_range() + TORPEDO_ARM_MARGIN and left >= gun.crew_required:
				picks.append(i)
				left -= gun.crew_required
	# Priority 2: ordinary deck guns, in index order, with whatever crew is left.
	for i in s.def.gun_mounts.size():
		if i in picks or s.gun_states[i]["destroyed"]:
			continue
		var gun: GunDef = ShipLibrary.gun(s.def.gun_mounts[i]["gun_id"])
		if gun.is_torpedo:
			continue   # tubes are handled above
		if left >= gun.crew_required:
			picks.append(i)
			left -= gun.crew_required
	s.apply_allocation({ "guns": picks, "engine": eng, "damage_control": left + dc_reserve })


## PLOT: step speed toward the doctrine target, bounded by acceleration and the
## crew-gated usable speed.
func plot(engine: TurnEngine, s: ShipState) -> void:
	var enemy := _enemy(engine, s)
	var dv := s.max_speed_change()
	var delta: int = clampi(_desired_speed(s, enemy) - s.speed, -dv, dv)
	s.speed = clampi(s.speed + delta, 0, s.usable_max_speed())


## MOVE: of the legal moves offered this impulse, take the one with the best
## resulting position. `moves` come from `TurnEngine.legal_moves_for` (already
## collision/bounds filtered by the caller).
func choose_move(engine: TurnEngine, s: ShipState, moves: Array[Dictionary]) -> Dictionary:
	var enemy := _enemy(engine, s)
	if enemy == null or moves.is_empty():
		return moves[0] if not moves.is_empty() else {}
	var best := moves[0]
	var best_score := -INF
	for m in moves:
		var score := _eval_position(s, m["hex"], m["facing"], enemy, engine.terrain)
		if noise > 0.0:
			score += _rng.randf_range(-noise, noise)
		if score > best_score:
			best_score = score
			best = m
	return best


## FIRE: shoot every gun that bears (LOS-checked); loose a torpedo only on
## worthwhile odds so the finite salvo isn't squandered on a long-range prayer.
func choose_fire(s: ShipState, enemy: ShipState, terrain: Dictionary = {}) -> Array[int]:
	var out: Array[int] = []
	for i in s.guns_bearing(enemy.hex, terrain):
		var gun: GunDef = ShipLibrary.gun(s.def.gun_mounts[i]["gun_id"])
		if gun.is_torpedo \
				and int(s.fire_preview(i, enemy.hex, terrain)["to_hit"]) > TORPEDO_MAX_TO_HIT:
			continue
		out.append(i)
	return out


# ---------------------------------------------------------------------------
# Evaluation
# ---------------------------------------------------------------------------

## The preferred [min, max] range band for this ship given its live state.
## When a torpedo tube is armed (ammo>0 AND reload=0) the scout shifts to the
## torpedo-run band; otherwise it falls back to the standard kiting band.
func _range_band(s: ShipState) -> Array[int]:
	if doctrine.has("torpedo_run_min"):
		for i in s.def.gun_mounts.size():
			if s.gun_states[i]["destroyed"]:
				continue
			var gun: GunDef = ShipLibrary.gun(s.def.gun_mounts[i]["gun_id"])
			if not gun.is_torpedo:
				continue
			if int(s.gun_states[i].get("ammo", 0)) > 0 \
					and int(s.gun_states[i].get("reload", 0)) == 0:
				return [int(doctrine["torpedo_run_min"]), int(doctrine["torpedo_run_max"])]
	return [int(doctrine["preferred_min"]), int(doctrine["preferred_max"])]


## Utility of putting `s` at (my_hex, my_facing) with `enemy` at its current
## position. Higher is better. Pure — reads state, mutates nothing.
## Pass `terrain` so the evaluator counts only guns with clear LOS.
func _eval_position(s: ShipState, my_hex: Vector2i, my_facing: int, enemy: ShipState,
		terrain: Dictionary = {}) -> float:
	var d := HexMath.distance(my_hex, enemy.hex)
	var band := _range_band(s)
	var lo: int = band[0]
	var hi: int = band[1]
	var in_torpedo_run: bool = doctrine.has("torpedo_run_min") \
			and lo == int(doctrine["torpedo_run_min"])
	# A crippled flyer wants more daylight: shift the band outward.
	if s.sys_fraction(ShipDef.SystemType.BUOYANCY) <= float(doctrine["flee_buoyancy_frac"]):
		lo += 3
		hi += 3

	# When running a torpedo, use a stronger "too far" weight so closing into
	# the shot bracket overcomes the enemy-gun avoidance penalty.
	var w_far: float = float(doctrine["w_too_far"])
	if in_torpedo_run:
		w_far = float(doctrine.get("torpedo_run_w_too_far", w_far))

	var score := 0.0
	if d < lo:
		score -= float(lo - d) * float(doctrine["w_too_close"])
	elif d > hi:
		score -= float(d - hi) * w_far

	# Reward our guns bearing from here (LOS-checked); punish enemy arcs.
	var mine := s.guns_bearing_from(my_hex, my_facing, enemy.hex, terrain).size()
	score += float(mine) * float(doctrine["w_my_guns"])
	var threat := enemy.guns_bearing_from(enemy.hex, enemy.facing, my_hex, terrain).size()
	score -= float(threat) * float(doctrine["w_enemy_guns"])

	# Don't show the enemy a battered or naturally thin facing.
	var struck := HexMath.struck_facing(my_hex, my_facing, enemy.hex)
	var best_armor: int = s.armor_remaining.max()
	score -= float(best_armor - s.armor_remaining[struck]) * float(doctrine["w_expose"])
	return score


## Speed the doctrine wants this turn: sprint when out of the band (to close or
## to open), and when crippled (to run); cruise when holding the band.
## `in_band_speed_fraction` lets fast kiting ships hold their preferred band
## against slower opponents without being pushed below it.
func _desired_speed(s: ShipState, enemy: ShipState) -> int:
	if enemy == null:
		return 0
	if s.sys_fraction(ShipDef.SystemType.BUOYANCY) <= float(doctrine["flee_buoyancy_frac"]):
		return s.effective_max_speed()
	var d := HexMath.distance(s.hex, enemy.hex)
	var band := _range_band(s)
	if d > band[1] or d < band[0]:
		return s.effective_max_speed()
	var frac: float = doctrine.get("in_band_speed_fraction", 0.5)
	return maxi(int(ceil(float(s.effective_max_speed()) * frac)), 1)


## Nearest living enemy (1v1 today; nearest-target ready for fleet scenarios).
func _enemy(engine: TurnEngine, s: ShipState) -> ShipState:
	var best: ShipState = null
	var best_d := 1 << 30
	for o in engine.ships:
		if o.side == s.side or o.is_destroyed or o.grounded:
			continue
		var d := HexMath.distance(s.hex, o.hex)
		if d < best_d:
			best_d = d
			best = o
	return best
