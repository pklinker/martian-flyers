class_name ShipDef
extends Resource
## Static definition of a ship CLASS — the blank SSD sheet.
## A ShipState references one of these and tracks which boxes are marked off.

## Internal system types. ARMOR is deliberately NOT here: armor is directional
## and tracked per-facing, never hit by internal damage allocation.
enum SystemType {
	BUOYANCY,    # eighth-ray tanks; too few and the ship settles (replaces SFB hull)
	ENGINE,      # radium engine; boxes set the speed ceiling (engine crew powers it)
	PROPELLER,   # acceleration/deceleration per turn
	RUDDER,      # turn mode quality
	BRIDGE,      # command; loss degrades everything
	CREW,        # the allocation pool; casualties shrink it
	MAGAZINE,    # radium shell storage; critical = catastrophic explosion
	DAMAGE_CONTROL,
}

## Firing arcs for gun mounts, expressed as relative bearings (see HexMath):
## 0=ahead, 1=fwd-stbd, 2=aft-stbd, 3=astern, 4=aft-port, 5=fwd-port.

@export var id: StringName = &"ship"
@export var display_name: String = "Unnamed Flyer"
@export var faction: String = "Helium"

## Named officers, senior first. A bridge hit (or an unlucky crew hit) strikes
## one down for genre-voice flavor — see DamageResolver. The mechanical effect
## is still the box marked off; the name is narration on top.
@export var officers: Array[String] = []

## Armor boxes per facing, indexed by relative bearing 0..5
## (bow, fwd-stbd, aft-stbd, stern, aft-port, fwd-port).
@export var armor: Array[int] = [0, 0, 0, 0, 0, 0]

## Internal box counts keyed by SystemType.
@export var systems: Dictionary = {}

## Gun mounts: array of { "gun_id": StringName, "arcs": Array[int], "label": String }
## e.g. { "gun_id": &"medium_gun", "arcs": [5, 0, 1], "label": "Bow Gun" }
@export var gun_mounts: Array[Dictionary] = []

@export var base_max_speed: int = 6      # hexes per turn at full engine boxes

## Hexes of speed each engine-room crew box can drive this turn. Engine BOXES
## set the ceiling (base_max_speed, eroded by damage); engine CREW sets how
## much of that ceiling the ship can actually use — the per-turn power economy
## that makes speed compete with guns and damage control for crew. See
## ShipState.usable_max_speed().
@export var speed_per_engine_crew: int = 2

## With this many buoyancy tanks (or fewer) the ship can no longer hold the
## air: it settles onto the dead sea bottom at upkeep — a forced grounding.
@export var grounding_threshold: int = 0

## Turn mode: hexes that must be moved straight before a facing change,
## indexed by current speed (index 0 = speed 0). Pad with last value.
@export var turn_mode_by_speed: Array[int] = [1, 1, 1, 2, 2, 3, 3]

func system_count(t: SystemType) -> int:
	return int(systems.get(t, 0))

func turn_mode(speed: int) -> int:
	if turn_mode_by_speed.is_empty():
		return 1
	return turn_mode_by_speed[min(speed, turn_mode_by_speed.size() - 1)]


# ---------------------------------------------------------------------------
# Points-buy cost (Phase F2). A pure, deterministic value DERIVED from the
# ship's own stats, so every new class is priced automatically. The curve is
# deliberately NON-LINEAR (convex): concentrated power costs a premium, so one
# cruiser is dearer than two scouts whose stats it dominates — the glass-cannon-
# vs-brick buy tension. Balance is explicitly not the goal here; the cost only
# needs to be monotone in the obvious way and stable. Weights are tunables.
# ---------------------------------------------------------------------------

## Optional hard override; ≥0 pins the cost for a class, -1 derives it.
@export var point_cost_override: int = -1

