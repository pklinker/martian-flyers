class_name ShipCatalog
extends RefCounted
## The ship/gun catalog, loaded from data files. Replaces ShipLibrary's
## hard-coded _ensure_built(). An INSTANCE (not static) so it can be dependency-
## injected: tests build a fresh ShipCatalog.new(temp_dir) over a throwaway mod
## folder with no global state to reset, and ShipLibrary holds one as its active
## catalog for the ~30 call sites that still use the static facade.
##
## Layers, applied in order (last writer wins, by id):
##   1. bundled core  — res://data/guns.json, res://data/ships.json
##   2. each mod pack — <mod_dir>/<pack>/guns.json, ships.json  (alphabetical)
## A new id ADDS; an existing id OVERRIDES the whole definition, keeping its slot
## in iteration order (Dictionary reassignment preserves key position), so the
## fleet-builder list never reshuffles when a mod retunes a core hull.
##
## Validation (schema, referential integrity) lands in a later step; this stage
## is the faithful migration off code-built data, guarded by the parity test.

const CORE_GUNS := "res://data/guns.json"
const CORE_SHIPS := "res://data/ships.json"
const DEFAULT_MOD_DIR := "user://mods/"

var _guns: Dictionary = {}      # StringName -> GunDef, insertion-ordered
var _ships: Dictionary = {}     # StringName -> ShipDef, insertion-ordered


func _init(mod_dir: String = DEFAULT_MOD_DIR) -> void:
	_load_guns(CORE_GUNS, "core")
	_load_ships(CORE_SHIPS, "core")
	_scan_mods(mod_dir)
	# Referential integrity runs once, after every layer is in, so a ship in one
	# pack may legally mount a gun defined in another.
	_drop_ships_with_unknown_guns()


# --- Public API (mirrors the old ShipLibrary statics) ----------------------

func gun(id: StringName) -> GunDef:
	return _guns[id]

func ship(id: StringName) -> ShipDef:
	return _ships[id]

func has_gun(id: StringName) -> bool:
	return _guns.has(id)

func has_ship(id: StringName) -> bool:
	return _ships.has(id)

func ship_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for id in _ships.keys():
		out.append(id)
	return out

func gun_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for id in _guns.keys():
		out.append(id)
	return out


# --- Loading ----------------------------------------------------------------

func _load_guns(path: String, source: String) -> void:
	var data: Variant = CatalogLoader.read_json(path)
	if data == null:
		return
	for d in (data as Dictionary).get("guns", []):
		var err := _validate_gun(d)
		if err != "":
			CatalogLoader.reject("ShipCatalog", source, "gun", d, err)
			continue
		var g := GunDef.from_dict(d)
		_guns[g.id] = g       # add, or override keeping slot

func _load_ships(path: String, source: String) -> void:
	var data: Variant = CatalogLoader.read_json(path)
	if data == null:
		return
	for d in (data as Dictionary).get("ships", []):
		var err := _validate_ship(d)
		if err != "":
			CatalogLoader.reject("ShipCatalog", source, "ship", d, err)
			continue
		var s := ShipDef.from_dict(d)
		_ships[s.id] = s

## Scan a mods folder: each subfolder is a pack that may carry guns.json and/or
## ships.json. Alphabetical order (via CatalogLoader.mod_packs) makes the merge
## deterministic.
func _scan_mods(mod_dir: String) -> void:
	for p in CatalogLoader.mod_packs(mod_dir):
		var base: String = p["base"]
		var pack: String = p["pack"]
		if FileAccess.file_exists(base.path_join("guns.json")):
			_load_guns(base.path_join("guns.json"), "mod:" + pack)
		if FileAccess.file_exists(base.path_join("ships.json")):
			_load_ships(base.path_join("ships.json"), "mod:" + pack)


# --- Validation -------------------------------------------------------------
# Each entry is validated against the schema BEFORE it is built, so one bad
# definition is skipped (with a contextual error) rather than crashing the load
# or poisoning the catalog. Returns "" when valid, else a human error message.
# Referential integrity (mount gun_id resolves) is checked separately, after all
# layers load, since a ship may legally mount a gun from another pack.

