class_name HexMath
## Static hex-grid math for a flat-top hex map using axial coordinates (q, r).
## Facing 0 = "north", facings increase clockwise 0..5.
## Pure functions only — no game state lives here.

## Axial direction vectors indexed by facing (flat-top, clockwise from north).
const DIRS: Array[Vector2i] = [
	Vector2i(0, -1),   # 0: N
	Vector2i(1, -1),   # 1: NE
	Vector2i(1, 0),    # 2: SE
	Vector2i(0, 1),    # 3: S
	Vector2i(-1, 1),   # 4: SW
	Vector2i(-1, 0),   # 5: NW
]

static func neighbor(hex: Vector2i, facing: int) -> Vector2i:
	return hex + DIRS[facing % 6]

static func distance(a: Vector2i, b: Vector2i) -> int:
	var dq := b.x - a.x
	var dr := b.y - a.y
	return (abs(dq) + abs(dr) + abs(dq + dr)) / 2

## Converts axial coords to 2D cartesian (unit hex size) for angle math.
static func to_cartesian(hex: Vector2i) -> Vector2:
	var x := 1.5 * hex.x
	var y := sqrt(3.0) * (hex.y + hex.x / 2.0)
	return Vector2(x, y)

## Absolute bearing (0..5) from hex `a` toward hex `b`, snapped to the
## nearest of the six facing directions. Returns -1 if a == b.
static func bearing(a: Vector2i, b: Vector2i) -> int:
	if a == b:
		return -1
	var v := to_cartesian(b) - to_cartesian(a)
	# Facing 0 points "up" (negative y in screen space).
	var angle := rad_to_deg(atan2(v.x, -v.y))  # 0 = north, clockwise positive
	if angle < 0.0:
		angle += 360.0
	return int(round(angle / 60.0)) % 6

## Relative bearing of `target_hex` as seen from a ship at `own_hex` with
## `own_facing`. 0 = dead ahead, 1 = forward-starboard, 2 = aft-starboard,
## 3 = dead astern, 4 = aft-port, 5 = forward-port.
static func relative_bearing(own_hex: Vector2i, own_facing: int, target_hex: Vector2i) -> int:
	var abs_bearing := bearing(own_hex, target_hex)
	if abs_bearing == -1:
		return -1
	return (abs_bearing - own_facing + 6) % 6

## Which armor facing of the TARGET is struck by fire coming from `firer_hex`.
## Same sector math, computed from the target's point of view.
static func struck_facing(target_hex: Vector2i, target_facing: int, firer_hex: Vector2i) -> int:
	return relative_bearing(target_hex, target_facing, firer_hex)

## The axial hexes strictly between `a` and `b` (endpoints excluded) that the
## straight line passes through. Used for LOS checks: if any returned hex
## contains a blocking terrain tile, the shot is obstructed. A tiny nudge on
## the start point resolves ambiguity when the line grazes a hex vertex.
static func line_hexes(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var n := distance(a, b)
	if n <= 1:
		return []
	const EPS := 1e-6
	var aq := float(a.x) + EPS
	var ar := float(a.y) + EPS
	var bq := float(b.x)
	var br := float(b.y)
	var out: Array[Vector2i] = []
	for i in range(1, n):
		var t := float(i) / float(n)
		out.append(_cube_round_axial(aq + (bq - aq) * t, ar + (br - ar) * t))
	return out

static func _cube_round_axial(fq: float, fr: float) -> Vector2i:
	var fs := -fq - fr
	var rq := roundf(fq); var rr := roundf(fr); var rs := roundf(fs)
	var dq := absf(rq - fq); var dr := absf(rr - fr); var ds := absf(rs - fs)
	if dq > dr and dq > ds:
		rq = -rr - rs
	elif dr > ds:
		rr = -rq - rs
	return Vector2i(int(rq), int(rr))
