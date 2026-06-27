class_name ShipLibrary
## Static facade over a data-driven ShipCatalog. The ~30 call sites across rules,
## AI, UI, and tests keep using ShipLibrary.gun()/ship()/ship_ids() unchanged;
## internally each delegates to a swappable active ShipCatalog (loaded from
## res://data/*.json plus user mods). Tests inject a catalog via use_catalog().
## The catalog data files are the single source of truth — there is no longer a
## code-built fallback.

static var _active: ShipCatalog

## The live catalog, lazily built over the default data + mod dirs.
static func _catalog() -> ShipCatalog:
	if _active == null:
		_active = ShipCatalog.new()
	return _active

## Swap in a specific catalog (dependency injection for tests). Pass a fresh
## ShipCatalog.new(temp_dir) to exercise mods without touching the real one.
static func use_catalog(cat: ShipCatalog) -> void:
	_active = cat

## Drop the injected/cached catalog; the next access rebuilds the default.
static func reset_default() -> void:
	_active = null

static func gun(id: StringName) -> GunDef:
	return _catalog().gun(id)

static func ship(id: StringName) -> ShipDef:
	return _catalog().ship(id)

## Does the active catalog know this id? Used by save/load to fail cleanly when a
## save references a ship or gun a (removed) mod used to provide.
static func has_ship(id: StringName) -> bool:
	return _catalog().has_ship(id)

static func has_gun(id: StringName) -> bool:
	return _catalog().has_gun(id)

## All ship-class ids, in definition order (deterministic — Dictionary keeps
## insertion order). The catalog the FleetBuilder and the fleet-builder UI list.
static func ship_ids() -> Array[StringName]:
	return _catalog().ship_ids()

## All gun-type ids, in definition order. Used by the data exporter to dump the
## full gun catalog (mirrors ship_ids()).
static func gun_ids() -> Array[StringName]:
	return _catalog().gun_ids()
