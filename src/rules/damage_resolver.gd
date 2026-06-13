class_name DamageResolver
## Gunnery resolution and the Damage Allocation Chart (DAC).
## Stateless except for the injected RNG — pass a seeded RandomNumberGenerator
## for deterministic replays and AI lookahead.

## Weighted internal-hit table — the heart of the SFB feel. When a shot
## penetrates armor, each point of internal damage rolls on this table.
## Weights are relative; entries for systems the ship lacks (or has none
## left of) cascade to BUOYANCY, the "always something left to wreck" filler
## (until it isn't, and the ship falls out of the sky).
const DAC_WEIGHTS := {
	ShipDef.SystemType.BUOYANCY: 30,
	ShipDef.SystemType.ENGINE: 14,
	ShipDef.SystemType.PROPELLER: 10,
	ShipDef.SystemType.RUDDER: 8,
	ShipDef.SystemType.CREW: 18,
	ShipDef.SystemType.BRIDGE: 4,
	ShipDef.SystemType.MAGAZINE: 4,
	ShipDef.SystemType.DAMAGE_CONTROL: 4,
}
const GUN_HIT_WEIGHT := 8  # chance an internal hit takes out a gun mount instead

## Resolves one gun firing at one target. Returns a report Dictionary the UI
## can render verbatim into a combat log:
## { "hit": bool, "roll": int, "needed": int, "range": int,
##   "facing_struck": int, "damage": int, "armor_absorbed": int,
##   "internals": Array[Dictionary], "destroyed_target": bool,
##   "los_blocked": bool, "dust_penalty": int }
## Pass `terrain` (from TurnEngine.terrain) for LOS and dust accounting.
static func resolve_shot(firer: ShipState, mount_index: int, target: ShipState,
		rng: RandomNumberGenerator, terrain: Dictionary = {}) -> Dictionary:
	var mount := firer.def.gun_mounts[mount_index]
	var gun: GunDef = ShipLibrary.gun(mount["gun_id"])
	var range_hexes := HexMath.distance(firer.hex, target.hex)

	var report := {
		"firer": firer.def.display_name, "gun": gun.display_name,
		"target": target.def.display_name, "is_torpedo": gun.is_torpedo,
		"hit": false, "roll": 0, "needed": 0, "range": range_hexes,
		"facing_struck": -1, "damage": 0, "armor_absorbed": 0,
		"internals": [], "destroyed_target": false,
		"los_blocked": false, "dust_penalty": 0,
	}

	var bracket := gun.bracket_for_range(range_hexes)
	if bracket.is_empty():
		report["needed"] = 7  # out of range — nothing loosed (no torpedo spent)
		_start_reload(firer, mount_index, gun)
		return report

	# LOS check: hills and towers block the shot entirely — no shot fired,
	# no ammo spent, no reload started. The firer simply can't see the target.
	if not TerrainDef.los_clear(firer.hex, target.hex, terrain):
		report["los_blocked"] = true
		return report

	# In range and LOS clear: the shot fires. A torpedo is expended whether
	# it hits or not.
	_consume_ammo(firer, mount_index, gun)
	var dust := TerrainDef.dust_along(firer.hex, target.hex, terrain)
	var lookouts: int = int(firer.allocation.get("lookout", 0))
	var penalty: int = maxi(dust - lookouts, 0)
	report["dust_penalty"] = penalty
	report["needed"] = int(bracket["to_hit"]) + penalty
	report["roll"] = rng.randi_range(1, 6)
	_start_reload(firer, mount_index, gun)
	if report["roll"] < report["needed"]:
		return report

	report["hit"] = true
	report["damage"] = int(bracket["damage"])
	_apply_damage(firer, target, report["damage"], report, rng, gun.armor_piercing)
	return report

static func _start_reload(firer: ShipState, mount_index: int, gun: GunDef) -> void:
	firer.gun_states[mount_index]["reload"] = gun.reload_turns

static func _consume_ammo(firer: ShipState, mount_index: int, gun: GunDef) -> void:
	if gun.is_torpedo:
		var st := firer.gun_states[mount_index]
		st["ammo"] = maxi(int(st.get("ammo", 0)) - 1, 0)

