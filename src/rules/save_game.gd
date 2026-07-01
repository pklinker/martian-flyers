class_name SaveGame
extends RefCounted
## Persistence for the rules engine: serialize a TurnEngine — its ships, the
## RNG state, the turn/phase, terrain, and the in-flight movement/fire queues —
## to a plain Dictionary, a string, or a file, and restore it exactly.
##
## A pure rules-layer concern: no rendering, no input, fully headless-testable
## (round-trip a clone and the engine continues deterministically). The UI is a
## client — it calls save_to_file()/load_from_file() and re-binds its signals to
## the restored engine.
##
## The wire format is Godot's var_to_str()/str_to_var() (not JSON): it round-
## trips Vector2i, nested dictionaries, and int dictionary keys natively, so the
## per-facing armor arrays, the SystemType-keyed system counts, and the terrain
## map all survive without hand-rolled key encoding. We never serialize the
## ShipDef Resource or any signal — only the marked-up state, with the immutable
## template rebuilt from ShipLibrary by id on load.

## Bump when the serialized shape changes incompatibly; load rejects unknown.
const SAVE_VERSION := 1

## Pre-T3 saves stored terrain as the old TerrainDef.Type int enum. Terrain is
## now keyed by a string kind id (MAP_MODDING.md §5), so a save's legacy int
## values are upgraded on load — an in-progress battle (the resume autosave)
## survives the migration. This is version-agnostic on purpose: a string value
## (a post-T3 save, or the clone() round-trip) passes through untouched, so no
## SAVE_VERSION bump is needed and old + new saves both load.
const LEGACY_TERRAIN_IDS := { 0: &"hill", 1: &"tower", 2: &"dust_storm" }

## Reason the last load returned null (unrecognised version, or a ship/gun the
## current catalog no longer provides — a removed mod). The UI surfaces it so the
## player learns "this save needs mod X" instead of a silent "no save".
static var load_error := ""


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Serialize the engine to a string suitable for a save file.
static func serialize(engine: TurnEngine) -> String:
	return var_to_str(engine_to_dict(engine))


## Rebuild a TurnEngine from a string produced by serialize(). Returns null if
## the text is malformed or the save version is unrecognised.
static func deserialize(text: String) -> TurnEngine:
	var data: Variant = str_to_var(text)
	if not (data is Dictionary):
		return null
	return dict_to_engine(data)


## Write a save to disk. Returns OK on success, or a non-OK Error code.
static func save_to_file(engine: TurnEngine, path: String) -> int:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(serialize(engine))
	f.close()
	return OK


## A deep, independent copy of a live engine — every ShipState, the RNG seed +
## state, terrain, phase, turn number, and the in-flight movement/fire queues.
## Reuses the (tested) serialize round-trip, so the clone is guaranteed to match
## the persistence contract and carries no signal connections — simulating on it
## fires no UI hooks. The AI's lookahead clones the engine to play candidate
## turns forward without ever touching live state.
static func clone(engine: TurnEngine) -> TurnEngine:
	return dict_to_engine(engine_to_dict(engine))


## Read a save from disk. Returns the restored engine, or null if the file is
## missing or corrupt.
static func load_from_file(path: String) -> TurnEngine:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	f.close()
	return deserialize(text)


# ---------------------------------------------------------------------------
# Engine <-> Dictionary
# ---------------------------------------------------------------------------

static func engine_to_dict(engine: TurnEngine) -> Dictionary:
	var ships_data: Array = []
	for s in engine.ships:
		ships_data.append(ship_to_dict(s))
	# The in-flight queues hold ShipState references; store them as indices into
	# the ships array so a save taken mid-MOVEMENT or mid-FIRE restores intact.
	var fire_queue: Array = []
	for decl in engine._fire_queue:
		fire_queue.append({
			"firer": engine.ships.find(decl["firer"]),
			"mount": int(decl["mount"]),
			"target": engine.ships.find(decl["target"]),
		})
	var move_queue: Array = []
	for s in engine._movement_queue:
		move_queue.append(engine.ships.find(s))
	return {
		"version": SAVE_VERSION,
		"turn_number": engine.turn_number,
		"phase": int(engine.phase),
		"rng_seed": int(engine.rng.seed),
		"rng_state": int(engine.rng.state),
		"map_cols": engine.map_cols,
		"map_rows": engine.map_rows,
		"current_impulse": engine.current_impulse,
		"terrain": engine.terrain.duplicate(),
		"ships": ships_data,
		"fire_queue": fire_queue,
		"movement_queue": move_queue,
	}


