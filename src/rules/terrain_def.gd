class_name TerrainDef
## Static data and LOS/spotting rules for terrain features.
## Terrain tiles live in TurnEngine.terrain (Vector2i → TerrainDef.Type).
## Hills and towers block line of sight. Dust storms impose spotting penalties
## that the firer's lookout crew can partially or fully cancel.

enum Type { HILL, TOWER, DUST_STORM }

## True if this terrain type physically blocks line of sight.
static func blocks_los(type: int) -> bool:
	return type == Type.HILL or type == Type.TOWER

## Extra to-hit penalty per hex of this type along the LOS path.
static func spot_penalty(type: int) -> int:
	return 1 if type == Type.DUST_STORM else 0

## True if LOS between `a` and `b` is unobstructed. Only the hexes strictly
## between the two endpoints are tested — a ship sitting on a hill is
## shootable; only a hill in between blocks the shot.
static func los_clear(a: Vector2i, b: Vector2i, terrain: Dictionary) -> bool:
	for h: Vector2i in HexMath.line_hexes(a, b):
		if blocks_los(int(terrain.get(h, -1))):
			return false
	return true

## Total spotting penalty for a shot from `a` to `b`. Counts dust in the
## intermediate hexes plus the target's own hex (a hidden target is hard to
## hit). The firer's own hex is excluded — you know where you're shooting from.
static func dust_along(a: Vector2i, b: Vector2i, terrain: Dictionary) -> int:
	var total := 0
	for h: Vector2i in HexMath.line_hexes(a, b):
		total += spot_penalty(int(terrain.get(h, -1)))
	total += spot_penalty(int(terrain.get(b, -1)))
	return total

static func display_name(type: int) -> String:
	match type:
		Type.HILL: return "Hill"
		Type.TOWER: return "Tower"
		Type.DUST_STORM: return "Dust"
	return "?"

## Fill color for map rendering.
static func render_color(type: int) -> Color:
	match type:
		Type.HILL: return Color(0.50, 0.35, 0.15, 0.80)
		Type.TOWER: return Color(0.42, 0.42, 0.42, 0.88)
		Type.DUST_STORM: return Color(0.85, 0.72, 0.28, 0.42)
	return Color(0.5, 0.5, 0.5, 0.5)