## Armor on the struck facing absorbs first (and is marked off permanently —
## armor does not regenerate). Overflow becomes internal hits via the DAC.
static func _apply_damage(firer: ShipState, target: ShipState, damage: int,
		report: Dictionary, rng: RandomNumberGenerator, armor_piercing: int = 0) -> void:
	var struck := HexMath.struck_facing(target.hex, target.facing, firer.hex)
	report["facing_struck"] = struck

	# Armour-piercing warheads bypass part of the plating: only the armour above
	# the AP value still absorbs (and only that much is marked off — the bypassed
	# plating is punched through, not destroyed).
	var effective_armor: int = max(target.armor_remaining[struck] - armor_piercing, 0)
	var absorbed: int = min(effective_armor, damage)
	target.armor_remaining[struck] -= absorbed
	report["armor_absorbed"] = absorbed

	var internal := damage - absorbed
	for _i in internal:
		if target.is_destroyed:
			break
		report["internals"].append(_roll_internal(target, rng, report["facing_struck"]))
	report["destroyed_target"] = target.is_destroyed
	target.damage_taken.emit(report)

## One internal hit on the DAC. Returns { "system": String, "effect": String }.
static func _roll_internal(target: ShipState, rng: RandomNumberGenerator,
		struck_facing: int = -1) -> Dictionary:
	# Build the live weight table: only systems with boxes remaining,
	# plus surviving gun mounts.
	var entries: Array = []
	var total := 0
	for t in DAC_WEIGHTS.keys():
		if target.sys(t) > 0:
			entries.append({ "kind": "system", "type": t, "w": DAC_WEIGHTS[t] })
			total += DAC_WEIGHTS[t]
	var live_guns: Array[int] = []
	for i in target.gun_states.size():
		if not target.gun_states[i]["destroyed"]:
			live_guns.append(i)
	if not live_guns.is_empty():
		entries.append({ "kind": "gun", "w": GUN_HIT_WEIGHT })
		total += GUN_HIT_WEIGHT

	if total == 0:
		target.is_destroyed = true
		target.destroyed.emit("hulk — nothing left to destroy")
		return { "system": "hulk", "effect": "the flyer breaks apart" }

	var pick := rng.randi_range(1, total)
	for e in entries:
		pick -= int(e["w"])
		if pick <= 0:
			if e["kind"] == "gun":
				var gi: int = live_guns[rng.randi_range(0, live_guns.size() - 1)]
				target.gun_states[gi]["destroyed"] = true
				return { "system": str(target.def.gun_mounts[gi]["label"]),
						"effect": "gun mount destroyed" }
			return _hit_system(target, e["type"], rng, struck_facing)
	return { "system": "?", "effect": "" }  # unreachable

static func _hit_system(target: ShipState, t: ShipDef.SystemType,
		rng: RandomNumberGenerator, struck_facing: int = -1) -> Dictionary:
	target.systems_remaining[t] = target.sys(t) - 1
	var name: String = ShipDef.SystemType.keys()[t].capitalize()
	var effect := "box destroyed"

	match t:
		ShipDef.SystemType.MAGAZINE:
			# Radium shells are volatile: each magazine hit risks catastrophe.
			if rng.randi_range(1, 6) >= 5:
				target.is_destroyed = true
				target.destroyed.emit("magazine explosion")
				effect = "MAGAZINE EXPLOSION — the flyer is consumed in radium fire"
		ShipDef.SystemType.BUOYANCY:
			# Route hit to port (facings 4,5) or stbd (1,2); bow/stern is 50/50.
			var hit_port: bool
			if struck_facing == 4 or struck_facing == 5:
				hit_port = true
			elif struck_facing == 1 or struck_facing == 2:
				hit_port = false
			else:
				hit_port = rng.randi_range(0, 1) == 0
			# If the struck side's tanks are exhausted, overflow to the other.
			if hit_port and target.port_buoyancy == 0:
				hit_port = false
			elif not hit_port and target.stbd_buoyancy == 0:
				hit_port = true
			if hit_port:
				target.port_buoyancy -= 1
			else:
				target.stbd_buoyancy -= 1
			var side := "port" if hit_port else "stbd"
			effect = "tank holed (%s) — %d above the falling line" % [
					side, maxi(target.sys(t) - target.def.grounding_threshold, 0)]
		ShipDef.SystemType.CREW:
			effect = "casualties among the deck crew"
		ShipDef.SystemType.BRIDGE:
			if target.sys(t) == 0:
				effect = "bridge destroyed — command crippled"

	if t == ShipDef.SystemType.BUOYANCY and not target.is_buoyant():
		effect = "below the falling line — the flyer is going down"

	return { "system": name, "effect": effect }
