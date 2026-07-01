class_name TerrainKindDef
extends Resource
## One kind of terrain feature, loaded from data (res://data/terrain.json plus
## mod packs). Replaces the hard-coded TerrainDef enum + static rules + the
## per-model tuning baked into ModelBaker._register, so a new kind (hill, tower,
## crystal spire, gas cloud…) is a data edit plus its asset — MAP_MODDING.md §5.
##
## This def carries BOTH the rules the engine reads (blocks_los / spot_penalty)
## and the presentation config the map view reads (render). The rules layer
## ignores `render`; the UI ignores nothing. That mirrors the old TerrainDef,
## which likewise mixed LOS rules and render_color/height in one place.
##
## The schema is intentionally open (§0.6): unknown/absent fields DEFAULT rather
## than reject, so future rule fields (partial LOS, movement cost, cover) can be
## added to the JSON without a data-file rewrite.
##
## NOTE (T2 scope): nothing in the running engine consumes this yet. The
## enum→string-id migration that swaps TerrainDef for these defs is T3; here the
## def exists and a parity test asserts the three core kinds reproduce today's
## hard-coded values exactly, so T3 can flip the source with zero behaviour drift.

@export var id: StringName = &"kind"
@export var display_name: String = "Terrain"
## Editor/asset grouping only — "terrain" | "building". Rules never read it; it
## decides which assets/<dir> a kind's models live under and how the 3d-gen
## palette groups them. A building is just a kind with category "building".
@export var category: String = "terrain"

## True if this kind physically blocks line of sight (hills, towers).
@export var blocks_los: bool = false
## Extra to-hit penalty per hex of this kind along the LOS path (dust storms).
@export var spot_penalty: int = 0

## Presentation config, read only by the map view. Shape:
##   { "color": [r,g,b,a],          # flat-tile fill / marker colour
##     "height": <float>,           # iso massing height (0 = no solid massing)
##     "model": { "dir","prefix","frame","span","look_y","anchor" },  # extruded mesh
##     "sprite": { "prefix","span","anchor" } }                        # animated billboard
## A kind with a "model" block bakes an extruded mesh; one with a "sprite" block
## plays an animated sheet; one with neither draws the procedural primitive. This
## is what the renderer branches on in T5 (render-type property, not an id — §0.6).
@export var render: Dictionary = {}

## Where this kind's assets live: "res://" for core, the pack root
## ("user://mods/<pack>/") for a mod kind. ModelBaker/DustSprites resolve a
## model as <source_root>/assets/<dir>/<prefix>_N (§0.3). Derived at load, not
## authored, so it is not part of to_dict/from_dict.
var source_root: String = "res://"


# --- Rules accessors (mirror the old TerrainDef static funcs, resolved per kind).
# T3 swaps `TerrainDef.blocks_los(int)` for `MapLibrary.kind(id).blocks_los`, etc.

func render_color() -> Color:
	var c: Variant = render.get("color", [0.5, 0.5, 0.5, 0.5])
	if typeof(c) == TYPE_ARRAY and (c as Array).size() >= 4:
		return Color(float(c[0]), float(c[1]), float(c[2]), float(c[3]))
	return Color(0.5, 0.5, 0.5, 0.5)

func render_height() -> float:
	return float(render.get("height", 0.0))

## "model" (extruded mesh), "sprite" (animated billboard), or "" (procedural).
## The renderer branches on THIS, never on a specific id (§0.6).
func render_type() -> String:
	if render.has("model"):
		return "model"
	if render.has("sprite"):
		return "sprite"
	return ""

func has_model() -> bool:
	return render.has("model")

func has_sprite() -> bool:
	return render.has("sprite")


# --- Serialization (mirrors ShipDef/GunDef) --------------------------------

func to_dict() -> Dictionary:
	return {
		"id": String(id),
		"display_name": display_name,
		"category": category,
		"blocks_los": blocks_los,
		"spot_penalty": spot_penalty,
		"render": render.duplicate(true),
	}

## Absent fields default (open schema) — only `id` and `display_name` are
## required, enforced by MapCatalog._validate_kind before this runs.
static func from_dict(d: Dictionary) -> TerrainKindDef:
	var k := TerrainKindDef.new()
	k.id = StringName(d["id"])
	k.display_name = String(d["display_name"])
	k.category = String(d.get("category", "terrain"))
	k.blocks_los = bool(d.get("blocks_los", false))
	k.spot_penalty = int(d.get("spot_penalty", 0))
	k.render = (d.get("render", {}) as Dictionary).duplicate(true)
	return k
