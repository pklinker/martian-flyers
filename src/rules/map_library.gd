class_name MapLibrary
extends RefCounted
## Static facade over a data-driven MapCatalog — the map/terrain analogue of
## ShipLibrary. Callers use MapLibrary.map(id)/kind(id)/map_ids(); internally
## each delegates to a swappable active MapCatalog (res://data + user mods).
## Tests inject a catalog via use_catalog(). The data files are the single source
## of truth — no code-built fallback (MAP_MODDING.md §0.1).

static var _active: MapCatalog

## The live catalog, lazily built over the default data + mod dirs.
static func _catalog() -> MapCatalog:
	if _active == null:
		_active = MapCatalog.new()
	return _active

## Swap in a specific catalog (dependency injection for tests). Pass a fresh
## MapCatalog.new(temp_dir) to exercise mods without touching the real one.
static func use_catalog(cat: MapCatalog) -> void:
	_active = cat

## Drop the injected/cached catalog; the next access rebuilds the default.
static func reset_default() -> void:
	_active = null

# --- Terrain kinds ---------------------------------------------------------

static func kind(id: StringName) -> TerrainKindDef:
	return _catalog().kind(id)

static func has_kind(id: StringName) -> bool:
	return _catalog().has_kind(id)

## All kind ids, in definition order (deterministic — Dictionary keeps insertion
## order). The 3d-gen palette and the (T3) renderer iterate this.
static func kind_ids() -> Array[StringName]:
	return _catalog().kind_ids()

# --- Maps ------------------------------------------------------------------

static func map(id: StringName) -> MapDef:
	return _catalog().map(id)

## Does the active catalog know this map? Used by save/load (T6) to fail cleanly
## when a save references a map a removed mod used to provide.
static func has_map(id: StringName) -> bool:
	return _catalog().has_map(id)

## All map ids, in definition order. The map picker (T3 UI) lists these.
static func map_ids() -> Array[StringName]:
	return _catalog().map_ids()