const COST := {
	# Offence: per-mount expected-damage × reach × arcs ÷ reload.
	"reach_norm": 6.0,         # divides a gun's max_range into a reach factor
	"w_offense": 1.0,
	"ap_bonus": 1.4,           # torpedoes defeat armour → valued up
	"ammo_half": 3.0,          # finite-ammo discount: ammo / (ammo + ammo_half)
	# Defence: plating + tanks + the internals that keep capability online.
	"w_armor": 1.0,
	"w_buoyancy": 0.5,
	"w_internal": 0.7,         # ENGINE + BRIDGE + CREW + DAMAGE_CONTROL
	"w_magazine": -0.5,        # a liability (explosion risk), shaves cost
	# Mobility & command.
	"w_speed": 1.0,
	"w_power": 1.2,            # speed_per_engine_crew
	"w_turn": 0.8,             # nimbleness (lower turn mode = costlier)
	"turn_base": 4.0,
	"w_prop_rudder": 0.4,
	"w_crew": 0.5,             # the pool powers everything via allocation
	# The non-linearity: convex exponents on the offence/defence subtotals plus a
	# cross term (hits hard AND survives is worth more than the sum).
	"exp_offense": 1.2,
	"exp_defense": 1.2,
	"cross": 0.03,
	"scale": 0.5,
}

## Total derived points cost (or the pinned override). Always ≥ 1.
func point_cost() -> int:
	if point_cost_override >= 0:
		return point_cost_override
	var off := _offense_score()
	var def_score := _defense_score()
	var mob := _mobility_score()
	var total := pow(off, COST["exp_offense"]) + pow(def_score, COST["exp_defense"]) \
			+ mob + COST["cross"] * off * def_score
	return maxi(1, int(round(total * COST["scale"])))

## Sustained offensive value summed over every gun mount.
func _offense_score() -> float:
	var off := 0.0
	for mount in gun_mounts:
		var g: GunDef = ShipLibrary.gun(mount["gun_id"])
		var arc_count: int = maxi(1, (mount["arcs"] as Array).size())
		# Mean expected damage across the gun's range brackets: damage weighted by
		# the probability of rolling at least `to_hit` on a d6.
		var ed := 0.0
		for b in g.range_brackets:
			var p := clampf(float(7 - int(b["to_hit"])) / 6.0, 0.0, 1.0)
			ed += p * float(b["damage"])
		if not g.range_brackets.is_empty():
			ed /= float(g.range_brackets.size())
		var reach := float(g.max_range()) / float(COST["reach_norm"])
		var per_turn := 1.0 / float(g.reload_turns + 1)
		var val := ed * reach * float(arc_count) * per_turn
		if g.is_torpedo:
			# AP defeats the armour term (full damage), but a finite rack is worth
			# a fraction of an infinite gun's sustained fire.
			var ammo_discount := float(g.ammo) / (float(g.ammo) + float(COST["ammo_half"]))
			val *= float(COST["ap_bonus"]) * ammo_discount
		off += val
	return off * float(COST["w_offense"])

## Damage-absorption value: plating, tanks, and the key internals.
func _defense_score() -> float:
	var armor_total := 0
	for a in armor:
		armor_total += a
	var internals := system_count(SystemType.ENGINE) + system_count(SystemType.BRIDGE) \
			+ system_count(SystemType.CREW) + system_count(SystemType.DAMAGE_CONTROL)
	return float(COST["w_armor"]) * float(armor_total) \
			+ float(COST["w_buoyancy"]) * float(system_count(SystemType.BUOYANCY)) \
			+ float(COST["w_internal"]) * float(internals) \
			+ float(COST["w_magazine"]) * float(system_count(SystemType.MAGAZINE))

## Mobility and command value.
func _mobility_score() -> float:
	var avg_tm := 0.0
	if not turn_mode_by_speed.is_empty():
		for t in turn_mode_by_speed:
			avg_tm += float(t)
		avg_tm /= float(turn_mode_by_speed.size())
	var nimbleness: float = maxf(0.0, float(COST["turn_base"]) - avg_tm)
	return float(COST["w_speed"]) * float(base_max_speed) \
			+ float(COST["w_power"]) * float(speed_per_engine_crew) \
			+ float(COST["w_turn"]) * nimbleness \
			+ float(COST["w_prop_rudder"]) * float(system_count(SystemType.PROPELLER)
					+ system_count(SystemType.RUDDER)) \
			+ float(COST["w_crew"]) * float(system_count(SystemType.CREW))
