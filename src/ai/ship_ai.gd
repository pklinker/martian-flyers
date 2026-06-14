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
##     protection, plus armour awareness: aim at the enemy's thinnest/breached
##     facing, and never present an already-holed facing of its own), and
##   - fires every deck gun that bears (chipping armour is never wasted) and
##     spends a finite torpedo only on good odds against hard armour.
##
## Doctrine is a weight table (see `_doctrine_for`). Difficulty is expressed as
## those weights plus optional score noise — deeper lookahead is a future lever.

var doctrine: Dictionary
var noise := 0.0                       # >0 = sloppier play (easy mode)
var _rng := RandomNumberGenerator.new()

# --- Lookahead / Monte Carlo (Phase C) ---------------------------------------
## Number of Monte Carlo rollouts averaged when choosing this turn's plot. 0
## (default) keeps the fast 1-ply path — `plot` just steps toward the doctrine
## speed. >0 switches on the seeded-engine lookahead: clone the engine, try each
## reachable speed, play the turn(s) out with greedy brains, resolve fire on the
## seeded RNG, and keep the speed with the best expected outcome. A pure
## difficulty lever — more rollouts + deeper turns = a stronger captain.
var rollouts := 0
## How many full turns each rollout simulates before scoring the result. 1 is
## "shallow lookahead" (this turn's exchange); higher peers further ahead.
var lookahead_turns := 1

## Value-function weights for scoring a rolled-out state (see `_eval_state`).
## Internals outweigh armour — armour only delays the first breach, but losing
## system boxes is what actually kills a flyer — and a decisive result dwarfs
## any amount of chipped plate.
const VALUE_ARMOR := 1.0
const VALUE_SYSTEM := 2.0
const VALUE_FIRE := 3.0
const VALUE_WIN := 1000.0
## A fixed scramble for the Monte Carlo RNG salt (Knuth's multiplicative hash),
## so repeated rollouts of the same candidate sample different fire outcomes.
const _MC_SALT := 2654435761

## Salvo discipline: don't spend a finite torpedo on a shot needing worse than
## this on the die. Guns fire freely; torpedoes are hoarded for good odds.
const TORPEDO_MAX_TO_HIT := 4
## Start manning a tube once the enemy is within this margin of its reach, so
## it's loaded and ready as the scout closes rather than a turn late.
const TORPEDO_ARM_MARGIN := 2
## Don't spend an armour-piercing torpedo on a facing softer than this when a
## deck gun also bears — guns crack soft plating for free; save the fish for
## armour they can't get through.
const TORPEDO_HARD_ARMOR := 3


static func for_ship(def: ShipDef) -> ShipAI:
	var ai := ShipAI.new()
	ai.doctrine = _doctrine_for(def.id)
	return ai


## Convenience: a lookahead-enabled brain (Phase C) — for_ship() plus the rollout
## knobs. This is the difficulty lever a menu will eventually set; `p_rollouts`
## of 0 is exactly the 1-ply brain.
static func for_ship_with_lookahead(def: ShipDef, p_rollouts: int, p_turns: int = 1) -> ShipAI:
	var ai := for_ship(def)
	ai.rollouts = maxi(p_rollouts, 0)
	ai.lookahead_turns = maxi(p_turns, 1)
	return ai


# ---------------------------------------------------------------------------
# Difficulty: the two wired levers (evaluator noise + lookahead depth) bundled
# into the three ranks the menu offers. PADWAR sandbags with sloppy positioning;
# DWAR is the clean 1-ply captain; ODWAR runs the seeded-engine rollouts. Held
# here (not in the UI) so the knob mapping lives with the brain it configures.
# ---------------------------------------------------------------------------

enum Difficulty { PADWAR, DWAR, ODWAR }

