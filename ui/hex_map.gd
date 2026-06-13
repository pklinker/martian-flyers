class_name HexMapView
extends Control
## Tactical map: flat-top hex grid matching HexMath's geometry (facing 0 =
## north, clockwise). Renders ship tokens with facing arrows, plus clickable
## highlights for legal moves. Contains no rules logic — it draws engine
## state and reports clicks.

signal move_clicked(move: Dictionary)
signal hex_clicked(hex: Vector2i)
signal map_pressed                         # any left-click on the map surface

const SQRT3 := 1.7320508

@export var cols := 16
@export var rows := 12
@export var hex_size := 34.0          # circumradius R; recomputed each frame by the camera

const DEFAULT_HEX := 34.0             # comfortable zoom; the camera only zooms OUT from here
const MIN_HEX := 10.0                 # floor so far-apart ships stay on screen
const SHIP_MARGIN := 3.0              # breathing room around the ships, in hex radii
const HALF_W := 1.0                    # flat-top hex half-width  (R)
const HALF_H := 0.8660254              # flat-top hex half-height (R·√3/2)

const SEA_BOTTOM := Color(0.87, 0.80, 0.66)   # dead sea bottom ochre
const GRID := Color(0.45, 0.38, 0.28, 0.55)
const HIGHLIGHT := Color(0.25, 0.60, 0.25, 0.45)
const HIGHLIGHT_EDGE := Color(0.15, 0.45, 0.15)
const ACTIVE_RING := Color(0.95, 0.75, 0.15)
const SIDE_COLORS: Array[Color] = [Color(0.16, 0.32, 0.62), Color(0.62, 0.16, 0.13)]
const WRECK := Color(0.35, 0.32, 0.30)

var engine: TurnEngine
var highlight_moves: Array[Dictionary] = []
var active_ship: ShipState

var _origin := Vector2.ZERO


func set_engine(e: TurnEngine) -> void:
	engine = e
	# The engine owns the playfield dimensions; the view just needs to know how
	# far the grid extends. The camera frames the ships, not the whole field.
	if e != null:
		cols = e.map_cols
		rows = e.map_rows
	queue_redraw()

func set_highlights(moves: Array[Dictionary], for_ship: ShipState) -> void:
	highlight_moves = moves
	active_ship = for_ship
	queue_redraw()

func clear_highlights() -> void:
	highlight_moves = []
	queue_redraw()


# ---------------------------------------------------------------------------
# Geometry: pixel <-> hex, matching HexMath.to_cartesian scaled by hex_size.
# ---------------------------------------------------------------------------

func hex_to_pixel(hex: Vector2i) -> Vector2:
	var c := HexMath.to_cartesian(hex)
	return _origin + c * hex_size

func pixel_to_hex(p: Vector2) -> Vector2i:
	var pt := (p - _origin) / hex_size
	var fq := (2.0 / 3.0) * pt.x
	var fr := (-1.0 / 3.0) * pt.x + (SQRT3 / 3.0) * pt.y
	return _cube_round(fq, fr)

static func _cube_round(fq: float, fr: float) -> Vector2i:
	var fs := -fq - fr
	var q := roundf(fq)
	var r := roundf(fr)
	var s := roundf(fs)
	var dq := absf(q - fq)
	var dr := absf(r - fr)
	var ds := absf(s - fs)
	if dq > dr and dq > ds:
		q = -r - s
	elif dr > ds:
		r = -q - s
	return Vector2i(int(q), int(r))

## Map uses an axial parallelogram squared off: column q holds rows
## r in [-(q>>1) .. -(q>>1)+rows-1], giving a roughly rectangular field.
func row_offset(q: int) -> int:
	return -(q >> 1)

## On-field test. Whether a hex is in play is a rule, so defer to the engine
## when present; the local rectangle is only a fallback for a standalone view.
func contains(hex: Vector2i) -> bool:
	if engine != null:
		return engine.map_contains(hex)
	if hex.x < 0 or hex.x >= cols:
		return false
	var off := row_offset(hex.x)
	return hex.y >= off and hex.y < off + rows

func _ready() -> void:
	clip_contents = true                  # keep the scrolling field inside the map rect
	resized.connect(queue_redraw)


## Follow camera: each draw, frame the live ships. Hold a comfortable default
## zoom and just scroll to keep them centered; zoom OUT only when they separate
## far enough that both wouldn't otherwise fit. The board is large, so the edge
## is effectively never in view — the field reads as open. Sets `_origin` and
## `hex_size`; never queues a redraw (it runs inside `_draw`).
func _frame_camera() -> void:
	var lo := Vector2(INF, INF)
	var hi := -lo
	var n := 0
	if engine != null:
		for s in engine.ships:
			if s.is_destroyed:
				continue
			var c := HexMath.to_cartesian(s.hex)
			lo = lo.min(c)
			hi = hi.max(c)
			n += 1
	if n == 0:
		lo = Vector2.ZERO
		hi = Vector2.ZERO
	var w_units := (hi.x - lo.x) + 2.0 * (HALF_W + SHIP_MARGIN)
	var h_units := (hi.y - lo.y) + 2.0 * (HALF_H + SHIP_MARGIN)
	var fit := minf(size.x / w_units, size.y / h_units)
	hex_size = clampf(fit, MIN_HEX, DEFAULT_HEX)
	_origin = size * 0.5 - (lo + hi) * 0.5 * hex_size


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		map_pressed.emit()
		var hex := pixel_to_hex(event.position)
		if not contains(hex):
			return
		for m in highlight_moves:
			if m["hex"] == hex:
				move_clicked.emit(m)
				return
		hex_clicked.emit(hex)


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