## Rebuild the terrain map from a save, upgrading legacy int-enum values to
## string kind ids (see LEGACY_TERRAIN_IDS). An unrecognised legacy int becomes
## the empty sentinel (no terrain) rather than crashing; string values are kept.
static func _restore_terrain(raw: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for hex in raw:
		var v: Variant = raw[hex]
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			out[hex] = LEGACY_TERRAIN_IDS.get(int(v), TerrainDef.NONE)
		else:
			out[hex] = StringName(v)
	return out


static func dict_to_engine(data: Dictionary) -> TurnEngine:
	load_error = ""
	if int(data.get("version", 0)) != SAVE_VERSION:
		load_error = "save version %s is not supported (expected %d)" % [data.get("version", "?"), SAVE_VERSION]
		return null
	# Resolve every ship — and every gun its hull mounts — against the active
	# catalog BEFORE building anything, so a save that names a removed mod's ship
	# or gun declines cleanly instead of half-building an engine then crashing
	# mid-battle on first access.
	var miss := _missing_dependency(data)
	if miss != "":
		load_error = miss
		push_warning("SaveGame: " + miss)
		return null
	var engine := TurnEngine.new()
	engine.turn_number = int(data.get("turn_number", 1))
	engine.phase = int(data.get("phase", TurnEngine.Phase.ALLOCATION)) as TurnEngine.Phase
	engine.map_cols = int(data.get("map_cols", engine.map_cols))
	engine.map_rows = int(data.get("map_rows", engine.map_rows))
	engine.current_impulse = int(data.get("current_impulse", 0))
	engine.rng.seed = int(data.get("rng_seed", 0))
	engine.rng.state = int(data.get("rng_state", 0))
	engine.terrain = _restore_terrain(data.get("terrain", {}) as Dictionary)

	var restored: Array[ShipState] = []
	for sd in data.get("ships", []):
		restored.append(dict_to_ship(sd))
	engine.ships = restored

	# Rebuild the queues from indices back into the live ShipStates.
	var fq: Array[Dictionary] = []
	for decl in data.get("fire_queue", []):
		var fi := int(decl["firer"])
		var ti := int(decl["target"])
		if fi < 0 or fi >= restored.size() or ti < 0 or ti >= restored.size():
			continue
		fq.append({ "firer": restored[fi], "mount": int(decl["mount"]), "target": restored[ti] })
	engine._fire_queue = fq

	var mq: Array[ShipState] = []
	for idx in data.get("movement_queue", []):
		var i := int(idx)
		if i >= 0 and i < restored.size():
			mq.append(restored[i])
	engine._movement_queue = mq

	return engine


## Returns "" if every ship in the save (and every gun its def mounts) is known
## to the active catalog; otherwise a message naming the first missing id. Checks
## the gun level too: a hull can survive a mod removal that took only its gun.
static func _missing_dependency(data: Dictionary) -> String:
	for sd in data.get("ships", []):
		var did := StringName(sd["def_id"])
		if not ShipLibrary.has_ship(did):
			return "this save needs ship class '%s' (a removed mod?)" % did
		# The hull's mount count must still match the saved per-gun state, or the
		# UI/rules walk the mounts against a shorter gun_states array and crash.
		# A gun added or removed from this class makes the save incompatible.
		var saved_guns := (sd.get("gun_states", []) as Array).size()
		if saved_guns != ShipLibrary.ship(did).gun_mounts.size():
			return "this save is from an older version — the '%s' hull's gun layout changed" % did
		for m in ShipLibrary.ship(did).gun_mounts:
			var gid := StringName(m["gun_id"])
			if not ShipLibrary.has_gun(gid):
				return "this save's '%s' mounts unknown gun '%s' (a removed mod?)" % [did, gid]
	return ""


# ---------------------------------------------------------------------------
# ShipState <-> Dictionary
# ---------------------------------------------------------------------------

static func ship_to_dict(s: ShipState) -> Dictionary:
	# Gun-mount states are plain dicts of bools/ints; deep-duplicate so the save
	# never aliases live state.
	var guns: Array = []
	for g in s.gun_states:
		guns.append(g.duplicate())
	return {
		"def_id": String(s.def.id),
		"side": s.side,
		"hex": s.hex,
		"facing": s.facing,
		"speed": s.speed,
		"straight_moved": s.straight_moved,
		"armor_remaining": s.armor_remaining.duplicate(),
		"systems_remaining": s.systems_remaining.duplicate(),
		"grounded": s.grounded,
		"is_destroyed": s.is_destroyed,
		"fires": s.fires,
		"steering_jammed": s.steering_jammed,
		"officers": s.officers.duplicate(),
		"gun_states": guns,
		"port_buoyancy": s.port_buoyancy,
		"stbd_buoyancy": s.stbd_buoyancy,
		"allocation": s.allocation.duplicate(true),
	}


static func dict_to_ship(d: Dictionary) -> ShipState:
	var s := ShipState.new()
	# The immutable template comes back from the library by id; only the marks
	# below are restored from the save.
	s.def = ShipLibrary.ship(StringName(d["def_id"]))
	s.side = int(d["side"])
	s.hex = d["hex"]
	s.facing = int(d["facing"])
	s.speed = int(d["speed"])
	s.straight_moved = int(d["straight_moved"])
	# assign() (not =) keeps the typed Array[int] / Array[String] element type —
	# see convention #1 in the implementation plan.
	s.armor_remaining.assign(d["armor_remaining"])
	s.systems_remaining = (d["systems_remaining"] as Dictionary).duplicate()
	s.grounded = bool(d["grounded"])
	s.is_destroyed = bool(d["is_destroyed"])
	s.fires = int(d["fires"])
	s.steering_jammed = int(d["steering_jammed"])
	s.officers.assign(d["officers"])
	var guns: Array[Dictionary] = []
	for g in d["gun_states"]:
		guns.append((g as Dictionary).duplicate())
	s.gun_states = guns
	s.port_buoyancy = int(d["port_buoyancy"])
	s.stbd_buoyancy = int(d["stbd_buoyancy"])
	s.allocation = (d["allocation"] as Dictionary).duplicate(true)
	return s
