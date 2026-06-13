class_name ShipState
extends RefCounted
## Runtime state of one ship in play: the "pencil marks" on the SSD plus
## position, speed, and this turn's crew allocation.
## No rendering, no input — the UI observes this; the engine mutates it.

signal damage_taken(report: Dictionary)   # emitted by DamageResolver via apply hooks
signal destroyed(reason: String)

var def: ShipDef
var side: int = 0                         # 0 = player, 1 = AI

# --- Position / movement ---
var hex: Vector2i = Vector2i.ZERO
var facing: int = 0                       # 0..5, see HexMath
var speed: int = 0                        # hexes per turn (plotted)
var straight_moved: int = 0               # hexes since last facing change (turn mode)

# --- Damage tracking ---
var armor_remaining: Array[int] = []      # per facing 0..5
var systems_remaining: Dictionary = {}    # SystemType -> int
var grounded: bool = false
var is_destroyed: bool = false

# --- Gun mounts (parallel to def.gun_mounts) ---
# Each: { "destroyed": bool, "reload": int (turns until ready), "manned": bool }
var gun_states: Array[Dictionary] = []

# --- Per-side buoyancy for listing. Sum equals sys(BUOYANCY). ---
# Initialized from the total; updated by DamageResolver._hit_system and
# TurnEngine DC repair. Neither value should go below zero in normal play.
var port_buoyancy: int = 0
var stbd_buoyancy: int = 0

# --- Crew allocation for the current turn ---
# Keys: "guns" (Array[int] of mount indices manned), "engine": int, "damage_control": int
var allocation: Dictionary = { "guns": [], "engine": 0, "damage_control": 0 }


static func create(ship_def: ShipDef, p_side: int, start_hex: Vector2i, start_facing: int) -> ShipState:
	var s := ShipState.new()
	s.def = ship_def
	s.side = p_side
	s.hex = start_hex
	s.facing = start_facing
	s.armor_remaining.assign(ship_def.armor)
	for t in ship_def.systems.keys():
		s.systems_remaining[t] = ship_def.systems[t]
	for m in ship_def.gun_mounts:
		var gun: GunDef = ShipLibrary.gun(m["gun_id"])
		# Torpedo tubes carry a finite load; guns use -1 to mean "not tracked".
		var ammo: int = gun.ammo if gun.is_torpedo else -1
		s.gun_states.append({ "destroyed": false, "reload": 0, "manned": false, "ammo": ammo })
	# Port gets the ceiling on odd totals so port >= stbd at start.
	var total_buoy := s.sys(ShipDef.SystemType.BUOYANCY)
	s.port_buoyancy = (total_buoy + 1) / 2
	s.stbd_buoyancy = total_buoy - s.port_buoyancy
	return s


# ---------------------------------------------------------------------------
# Derived capabilities — every one of these is where "capability erosion"
# happens. Damage never subtracts hit points; it degrades these answers.
# ---------------------------------------------------------------------------

func sys(t: ShipDef.SystemType) -> int:
	return int(systems_remaining.get(t, 0))

func sys_fraction(t: ShipDef.SystemType) -> float:
	var total := def.system_count(t)
	return 1.0 if total == 0 else float(sys(t)) / float(total)

## The engine-box ceiling: max speed scales with surviving engine boxes, and
## bridge loss caps it further. This is the ship's *rated* top speed — what the
## hardware allows when fully crewed. `usable_max_speed()` layers the per-turn
## crew power economy on top.
func effective_max_speed() -> int:
	var v := int(ceil(def.base_max_speed * sys_fraction(ShipDef.SystemType.ENGINE)))
	if sys(ShipDef.SystemType.BRIDGE) == 0:
		v = min(v, def.base_max_speed / 2)
	return max(v, 0 if sys(ShipDef.SystemType.ENGINE) == 0 else 1)

## This turn's drivable speed: the engine-box ceiling, capped by how much
## engine-room crew is powering the radium engine. No engine crew = no way on.
## (Allocation is set in the ALLOCATE phase, before speed is plotted.)
func usable_max_speed() -> int:
	var crew_cap := int(allocation.get("engine", 0)) * def.speed_per_engine_crew
	return mini(effective_max_speed(), crew_cap)

## Engine-room crew needed to drive `target_speed` hexes (rounding up). Useful
## to the allocation UI and AI when reserving crew for a desired speed.
func engine_crew_for_speed(target_speed: int) -> int:
	if def.speed_per_engine_crew <= 0:
		return 0
	return int(ceil(float(target_speed) / def.speed_per_engine_crew))

## Acceleration/deceleration allowed between turns, from propeller boxes.
func max_speed_change() -> int:
	return max(1, int(ceil(2.0 * sys_fraction(ShipDef.SystemType.PROPELLER))))

## Turn mode worsens (+1 straight hex required) when rudder is half gone,
## and again when it is fully gone. A listing ship also turns more sluggishly:
## floor(tank imbalance / 2) is added on top.
func turn_mode() -> int:
	var tm := def.turn_mode(speed)
	var rf := sys_fraction(ShipDef.SystemType.RUDDER)
	if rf <= 0.0:
		tm += 2
	elif rf <= 0.5:
		tm += 1
	tm += list_severity()
	return tm

## Tank imbalance expressed as a turn-mode penalty. One-tank difference is
## noise; every two-tank gap costs one extra straight hex before turning.
func list_severity() -> int:
	return absi(port_buoyancy - stbd_buoyancy) / 2

