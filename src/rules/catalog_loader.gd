class_name CatalogLoader
extends RefCounted
## Shared loading machinery for the data catalogs. Both ShipCatalog (guns +
## ships) and MapCatalog (terrain kinds + maps) layer bundled res:// data over
## alphabetical user mod packs with identical scan / read / reject rules; this
## holds the common parts so neither catalog reimplements them (DRY —
## MAP_MODDING.md §0.1). Pure static helpers, tree-free, safe from a unit test.

## Parse a JSON object file. Returns the Dictionary, or null on a missing file or
## a parse error (logged). A missing core file is a packaging bug; a missing mod
## file just means that pack does not provide that data type.
static func read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("CatalogLoader: %s is not a JSON object" % path)
		return null
	return parsed

## Enumerate mod packs under `mod_dir`, alphabetical so the merge is
## deterministic (last writer wins). Returns one entry per subfolder:
##   { "pack": <name>, "base": <mod_dir>/<name> }
## `base` is the pack root, so a caller resolves any file it needs from it
## (guns.json, ships.json, maps.json, terrain.json, assets/…). An absent mod dir
## is not an error — it just yields no packs.
static func mod_packs(mod_dir: String) -> Array:
	var out: Array = []
	if not DirAccess.dir_exists_absolute(mod_dir):
		return out
	var packs := DirAccess.get_directories_at(mod_dir)
	packs.sort()
	for pack in packs:
		out.append({ "pack": pack, "base": mod_dir.path_join(pack) })
	return out

## A rejected entry: loud, contextual, and skipped — never crashes the load,
## never poisons the catalog. `catalog` names the owner ("ShipCatalog" /
## "MapCatalog"), `source` the layer ("core" / "mod:<pack>").
static func reject(catalog: String, source: String, kind: String, d: Variant, err: String) -> void:
	var id_str := "?"
	if typeof(d) == TYPE_DICTIONARY and (d as Dictionary).has("id"):
		id_str = String(d["id"])
	push_error("%s[%s]: skipped %s '%s' — %s" % [catalog, source, kind, id_str, err])
