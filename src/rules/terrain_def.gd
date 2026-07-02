class_name TerrainDef
## LOS / spotting rules and render lookups for terrain, resolved through the
## data-driven terrain-kind catalog (MapLibrary.kind). Terrain tiles live in
## TurnEngine.terrain (Vector2i → StringName kind id).
##
## This is now a thin static facade over the catalog: it keeps the los_clear /
## dust_along line-walk helpers (the rules the engine and AI call) and delegates
## every per-kind property to the loaded TerrainKindDef. The old int enum and the
## hard-coded rule/render tables moved into res://data/terrain.json
## (MAP_MODDING.md §5); a parity test proved the data reproduced the previous
## values before this swap, so behaviour is unchanged.

## StringName sentinel for "no terrain at this hex": a Dictionary miss returns it,
## the catalog has no such kind, so blocks_los / spot_penalty read false / 0.
const NONE := &""


## True if this kind physically blocks line of sight (hills, towers).
static func blocks_los(id: StringName) -> bool:
	return MapLibrary.has_kind(id) and MapLibrary.kind(id).blocks_los

## Extra to-hit penalty per hex of this kind along the LOS path (dust storms).
static func spot_penalty(id: StringName) -> int:
	return MapLibrary.kind(id).spot_penalty if MapLibrary.has_kind(id) else 0

## True if LOS between `a` and `b` is unobstructed. Only the hexes strictly
## between the two endpoints are tested — a ship sitting on a hill is shootable;
## only a hill in between blocks the shot.
static func los_clear(a: Vector2i, b: Vector2i, terrain: Dictionary) -> bool:
	for h: Vector2i in HexMath.line_hexes(a, b):
		if blocks_los(terrain.get(h, NONE)):
			return false
	return true

## Total spotting penalty for a shot from `a` to `b`. Counts dust in the
## intermediate hexes plus the target's own hex (a hidden target is hard to hit).
## The firer's own hex is excluded — you know where you're shooting from.
static func dust_along(a: Vector2i, b: Vector2i, terrain: Dictionary) -> int:
	var total := 0
	for h: Vector2i in HexMath.line_hexes(a, b):
		total += spot_penalty(terrain.get(h, NONE))
	total += spot_penalty(terrain.get(b, NONE))
	return total


# --- Presentation lookups (map view only; rules never call these) ----------

static func display_name(id: StringName) -> String:
	return MapLibrary.kind(id).display_name if MapLibrary.has_kind(id) else "?"

## Fill color for map rendering.
static func render_color(id: StringName) -> Color:
	return MapLibrary.kind(id).render_color() if MapLibrary.has_kind(id) else Color(0.5, 0.5, 0.5, 0.5)

## World-height a feature rises to in isometric (presentation only — rules never
## read this).
static func render_height(id: StringName) -> float:
	return MapLibrary.kind(id).render_height() if MapLibrary.has_kind(id) else 0.0

## Footprint radius (hex units) of a terrain prism fallback — hills fill the hex,
## towers stand in a narrow column. Data-driven via render.footprint (default 1).
static func render_footprint(id: StringName) -> float:
	return MapLibrary.kind(id).render_footprint() if MapLibrary.has_kind(id) else 1.0

## True if this kind is drawn as an animated sprite (dust, gas cloud) rather than
## an extruded mesh. The map view branches on THIS render-type property, never on
## a specific id (MAP_MODDING.md §0.6), so a new animated kind works for free.
static func is_sprite(id: StringName) -> bool:
	return MapLibrary.has_kind(id) and MapLibrary.kind(id).render_type() == "sprite"