## Easy mode's positional sloppiness — the spread on the move-scoring noise. Big
## enough to visibly drift the kiter out of its band and mis-present facings.
const PADWAR_NOISE := 2.5
## Hard mode's rollout budget: plays each candidate plot forward this many times
## on the seeded engine and averages the outcome. Kept shallow (one turn) so the
## enemy never stalls the player's turn.
const ODWAR_ROLLOUTS := 3

## Build the enemy brain for a chosen difficulty rank. Unknown levels fall back
## to DWAR, the balanced default.
static func for_difficulty(def: ShipDef, level: int) -> ShipAI:
	match level:
		Difficulty.PADWAR:
			var ai := for_ship(def)
			ai.noise = PADWAR_NOISE
			return ai
		Difficulty.ODWAR:
			return for_ship_with_lookahead(def, ODWAR_ROLLOUTS, 1)
		_:
			return for_ship(def)


## Short rank name for the difficulty selector.
static func difficulty_name(level: int) -> String:
	match level:
		Difficulty.PADWAR: return "Padwar"
		Difficulty.ODWAR:  return "Odwar"
		_:                 return "Dwar"


## One-line flavour blurb shown under the selector.
static func difficulty_blurb(level: int) -> String:
	match level:
		Difficulty.PADWAR: return "Green officers — eager, but their fire wanders."
		Difficulty.ODWAR:  return "Warlords who weigh every plot before they commit."
		_:                 return "Seasoned line captains who hold their doctrine."


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
				"w_penetrate": 1.0, "w_hole": 1.5,
				"flee_buoyancy_frac": 0.34,
			}
		&"zodanga_cruiser":
			return {
				"preferred_min": 1, "preferred_max": 4,
				"w_too_close": 0.5, "w_too_far": 2.0,
				"w_my_guns": 3.0, "w_enemy_guns": 0.5, "w_expose": 0.5,
				"w_penetrate": 1.5, "w_hole": 1.0,
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
				"w_penetrate": 1.0, "w_hole": 1.5,
				"flee_buoyancy_frac": 0.34,
			}
		&"helium_battleship":
			# The heaviest brawler: wants its broadside on the target and shrugs
			# off return fire even harder than the cruiser.
			return {
				"preferred_min": 1, "preferred_max": 6,
				"w_too_close": 0.4, "w_too_far": 2.0,
				"w_my_guns": 3.5, "w_enemy_guns": 0.4, "w_expose": 0.5,
				"w_penetrate": 1.5, "w_hole": 1.0,
				"flee_buoyancy_frac": 0.15,
			}
		_:
			return {
				"preferred_min": 2, "preferred_max": 6,
				"w_too_close": 1.0, "w_too_far": 1.0,
				"w_my_guns": 2.0, "w_enemy_guns": 1.0, "w_expose": 0.5,
				"w_penetrate": 1.0, "w_hole": 1.0,
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


## PLOT: choose this turn's speed. With lookahead off (the default) step toward
## the doctrine target, bounded by acceleration and the crew-gated usable speed.
## With lookahead on, let the seeded-engine rollout pick the best reachable speed
## (it falls back to the 1-ply step when there's no enemy to plan against).
func plot(engine: TurnEngine, s: ShipState) -> void:
	if rollouts > 0:
		var chosen := _plot_by_lookahead(engine, s)
		if chosen >= 0:
			s.speed = chosen
			return
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


## FIRE: shoot every deck gun that bears (LOS-checked) — even a fully-absorbed
## shot strips armour toward the next penetration, so guns are never wasted. A
## finite torpedo is spent only on worthwhile odds AND only against hard armour:
## once the struck facing is breached, ordinary guns exploit the hole for free,
## so the armour-piercing salvo is hoarded for plating the guns can't crack.
func choose_fire(s: ShipState, enemy: ShipState, terrain: Dictionary = {}) -> Array[int]:
	var bearing := s.guns_bearing(enemy.hex, terrain)
	var has_deck_gun := false
	for i in bearing:
		if not ShipLibrary.gun(s.def.gun_mounts[i]["gun_id"]).is_torpedo:
			has_deck_gun = true
			break
	var out: Array[int] = []
	for i in bearing:
		var gun: GunDef = ShipLibrary.gun(s.def.gun_mounts[i]["gun_id"])
		if gun.is_torpedo:
			if int(s.fire_preview(i, enemy.hex, terrain)["to_hit"]) > TORPEDO_MAX_TO_HIT:
				continue   # salvo discipline: not on a long-range prayer
			var hit := HexMath.struck_facing(enemy.hex, enemy.facing, s.hex)
			if has_deck_gun and enemy.armor_remaining[hit] < TORPEDO_HARD_ARMOR:
				continue   # the facing is soft — let the deck guns do it, save the fish
		out.append(i)
	return out


# ---------------------------------------------------------------------------
# Lookahead / Monte Carlo (Phase C)
#
# When `rollouts > 0`, the plot is chosen by simulation rather than the 1-ply
# heuristic: clone the seeded engine, fix our speed to a candidate, fly everyone
# (us included, on subsequent impulses/turns) with cheap greedy brains, resolve
# real fire, and score the resulting state. Averaging over `rollouts` RNG-salted
# plays turns the chance of the dice into an expected value, so the captain
# commits to the speed that pays off across the likely fights, not just the one
# the heuristic's positional proxies favour.
# ---------------------------------------------------------------------------

## Choose this turn's speed by rollout: for every speed reachable this turn
## (bounded by acceleration and the crew-gated ceiling), clone the engine, fix
## our speed, let greedy brains fly everyone else, play the turn(s) out, and keep
## the speed with the best state value averaged over `rollouts` seeded plays.
## Returns -1 when there's no enemy to plan against (caller uses the 1-ply path).
func _plot_by_lookahead(engine: TurnEngine, s: ShipState) -> int:
	var enemy := _enemy(engine, s)
	if enemy == null:
		return -1
	var my_index := engine.ships.find(s)
	if my_index < 0:
		return -1
	var cap := s.usable_max_speed()
	var dv := s.max_speed_change()
	var lo: int = clampi(s.speed - dv, 0, cap)
	var hi: int = clampi(s.speed + dv, 0, cap)
	var trials: int = maxi(rollouts, 1)
	var best_speed := s.speed
	var best_score := -INF
	for cand in range(lo, hi + 1):
		var total := 0.0
		for r in trials:
			total += _rollout_value(engine, my_index, cand, r)
		var avg := total / float(trials)
		if avg > best_score:
			best_score = avg
			best_speed = cand
	return best_speed


## One rollout: clone the engine, set our ship to `cand_speed`, plot the others
## with greedy brains, then play `lookahead_turns` turns to completion and score
## the result from our side's perspective. `salt` perturbs the clone's RNG so
## repeated rollouts sample different fire outcomes (Monte Carlo); a single
## rollout uses the live seed unchanged, so lookahead is then fully deterministic.
func _rollout_value(engine: TurnEngine, my_index: int, cand_speed: int, salt: int) -> float:
	var sim := SaveGame.clone(engine)
	if rollouts > 1:
		sim.rng.seed = sim.rng.seed + salt * _MC_SALT
	var me: ShipState = sim.ships[my_index]
	var brains := _greedy_brains(sim)
	# The opponents (and us, on later impulses) fly greedily; only this turn's
	# speed for our hull is the candidate under test.
	for o in sim.ships:
		if o != me and not sim.is_out_of_action(o):
			brains[o].plot(sim, o)
	me.speed = clampi(cand_speed, 0, me.usable_max_speed())
	_drive_movement_fire_upkeep(sim, brains)
	for _t in range(lookahead_turns - 1):
		if sim.phase == TurnEngine.Phase.GAME_OVER:
			break
		_drive_full_turn(sim, brains)
	return _eval_state(sim, me.side)


## Score a (rolled-out) engine state from `side`'s perspective: our remaining
## fighting strength minus the enemy's, plus a decisive bonus when the battle has
## actually been won or lost. Higher is better for `side`.
func _eval_state(engine: TurnEngine, side: int) -> float:
	var mine := 0.0
	var theirs := 0.0
	for s in engine.ships:
		var strength := _ship_strength(s)
		if s.side == side:
			mine += strength
		else:
			theirs += strength
	var score := mine - theirs
	if engine.phase == TurnEngine.Phase.GAME_OVER:
		score += VALUE_WIN if engine.side_alive(side) else -VALUE_WIN
	return score


## A scalar "fighting strength" for one hull: surviving armour and system boxes,
## docked for active fires. An out-of-action hull is worth nothing.
func _ship_strength(s: ShipState) -> float:
	if s.is_destroyed or s.grounded or s.crew_pool() == 0:
		return 0.0
	var v := 0.0
	for a in s.armor_remaining:
		v += float(a) * VALUE_ARMOR
	for t in s.systems_remaining:
		v += float(s.systems_remaining[t]) * VALUE_SYSTEM
	return v - float(s.fires) * VALUE_FIRE


## A fast 1-ply ShipAI for every hull in a (cloned) engine — the opponent model
## a rollout flies. Keyed by ShipState, matching the demo/test driver shape.
static func _greedy_brains(engine: TurnEngine) -> Dictionary:
	var brains := {}
	for s in engine.ships:
		brains[s] = ShipAI.for_ship(s.def)
	return brains


## Drive a cloned engine from a speeds-set state through end-of-turn: run the
## 8-impulse movement with each brain's choose_move, declare and resolve the
## simultaneous fire, then upkeep. Mirrors the production loop (demo, tests) so a
## rollout plays exactly the game it is predicting.
static func _drive_movement_fire_upkeep(engine: TurnEngine, brains: Dictionary) -> void:
	engine.begin_movement()
	while true:
		var mover := engine.next_mover()
		if mover == null:
			break
		var moves := engine.legal_moves_for(mover)
		if not moves.is_empty():
			engine.execute_move(mover, brains[mover].choose_move(engine, mover, moves))
	for s in engine.ships:
		if engine.is_out_of_action(s):
			continue
		var enemy: ShipState = brains[s]._enemy(engine, s)
		if enemy == null:
			continue
		for mi in brains[s].choose_fire(s, enemy, engine.terrain):
			engine.declare_fire(s, mi, enemy)
	engine.resolve_fire_phase()
	if engine.phase != TurnEngine.Phase.GAME_OVER:
		engine.run_upkeep()


## Drive a full turn on a cloned engine: allocate + plot every living hull with
## its greedy brain, then movement/fire/upkeep. Used for the 2nd..Nth turns of a
## multi-turn rollout (the greedy brains have rollouts == 0, so no recursion).
static func _drive_full_turn(engine: TurnEngine, brains: Dictionary) -> void:
	for s in engine.ships:
		if not engine.is_out_of_action(s):
			brains[s].allocate(engine, s)
	for s in engine.ships:
		if not engine.is_out_of_action(s):
			brains[s].plot(engine, s)
	_drive_movement_fire_upkeep(engine, brains)


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
	# A fully holed facing is free internals for the enemy — refuse to present it.
	if s.armor_remaining[struck] == 0:
		score -= float(doctrine.get("w_hole", 0.0))

	# Offense: internal damage only flows once a facing is stripped, so prefer to
	# strike the enemy's thinnest (or already-breached) facing and keep pounding
	# the same one until it caves — rather than circling onto fresh plating.
	if mine > 0:
		var enemy_hit := HexMath.struck_facing(enemy.hex, enemy.facing, my_hex)
		score += float(enemy.def.armor.max() - enemy.armor_remaining[enemy_hit]) \
				* float(doctrine.get("w_penetrate", 0.0))
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
