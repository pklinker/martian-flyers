class_name MapCatalog
extends RefCounted
## The map/terrain catalog, loaded from data files. One catalog loads BOTH
## terrain kinds (terrain.json) and maps (maps.json) — the map side references
## kinds, so they belong together, exactly as ShipCatalog loads guns+ships in one
## instance (MAP_MODDING.md §0.1). An INSTANCE (not static) so it is
## dependency-injected: tests build a fresh MapCatalog.new(temp_dir) over a
## throwaway mod folder, and MapLibrary holds one as its active catalog.
##
## Layers, applied in order (last writer wins, by id):
##   1. bundled core  — res://data/terrain.json, res://data/maps.json
##   2. each mod pack — <mod_dir>/<pack>/{terrain,maps}.json  (alphabetical)
## A new id ADDS; an existing id OVERRIDES the whole definition, keeping its slot
## in iteration order (Dictionary reassignment preserves key position), so a map
## picker never reshuffles when a mod retunes a core map or kind.
##
## Referential integrity (a map's cells → the kind set) runs once, after every
## layer is in, so a map in one pack may legally use a kind defined in another —
## the same ordering ShipCatalog uses for ship→gun mounts.

const CORE_TERRAIN := "res://data/terrain.json"
const CORE_MAPS := "res://data/maps.json"
const DEFAULT_MOD_DIR := "user://mods/"

var _kinds: Dictionary = {}     # StringName -> TerrainKindDef, insertion-ordered
var _maps: Dictionary = {}      # StringName -> MapDef, insertion-ordered


func _init(mod_dir: String = DEFAULT_MOD_DIR) -> void:
	_load_terrain(CORE_TERRAIN, "core", "res://")
	_load_maps(CORE_MAPS, "core")
	_scan_mods(mod_dir)
	# Referential integrity runs once, after every layer is in, so a map may use a
	# kind provided by a different pack.
	_drop_maps_with_unknown_kinds()


# --- Public API (mirrors ShipCatalog's shape) ------------------------------

func kind(id: StringName) -> TerrainKindDef:
	return _kinds[id]

func has_kind(id: StringName) -> bool:
	return _kinds.has(id)

func kind_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for id in _kinds.keys():
		out.append(id)
	return out

func map(id: StringName) -> MapDef:
	return _maps[id]

func has_map(id: StringName) -> bool:
	return _maps.has(id)

func map_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for id in _maps.keys():
		out.append(id)
	return out


# --- Loading ----------------------------------------------------------------

## `asset_root` is where this layer's kind assets live (res:// for core, the pack
## root for a mod) — stored on each kind so ModelBaker resolves mod assets (§0.3).
func _load_terrain(path: String, source: String, asset_root: String) -> void:
	var data: Variant = CatalogLoader.read_json(path)
	if data == null:
		return
	for d in (data as Dictionary).get("terrain", []):
		var err := _validate_kind(d)
		if err != "":
			CatalogLoader.reject("MapCatalog", source, "terrain kind", d, err)
			continue
		var k := TerrainKindDef.from_dict(d)
		k.source_root = asset_root
		_kinds[k.id] = k       # add, or override keeping slot

func _load_maps(path: String, source: String) -> void:
	var data: Variant = CatalogLoader.read_json(path)
	if data == null:
		return
	for d in (data as Dictionary).get("maps", []):
		var err := _validate_map(d)
		if err != "":
			CatalogLoader.reject("MapCatalog", source, "map", d, err)
			continue
		var m := MapDef.from_dict(d)
		_maps[m.id] = m

## Each pack may carry terrain.json and/or maps.json. A pack's kinds resolve
## their assets against the pack root (§0.3).
func _scan_mods(mod_dir: String) -> void:
	for p in CatalogLoader.mod_packs(mod_dir):
		var base: String = p["base"]
		var pack: String = p["pack"]
		if FileAccess.file_exists(base.path_join("terrain.json")):
			_load_terrain(base.path_join("terrain.json"), "mod:" + pack, base + "/")
		if FileAccess.file_exists(base.path_join("maps.json")):
			_load_maps(base.path_join("maps.json"), "mod:" + pack)


# --- Validation -------------------------------------------------------------
# Each entry is validated BEFORE it is built, so one bad definition is skipped
# (with a contextual error) rather than crashing the load. Returns "" when valid.
# The schema is intentionally open (§0.6): only the fields the loader cannot
# default are required. Referential integrity (map cell → kind) is checked
# separately, after all layers load.

func _validate_kind(d: Variant) -> String:
	if typeof(d) != TYPE_DICTIONARY:
		return "entry is not an object"
	for key in ["id", "display_name"]:
		if not (d as Dictionary).has(key):
			return "missing required field '%s'" % key
	if String(d["id"]).is_empty():
		return "id is empty"
	if (d as Dictionary).has("spot_penalty") and int(d["spot_penalty"]) < 0:
		return "spot_penalty must be >= 0"
	if (d as Dictionary).has("render") and typeof(d["render"]) != TYPE_DICTIONARY:
		return "render must be an object"
	return ""

func _validate_map(d: Variant) -> String:
	if typeof(d) != TYPE_DICTIONARY:
		return "entry is not an object"
	for key in ["id", "display_name", "cols", "rows", "terrain"]:
		if not (d as Dictionary).has(key):
			return "missing required field '%s'" % key
	if String(d["id"]).is_empty():
		return "id is empty"
	if int(d["cols"]) <= 0 or int(d["rows"]) <= 0:
		return "cols and rows must be > 0"
	if typeof(d["terrain"]) != TYPE_ARRAY:
		return "terrain must be an array"
	for c in d["terrain"]:
		if typeof(c) != TYPE_DICTIONARY or not (c as Dictionary).has("hex") \
				or not (c as Dictionary).has("type"):
			return "a terrain cell is missing 'hex' or 'type'"
		var h: Variant = c["hex"]
		if typeof(h) != TYPE_ARRAY or (h as Array).size() != 2:
			return "a terrain cell 'hex' must be [x, y]"
		if String(c["type"]).is_empty():
			return "a terrain cell has an empty 'type'"
	return ""

## After every layer is loaded: drop any map whose terrain references a kind no
## layer provides (a mod removed a kind a map still uses, or a typo). We drop the
## WHOLE map, not just the cell: a map silently missing a terrain feature has a
## different tactical layout (LOS lanes shift), so it is better to withhold it
## from the picker than to offer a subtly-wrong field. Mirrors ShipCatalog's
## _drop_ships_with_unknown_guns. Loud, contextual (map + kind + hex).
func _drop_maps_with_unknown_kinds() -> void:
	for mid in _maps.keys():
		var m: MapDef = _maps[mid]
		for c in m.terrain:
			if not _kinds.has(c["type"]):
				var h: Vector2i = c["hex"]
				push_error("MapCatalog: map '%s' uses unknown terrain kind '%s' at (%d,%d) — dropping the map" \
						% [mid, String(c["type"]), h.x, h.y])
				_maps.erase(mid)
				break