## Which side is lower in the water ("port", "stbd", or "" when balanced).
## An imbalance of 1 is not enough to produce a visible list.
func list_side() -> String:
	var diff := port_buoyancy - stbd_buoyancy
	if diff < -1: return "port"   # port tanks fewer → port side sags
	if diff > 1:  return "stbd"   # stbd tanks fewer → stbd side sags
	return ""

## Buoyancy is the heart of the Barsoom flavor: hole enough tanks and the
## ship can no longer hold the air. True while it has lift to spare.
func is_buoyant() -> bool:
	return sys(ShipDef.SystemType.BUOYANCY) > def.grounding_threshold

func can_turn() -> bool:
	return straight_moved >= turn_mode()

func crew_pool() -> int:
	return sys(ShipDef.SystemType.CREW)

func gun_ready(i: int) -> bool:
	var g := gun_states[i]
	if g["destroyed"] or g["reload"] != 0 or not g["manned"] or is_destroyed:
		return false
	# A torpedo tube with an empty rack can't fire even when manned and bearing.
	if int(g.get("ammo", -1)) == 0:
		return false
	return true

## Mount indices that could bear on a target hex right now (arc + range + LOS).
func guns_bearing(target_hex: Vector2i, terrain: Dictionary = {}) -> Array[int]:
	return guns_bearing_from(hex, facing, target_hex, terrain)

## Same query, but from a hypothetical position/facing — so the AI can score
## candidate moves before committing. Ready/manned state is position-independent
## and read from the live mount states. Pass `terrain` to exclude mounts with
## blocked LOS (hills/towers between the two hexes).
func guns_bearing_from(from_hex: Vector2i, from_facing: int, target_hex: Vector2i,
		terrain: Dictionary = {}) -> Array[int]:
	var out: Array[int] = []
	var rb := HexMath.relative_bearing(from_hex, from_facing, target_hex)
	var dist := HexMath.distance(from_hex, target_hex)
	for i in def.gun_mounts.size():
		var mount := def.gun_mounts[i]
		var gun: GunDef = ShipLibrary.gun(mount["gun_id"])
		if rb in mount["arcs"] and dist <= gun.max_range() and gun_ready(i) \
				and TerrainDef.los_clear(from_hex, target_hex, terrain):
			out.append(i)
	return out

## What mount `i` would do against a target hex this phase — for the
## fire-declaration UI's shot preview. Pure query; declares nothing.
## Returns { "bears": bool, "reason": String, "range": int,
##           "to_hit": int, "damage": int, "dust_penalty": int }.
## When "bears" is false, "reason" says why (destroyed / unmanned / reloading /
## out of arc / LOS blocked / out of range). Pass `terrain` for accurate LOS
## and dust-penalty accounting; omit for a terrain-free preview.
func fire_preview(i: int, target_hex: Vector2i, terrain: Dictionary = {}) -> Dictionary:
	var mount := def.gun_mounts[i]
	var gun: GunDef = ShipLibrary.gun(mount["gun_id"])
	var rb := HexMath.relative_bearing(hex, facing, target_hex)
	var dist := HexMath.distance(hex, target_hex)
	var st := gun_states[i]
	var out := { "bears": false, "reason": "", "range": dist,
			"to_hit": 0, "damage": 0, "dust_penalty": 0,
			"is_torpedo": gun.is_torpedo, "ammo": int(st.get("ammo", -1)),
			"armor_piercing": gun.armor_piercing }
	if st["destroyed"]:
		out["reason"] = "destroyed"
	elif not st["manned"]:
		out["reason"] = "unmanned"
	elif int(st["reload"]) > 0:
		out["reason"] = "reloading"
	elif gun.is_torpedo and int(st.get("ammo", -1)) == 0:
		out["reason"] = "no torpedoes"
	elif not (rb in mount["arcs"]):
		out["reason"] = "out of arc"
	elif not TerrainDef.los_clear(hex, target_hex, terrain):
		out["reason"] = "LOS blocked"
	else:
		var bracket := gun.bracket_for_range(dist)
		if bracket.is_empty():
			out["reason"] = "out of range"
		else:
			out["bears"] = true
			var dust := TerrainDef.dust_along(hex, target_hex, terrain)
			var lookouts: int = int(allocation.get("lookout", 0))
			var penalty: int = maxi(dust - lookouts, 0)
			out["to_hit"] = int(bracket["to_hit"]) + penalty
			out["damage"] = int(bracket["damage"])
			out["dust_penalty"] = penalty
	return out


# ---------------------------------------------------------------------------
# Turn upkeep
# ---------------------------------------------------------------------------

## Called at the start of each turn, after crew allocation is chosen.
func apply_allocation(alloc: Dictionary) -> bool:
	var needed := 0
	for i in alloc.get("guns", []):
		var gun: GunDef = ShipLibrary.gun(def.gun_mounts[i]["gun_id"])
		needed += gun.crew_required
	needed += int(alloc.get("engine", 0)) + int(alloc.get("damage_control", 0))
	needed += int(alloc.get("lookout", 0))
	if needed > crew_pool():
		return false  # illegal allocation; caller must fix
	allocation = alloc
	for i in gun_states.size():
		gun_states[i]["manned"] = i in alloc.get("guns", [])
	return true

func tick_reloads() -> void:
	for g in gun_states:
		if g["reload"] > 0:
			g["reload"] -= 1

## Enforce buoyancy: with too few tanks left, the ship settles onto the dead
## sea bottom — a forced grounding (and a loss).
func enforce_buoyancy() -> void:
	if not is_buoyant():
		grounded = true
		speed = 0
