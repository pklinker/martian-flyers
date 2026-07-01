class_name MapDef
extends Resource
## One playable map, loaded from data (res://data/maps.json plus mod packs). A
## map is the board size, the per-side deployment rules, and the terrain laid on
## it — everything TurnEngine._place_terrain() and the map-size / deploy consts
## hard-code today (MAP_MODDING.md §4). Terrain cells reference terrain KINDS by
## id (MapCatalog resolves them; see referential integrity in map_catalog.gd).
##
## NOTE (T2 scope): TurnEngine does not consume this yet. apply_map() and the
## DEFAULT_ deploy-const split are T4; here the def + a parity test that
## dead_sea_bottom reproduces today's _place_terrain() cells and 48×48 / 24 / 10
## constants exactly, so T4 can wire it in with zero drift.

@export var id: StringName = &"map"
@export var display_name: String = "Untitled Field"

## Board dimensions (hex columns × rows). Default mirrors TurnEngine's current
## map_cols/map_rows so an omitted size reproduces today's field.
@export var cols: int = 48
@export var rows: int = 48

## Per-side deployment band + spacing. Defaults mirror TurnEngine's current
## DEPLOY_ZONE_COLS / DEPLOY_MIN_SEPARATION (24 / 10). T4 promotes those consts
## to DEFAULT_ + instance vars and has apply_map() read these (§0.7).
@export var deploy_zone_cols: int = 24
@export var deploy_min_separation: int = 10

## Terrain cells: Array of { "hex": Vector2i, "type": StringName-kind-id }.
## Stored parsed (Vector2i keys, StringName ids) so callers build the engine
## terrain dict directly via terrain_map().
@export var terrain: Array[Dictionary] = []


## The engine terrain dict this map produces: Vector2i hex → StringName kind id.
## (The int-enum engine of T2 doesn't use this yet; T4 feeds it into apply_map.)
func terrain_map() -> Dictionary:
	var out: Dictionary = {}
	for c in terrain:
		out[c["hex"]] = c["type"]
	return out

## Every distinct kind id this map references — MapCatalog's referential-integrity
## pass checks each against the loaded kind set (§0.2).
func kind_ids_used() -> Array[StringName]:
	var seen: Array[StringName] = []
	for c in terrain:
		var t: StringName = c["type"]
		if not seen.has(t):
			seen.append(t)
	return seen


# --- Serialization (mirrors ShipDef/GunDef) --------------------------------

func to_dict() -> Dictionary:
	var cells: Array = []
	for c in terrain:
		var h: Vector2i = c["hex"]
		cells.append({ "hex": [h.x, h.y], "type": String(c["type"]) })
	return {
		"id": String(id),
		"display_name": display_name,
		"cols": cols,
		"rows": rows,
		"deploy_zone_cols": deploy_zone_cols,
		"deploy_min_separation": deploy_min_separation,
		"terrain": cells,
	}

## Absent size/deploy fields default (open schema). `id`, `display_name`, `cols`,
## `rows`, and a well-formed `terrain` array are enforced by
## MapCatalog._validate_map before this runs.
static func from_dict(d: Dictionary) -> MapDef:
	var m := MapDef.new()
	m.id = StringName(d["id"])
	m.display_name = String(d["display_name"])
	m.cols = int(d.get("cols", 48))
	m.rows = int(d.get("rows", 48))
	m.deploy_zone_cols = int(d.get("deploy_zone_cols", 24))
	m.deploy_min_separation = int(d.get("deploy_min_separation", 10))
	var cells: Array[Dictionary] = []
	for c in d.get("terrain", []):
		var h: Array = c["hex"]
		cells.append({
			"hex": Vector2i(int(h[0]), int(h[1])),
			"type": StringName(c["type"]),
		})
	m.terrain.assign(cells)
	return m
