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