func _validate_gun(d: Variant) -> String:
	if typeof(d) != TYPE_DICTIONARY:
		return "entry is not an object"
	for key in ["id", "display_name", "size", "reload_turns", "crew_required", "range_brackets"]:
		if not (d as Dictionary).has(key):
			return "missing required field '%s'" % key
	if String(d["id"]).is_empty():
		return "id is empty"
	if not GunDef.Size.keys().has(String(d["size"])):
		return "unknown size '%s' (expected one of %s)" % [d["size"], GunDef.Size.keys()]
	for key in ["reload_turns", "crew_required"]:
		if int(d[key]) < 0:
			return "%s must be >= 0" % key
	for key in ["ammo", "armor_piercing"]:
		if (d as Dictionary).has(key) and int(d[key]) < 0:
			return "%s must be >= 0" % key
	var brackets: Variant = d["range_brackets"]
	if typeof(brackets) != TYPE_ARRAY or (brackets as Array).is_empty():
		return "range_brackets must be a non-empty array"
	var prev := -1
	for b in brackets:
		for bk in ["max_range", "to_hit", "damage"]:
			if not (b as Dictionary).has(bk):
				return "range bracket missing '%s'" % bk
		if int(b["max_range"]) <= prev:
			return "range_brackets max_range must strictly increase (saw %d after %d)" % [int(b["max_range"]), prev]
		prev = int(b["max_range"])
	return ""

func _validate_ship(d: Variant) -> String:
	if typeof(d) != TYPE_DICTIONARY:
		return "entry is not an object"
	for key in ["id", "display_name", "armor", "systems", "gun_mounts",
			"base_max_speed", "engine_crew_per_speed", "grounding_threshold",
			"turn_mode_by_speed"]:
		if not (d as Dictionary).has(key):
			return "missing required field '%s'" % key
	if String(d["id"]).is_empty():
		return "id is empty"
	if typeof(d["armor"]) != TYPE_ARRAY or (d["armor"] as Array).size() != 6:
		return "armor must be an array of exactly 6 facings"
	if typeof(d["systems"]) != TYPE_DICTIONARY:
		return "systems must be an object"
	for name in (d["systems"] as Dictionary):
		if not ShipDef.SystemType.keys().has(String(name)):
			return "unknown system '%s' (expected one of %s)" % [name, ShipDef.SystemType.keys()]
		if int(d["systems"][name]) < 0:
			return "system '%s' count must be >= 0" % name
	if typeof(d["gun_mounts"]) != TYPE_ARRAY:
		return "gun_mounts must be an array"
	for m in d["gun_mounts"]:
		if not (m as Dictionary).has("gun_id") or String(m["gun_id"]).is_empty():
			return "a gun mount is missing gun_id"
		if not (m as Dictionary).has("arcs") or typeof(m["arcs"]) != TYPE_ARRAY:
			return "gun mount '%s' is missing an arcs array" % m.get("gun_id", "?")
		for a in m["arcs"]:
			if int(a) < 0 or int(a) > 5:
				return "gun mount '%s' has arc %d outside 0..5" % [m["gun_id"], int(a)]
	if typeof(d["turn_mode_by_speed"]) != TYPE_ARRAY or (d["turn_mode_by_speed"] as Array).is_empty():
		return "turn_mode_by_speed must be a non-empty array"
	if (d as Dictionary).has("acceleration") and int(d["acceleration"]) < 1:
		return "acceleration must be >= 1"
	return ""

## After every layer is loaded: drop any ship whose mount references a gun no
## layer provides (e.g. a mod removed a gun a hull still mounts). Errors are
## loud; the ship is removed so the rest of the catalog stays usable.
func _drop_ships_with_unknown_guns() -> void:
	for sid in _ships.keys():
		var s: ShipDef = _ships[sid]
		for m in s.gun_mounts:
			if not _guns.has(m["gun_id"]):
				push_error("ShipCatalog: ship '%s' mounts unknown gun '%s' — dropping the ship" % [sid, m["gun_id"]])
				_ships.erase(sid)
				break

# Rejection logging and JSON reading now live in the shared CatalogLoader
# (CatalogLoader.reject / .read_json), used by both ShipCatalog and MapCatalog.