func _corners(center: Vector2) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 6:
		var a := deg_to_rad(60.0 * i)
		pts.append(center + hex_size * Vector2(cos(a), sin(a)))
	return pts

static func _facing_dir(facing: int) -> Vector2:
	var a := deg_to_rad(facing * 60.0)
	return Vector2(sin(a), -cos(a))

func _draw() -> void:
	_frame_camera()
	draw_rect(Rect2(Vector2.ZERO, size), SEA_BOTTOM, true)
	var font := get_theme_default_font()

	# Grid — only the cells the camera currently shows (the field is large).
	var cull := hex_size * 1.5
	for q in cols:
		var off := row_offset(q)
		for r in range(off, off + rows):
			var c := hex_to_pixel(Vector2i(q, r))
			if c.x < -cull or c.x > size.x + cull or c.y < -cull or c.y > size.y + cull:
				continue
			var pts := _corners(c)
			draw_polyline(pts + PackedVector2Array([pts[0]]), GRID, 1.0)

	# Terrain (above grid, below highlights and ships)
	if engine != null:
		for hex: Vector2i in engine.terrain:
			var c := hex_to_pixel(hex)
			if c.x < -cull or c.x > size.x + cull or c.y < -cull or c.y > size.y + cull:
				continue
			var t: int = engine.terrain[hex]
			var col := TerrainDef.render_color(t)
			draw_colored_polygon(_corners(c), col)
			# Heavier border on LOS-blocking terrain so captains can spot it.
			var edge_col := col.darkened(0.35)
			var edge_w := 2.5 if TerrainDef.blocks_los(t) else 1.0
			var pts := _corners(c)
			draw_polyline(pts + PackedVector2Array([pts[0]]), edge_col, edge_w)
			# Single-letter label: H = Hill, T = Tower, D = Dust.
			draw_string(font, c + Vector2(-4.0, 5.0),
					TerrainDef.display_name(t).substr(0, 1),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
					Color(0.12, 0.08, 0.03, 0.90))

	# Legal-move highlights
	for m in highlight_moves:
		var c := hex_to_pixel(m["hex"])
		draw_colored_polygon(_corners(c), HIGHLIGHT)
		var pts := _corners(c)
		draw_polyline(pts + PackedVector2Array([pts[0]]), HIGHLIGHT_EDGE, 2.0)
		# Small tick showing the facing the ship will have after this move.
		draw_line(c, c + _facing_dir(m["facing"]) * hex_size * 0.55, HIGHLIGHT_EDGE, 2.0)

	if engine == null:
		return

	# Ships
	for s in engine.ships:
		_draw_ship(font, s)


func _draw_ship(font: Font, s: ShipState) -> void:
	var c := hex_to_pixel(s.hex)
	var col: Color = WRECK if (s.is_destroyed or s.grounded) else SIDE_COLORS[s.side]

	# Active-ship ring
	if s == active_ship:
		draw_arc(c, hex_size * 0.92, 0.0, TAU, 32, ACTIVE_RING, 3.0)

	# Hull: triangle pointing at facing
	var dir := _facing_dir(s.facing)
	var tip := c + dir * hex_size * 0.66
	var a_back1 := deg_to_rad(s.facing * 60.0 + 145.0)
	var a_back2 := deg_to_rad(s.facing * 60.0 - 145.0)
	var b1 := c + hex_size * 0.55 * Vector2(sin(a_back1), -cos(a_back1))
	var b2 := c + hex_size * 0.55 * Vector2(sin(a_back2), -cos(a_back2))
	draw_colored_polygon(PackedVector2Array([tip, b1, b2]), col)
	draw_polyline(PackedVector2Array([tip, b1, b2, tip]), Color(0, 0, 0, 0.6), 1.5)

	# Destroyed: X over the token
	if s.is_destroyed:
		var r := hex_size * 0.6
		draw_line(c + Vector2(-r, -r), c + Vector2(r, r), Color(0.7, 0.1, 0.1), 3.0)
		draw_line(c + Vector2(r, -r), c + Vector2(-r, r), Color(0.7, 0.1, 0.1), 3.0)

	# Name initial
	var initial := s.def.display_name.substr(0, 1)
	draw_string(font, c + Vector2(-4.0, 4.0), initial,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color.WHITE)
