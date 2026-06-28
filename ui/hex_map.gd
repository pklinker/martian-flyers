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
const DEPLOY_ZONE := Color(0.20, 0.45, 0.70, 0.22)   # legal deploy hexes (pre-game)
const DEPLOY_ZONE_EDGE := Color(0.30, 0.55, 0.85, 0.55)
const ACTIVE_RING := Color(0.95, 0.75, 0.15)
const TARGET_RETICLE := Color(0.85, 0.18, 0.15, 0.9)
const SIDE_COLORS: Array[Color] = [Color(0.16, 0.32, 0.62), Color(0.62, 0.16, 0.13)]
const WRECK := Color(0.35, 0.32, 0.30)

## Direction sunlight travels across the screen (down-right). Faces whose outward
## normal opposes this are lit; shadows are cast along it. Fixed in screen space, so
## the lit faces change as the field rotates — which reads as a real sun overhead.
const SUN_SCREEN := Vector2(0.45, 0.55)

const TRACER := Color(0.95, 0.85, 0.45)        # radium shell streak
const TORPEDO_TRACER := Color(0.55, 0.85, 0.95) # cooler, for the AP fish
const FLASH_HIT := Color(0.95, 0.55, 0.15)      # shell strike burst
const FLASH_BOOM := Color(0.95, 0.30, 0.12)     # destruction / magazine blast

var engine: TurnEngine
var highlight_moves: Array[Dictionary] = []
var active_ship: ShipState

## Legal deployment hexes for the pre-game placement phase. A separate channel
## from highlight_moves (which is move-shaped and means "legal moves this
## impulse") so the two never interfere. Drawn as a translucent zone tint.
var deploy_hexes: Array[Vector2i] = []

## Hexes the active ship's chosen guns are currently aimed at (FIRE phase). Pure
## presentation — drawn as target reticles so the player sees who they'll shoot.
var fire_targets: Array[Vector2i] = []

var _origin := Vector2.ZERO

## Camera: a manual pan/zoom view. `_cam_center` is the cartesian (hex-unit)
## point held at the centre of the view; `hex_size` is the zoom. The view used to
## auto-fit every frame, which made fleets jump around on every redraw — now the
## player drives it (drag to pan, wheel/pinch to zoom), with frame_ships() as a
## one-shot "fit everything" used at battle start and the Recenter button.
var _cam_center := Vector2.ZERO
var _needs_initial_frame := true
var _press_pos := Vector2.ZERO
var _panning := false

## View transform: the field can be drawn flat top-down (overhead) or tilted into
## an axonometric "2.5D" isometric view. Every hex/ship/terrain point goes through
## project()/project_local(), which maps a ground-cartesian point plus a height into
## screen space. Overhead = _theta 0, _tilt 1, _height_scale 0 → numerically identical
## to the original flat hex_to_pixel (regression-safe). Isometric tilts the ground
## (foreshortened y) and lifts geometry by its height. These three are tweened on
## _process for a smooth transition; targets are set by set_view_mode/rotate_field.
var _theta := 0.0                     # field rotation (radians), snapped to orientation
var _tilt := 1.0                      # ground-depth foreshortening: 1 overhead → ISO_TILT
var _height_scale := 0.0              # screen lift per unit world-height: 0 overhead → ISO_HEIGHT

## Overhead ⇄ isometric toggle. The transform above is tweened toward these targets
## on _process; OVERHEAD locks back to a flat north-up view, ISOMETRIC tilts the field.
enum ViewMode { OVERHEAD, ISOMETRIC }
signal view_mode_changed(mode: int)

const ISO_TILT := 0.58                # depth foreshortening in isometric
const ISO_HEIGHT := 0.95             # screen lift per world-height unit in isometric
const VIEW_LERP := 7.0                # transition snappiness (higher = faster settle)
const SHIP_ALT := 0.6                 # world-height a living flyer hovers at

var _anim_t := 0.0                     # free-running clock for idle bob / drift (iso only)

## Ambient drifting clouds — pure presentation, no gameplay effect, only shown in iso.
## Lazily seeded across the board; each drifts along +x and wraps. See _ensure_clouds.
const CLOUD_HEIGHT := 3.2
var _clouds: Array[Dictionary] = []

## Authored 3D terrain models (hills/towers). When a matching .glb is present its baked
## sprite replaces the procedural prism; otherwise this is dormant. See terrain_models.gd.
## MODEL_GROUND_ANCHOR is the fraction down the sprite where the hex centre sits (the
## model's base) — tune against a real model once one is dropped in.
const MODEL_GROUND_ANCHOR := 0.62
var _terrain_models: TerrainModels

var view_mode := ViewMode.OVERHEAD
var _orientation := 0                  # snapped field facing 0..5 (isometric only)
var _target_theta := 0.0
var _target_tilt := 1.0
var _target_height := 0.0

const MAX_HEX := 64.0                  # manual zoom-in ceiling
const PAN_THRESHOLD := 6.0             # px of drag before a click becomes a pan
const ROT_DRAG_SPEED := 0.01           # radians of field spin per px of right-drag

var _rotating := false                  # right button held: free-spinning the field

## Transient combat effects: short-lived tracers (firer->target streaks) and
## flashes (bursts at a hex). Pure presentation — they animate on _process and
## fade out, then stop processing. Driven by map_demo from shot_resolved.
## tracer:  { "from": Vector2i, "to": Vector2i, "torpedo": bool, "t": float, "life": float }
## flash:   { "hex": Vector2i, "big": bool, "t": float, "life": float }
var _tracers: Array[Dictionary] = []
var _flashes: Array[Dictionary] = []


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

## Tint the legal deployment hexes (pre-game). Pass an empty array to clear.
func set_deploy_highlights(hexes: Array[Vector2i]) -> void:
	deploy_hexes = hexes
	queue_redraw()

## Mark which ship the per-ship phase bars (allocate/plot/fire) are editing, so
## the player sees the active flyer ringed even when there are no move highlights.
func set_active_ship(s: ShipState) -> void:
	active_ship = s
	queue_redraw()

func set_fire_targets(hexes: Array[Vector2i]) -> void:
	fire_targets = hexes
	queue_redraw()


# ---------------------------------------------------------------------------
# Geometry: pixel <-> hex, matching HexMath.to_cartesian scaled by hex_size.
# ---------------------------------------------------------------------------

## Map a ground-cartesian point (hex units) plus a world-height into the view's
## local pixel offset from _origin. Rotation spins the ground; tilt foreshortens the
## depth axis; height lifts the point up the screen. This is the single seam every
## drawable goes through, so overhead and isometric share one code path.
## Unit-space projection (no zoom, no origin): the linear part of the view transform.
## Camera framing/clamping work here so they're independent of zoom and pan.
func _proj_unit(cart: Vector2, height: float) -> Vector2:
	var r := cart.rotated(_theta)
	return Vector2(r.x, r.y * _tilt - height * _height_scale)

## Inverse of _proj_unit on the ground plane (height 0): un-tilt then un-rotate.
func _unproj_unit(u: Vector2) -> Vector2:
	var unt := Vector2(u.x, u.y / _tilt) if absf(_tilt) > 0.0001 else u
	return unt.rotated(-_theta)

func project_local(cart: Vector2, height: float) -> Vector2:
	return _proj_unit(cart, height) * hex_size

func project(cart: Vector2, height: float) -> Vector2:
	return _origin + project_local(cart, height)

func hex_to_pixel(hex: Vector2i) -> Vector2:
	return project(HexMath.to_cartesian(hex), 0.0)

## Inverse of project() on the ground plane (height 0): the player clicks where a
## token's base sits, so picking always resolves against the floor. Un-applies origin
## and zoom, un-tilts the depth axis, un-rotates, then reuses the axial cube-round.
func pixel_to_hex(p: Vector2) -> Vector2i:
	var local := (p - _origin) / hex_size
	var unt := Vector2(local.x, local.y / _tilt) if absf(_tilt) > 0.0001 else local
	var pt := unt.rotated(-_theta)
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
	resized.connect(_on_resized)
	set_process(false)                    # only tick while effects are alive
	# Offscreen baker for authored 3D terrain models. Adds no 3D nodes and no cost
	# until a model is present in assets/terrain/; otherwise terrain stays prisms.
	_terrain_models = TerrainModels.new()
	add_child(_terrain_models)
	_terrain_models.baked.connect(queue_redraw)


## A larger view can outrun the previous clamp, exposing void at an edge — re-pin
## the camera to the board before redrawing.
func _on_resized() -> void:
	_clamp_camera()
	queue_redraw()


# ---------------------------------------------------------------------------
# Combat effects (transient, presentation-only)
# ---------------------------------------------------------------------------

const TRACER_LIFE := 0.45
const FLASH_LIFE := 0.55

## A shell/torpedo streak from firer to target that fades over TRACER_LIFE.
func add_tracer(from_hex: Vector2i, to_hex: Vector2i, torpedo: bool) -> void:
	_tracers.append({ "from": from_hex, "to": to_hex, "torpedo": torpedo,
			"t": 0.0, "life": TRACER_LIFE })
	set_process(true)
	queue_redraw()

## A burst at a hex — a hit spark, or a bigger blast on destruction.
func add_flash(hex: Vector2i, big: bool) -> void:
	_flashes.append({ "hex": hex, "big": big, "t": 0.0, "life": FLASH_LIFE })
	set_process(true)
	queue_redraw()

func clear_effects() -> void:
	_tracers.clear()
	_flashes.clear()
	set_process(false)

func _process(delta: float) -> void:
	var animating := _step_view(delta)
	_anim_t += delta
	# Isometric is a living scene (hovering flyers, drifting dust/clouds), so keep
	# ticking while it's shown; overhead is static and idles once effects clear.
	var ambient := view_mode == ViewMode.ISOMETRIC
	var alive := false
	for fx in _tracers:
		fx["t"] += delta
		if fx["t"] < fx["life"]:
			alive = true
	for fx in _flashes:
		fx["t"] += delta
		if fx["t"] < fx["life"]:
			alive = true
	_tracers = _tracers.filter(func(f: Dictionary) -> bool: return f["t"] < f["life"])
	_flashes = _flashes.filter(func(f: Dictionary) -> bool: return f["t"] < f["life"])
	if not alive and not animating and not ambient:
		set_process(false)
	queue_redraw()


## Fit every live ship into view at once: set the zoom to hold them all with a
## margin and centre on their midpoint. A one-shot (battle start, Recenter), NOT
## per-frame — so panning/zooming sticks and ship-selection never yanks the view.
func frame_ships() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		_needs_initial_frame = true   # no layout yet; do it on the first real draw
		return
	# Work in unit-projected space so the fit is correct at any tilt/rotation: the
	# foreshortened, rotated footprint is what actually has to fit the viewport.
	var lo := Vector2(INF, INF)
	var hi := -lo
	var n := 0
	if engine != null:
		for s in engine.ships:
			if s.is_destroyed:
				continue
			var u := _proj_unit(HexMath.to_cartesian(s.hex), 0.0)
			lo = lo.min(u)
			hi = hi.max(u)
			n += 1
	if n == 0:
		lo = Vector2.ZERO
		hi = Vector2.ZERO
	var w_units := (hi.x - lo.x) + 2.0 * (HALF_W + SHIP_MARGIN)
	var h_units := (hi.y - lo.y) + 2.0 * (HALF_H + SHIP_MARGIN)
	hex_size = clampf(minf(size.x / w_units, size.y / h_units), MIN_HEX, DEFAULT_HEX)
	_cam_center = _unproj_unit((lo + hi) * 0.5)
	_needs_initial_frame = false
	_clamp_camera()
	queue_redraw()

## Hold `hex` at the centre of the view (used to follow the active mover).
func center_on(hex: Vector2i) -> void:
	_cam_center = HexMath.to_cartesian(hex)
	_clamp_camera()
	queue_redraw()

## Pan by a pixel delta (drag / two-finger scroll): move the world under the view.
## The drag happens in screen space, so step the camera in unit-projected space and
## map back to a cartesian centre — a straight cartesian shift would skew under tilt.
func pan(delta_px: Vector2) -> void:
	var uc := _proj_unit(_cam_center, 0.0) - delta_px / hex_size
	_cam_center = _unproj_unit(uc)
	_clamp_camera()
	queue_redraw()

## Zoom about the view centre by a multiplicative factor (wheel / pinch).
func zoom_by(factor: float) -> void:
	hex_size = clampf(hex_size * factor, MIN_HEX, MAX_HEX)
	_clamp_camera()
	queue_redraw()


# ---------------------------------------------------------------------------
# View mode (overhead ⇄ isometric) and field rotation
# ---------------------------------------------------------------------------

## Switch between the flat top-down view and the tilted isometric view. The actual
## transform animates toward the new targets on _process, so the swap reads as the
## camera tilting down (or lifting back up) rather than a jump.
func set_view_mode(mode: int) -> void:
	if mode == view_mode:
		return
	view_mode = mode
	if view_mode == ViewMode.ISOMETRIC:
		_target_tilt = ISO_TILT
		_target_height = ISO_HEIGHT
	else:
		# Overhead is flat (no tilt/height) but keeps its rotation — orientation
		# persists across a view toggle so the field doesn't snap back to north-up.
		_target_tilt = 1.0
		_target_height = 0.0
	_target_theta = _orientation * (TAU / 6.0)
	set_process(true)
	view_mode_changed.emit(view_mode)

func toggle_view() -> void:
	set_view_mode(ViewMode.OVERHEAD if view_mode == ViewMode.ISOMETRIC else ViewMode.ISOMETRIC)

## Snap the field by one hex-facing step (±1 of 6). Works in both views; the transform
## tweens to the new angle on _process.
func rotate_field(step: int) -> void:
	_orientation = posmod(_orientation + step, 6)
	_target_theta = _orientation * (TAU / 6.0)
	set_process(true)

## Free-spin the field by a right-drag's horizontal delta. Drives _theta directly and
## pins the tween target to it so the in-flight settle doesn't fight the drag; the
## actual snap-to-orientation happens on release via _snap_orientation().
func rotate_drag(dx: float) -> void:
	_theta += dx * ROT_DRAG_SPEED
	_target_theta = _theta
	_clamp_camera()
	queue_redraw()

## Settle a free rotation onto the nearest of the six hex orientations, animated.
func _snap_orientation() -> void:
	var step := TAU / 6.0
	_theta = wrapf(_theta, 0.0, TAU)
	_orientation = posmod(int(round(_theta / step)), 6)
	_target_theta = _orientation * step
	set_process(true)

## Step the view transform toward its targets. Returns true while still moving, so
## _process keeps ticking through the transition (and any field-rotation snap).
func _step_view(delta: float) -> bool:
	var k := minf(delta * VIEW_LERP, 1.0)
	var moving := false
	if absf(_tilt - _target_tilt) > 0.0005:
		_tilt = lerpf(_tilt, _target_tilt, k); moving = true
	else:
		_tilt = _target_tilt
	if absf(_height_scale - _target_height) > 0.0005:
		_height_scale = lerpf(_height_scale, _target_height, k); moving = true
	else:
		_height_scale = _target_height
	var dth := wrapf(_target_theta - _theta, -PI, PI)
	if absf(dth) > 0.0008:
		_theta += dth * k; moving = true
	else:
		_theta = _target_theta
	if moving:
		_clamp_camera()
	return moving

## Keep the view over the playfield: the field never scrolls off into the empty
## sea-bottom void. The camera centre is held so the view stays inside the board's
## cartesian bounds (plus a one-hex margin); on any axis where the board is
## smaller than the view, the board is centred instead.
func _clamp_camera() -> void:
	if size.x <= 0.0 or size.y <= 0.0 or hex_size <= 0.0:
		return
	# Clamp in unit-projected space, where the viewport is an axis-aligned rectangle
	# regardless of tilt/rotation. Convert the camera centre in, clamp, convert back.
	var b := _board_bounds_unit()
	var lo := b.position - Vector2(HALF_W, HALF_H)
	var hi := b.end + Vector2(HALF_W, HALF_H)
	var half := size * 0.5 / hex_size
	var uc := _proj_unit(_cam_center, 0.0)
	for axis in 2:
		if hi[axis] - lo[axis] <= 2.0 * half[axis]:
			uc[axis] = (lo[axis] + hi[axis]) * 0.5
		else:
			uc[axis] = clampf(uc[axis], lo[axis] + half[axis], hi[axis] - half[axis])
	_cam_center = _unproj_unit(uc)

## Unit-projected bounding box of the whole playfield. The board is a sheared
## rectangle in axial space; under rotation the screen-space extremes are among its
## corner hexes, so project those (corner columns × top/bottom rows) and bound them.
func _board_bounds_unit() -> Rect2:
	var lo := Vector2(INF, INF)
	var hi := -lo
	for q in [0, 1, cols - 2, cols - 1]:
		if q < 0 or q >= cols:
			continue
		var off := row_offset(q)
		for r in [off, off + rows - 1]:
			var u := _proj_unit(HexMath.to_cartesian(Vector2i(q, r)), 0.0)
			lo = lo.min(u)
			hi = hi.max(u)
	return Rect2(lo, hi - lo)

## Cartesian bounding box of the whole playfield (rotation-independent). Used to
## seed and wrap the ambient cloud field, which lives in ground-cartesian space.
func _board_bounds() -> Rect2:
	var lo := Vector2(INF, INF)
	var hi := -lo
	for q in [0, 1, cols - 2, cols - 1]:
		if q < 0 or q >= cols:
			continue
		var off := row_offset(q)
		for r in [off, off + rows - 1]:
			var c := HexMath.to_cartesian(Vector2i(q, r))
			lo = lo.min(c)
			hi = hi.max(c)
	return Rect2(lo, hi - lo)


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				if event.pressed:
					_press_pos = event.position
					_panning = false
				elif not _panning:
					_click(event.position)   # a click, not a drag-pan
			MOUSE_BUTTON_RIGHT:
				# Hold the right button and drag to spin the field (either view); settle
				# to the nearest hex orientation on release.
				if event.pressed:
					_rotating = true
				elif _rotating:
					_rotating = false
					_snap_orientation()
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					zoom_by(1.1)
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					zoom_by(1.0 / 1.1)
	elif event is InputEventMouseMotion:
		# Right-drag spins the field (either view); left-drag pans past the threshold.
		if _rotating and (event.button_mask & MOUSE_BUTTON_MASK_RIGHT):
			rotate_drag(event.relative.x)
		elif event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			if not _panning and event.position.distance_to(_press_pos) > PAN_THRESHOLD:
				_panning = true
			if _panning:
				pan(event.relative)
	elif event is InputEventPanGesture:
		pan(-event.delta * 24.0)             # trackpad two-finger scroll
	elif event is InputEventMagnifyGesture:
		zoom_by(event.factor)                # trackpad pinch


## Resolve a left-click (no pan): a legal-move hex, then any hex.
func _click(pos: Vector2) -> void:
	map_pressed.emit()
	var hex := pixel_to_hex(pos)
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

## The six corners of a hex, projected on the ground plane (or lifted to `height`).
## Each vertex goes through project() so cells foreshorten and rotate with the field;
## in overhead this collapses to a plain flat hexagon at the cell's pixel centre.
func _hex_corners(hex: Vector2i, height := 0.0) -> PackedVector2Array:
	var base := HexMath.to_cartesian(hex)
	var pts := PackedVector2Array()
	for i in 6:
		var a := deg_to_rad(60.0 * i)
		pts.append(project(base + Vector2(cos(a), sin(a)), height))
	return pts

## Painter's-algorithm depth key for a ground point: how far "back" it sits along
## the (rotated, foreshortened) view depth axis. Smaller = farther, drawn first.
func _depth_of(cart: Vector2) -> float:
	return cart.rotated(_theta).y

static func _facing_dir(facing: int) -> Vector2:
	var a := deg_to_rad(facing * 60.0)
	return Vector2(sin(a), -cos(a))

func _draw() -> void:
	if _needs_initial_frame:
		frame_ships()                       # first draw after layout: fit the fleets
	# Solve _origin so the camera-centre ground point lands at the view centre under
	# the current projection (identical to the old flat formula when overhead).
	_origin = size * 0.5 - project_local(_cam_center, 0.0)
	draw_rect(Rect2(Vector2.ZERO, size), SEA_BOTTOM, true)
	var font := get_theme_default_font()
	var iso_k := clampf(_height_scale / ISO_HEIGHT, 0.0, 1.0)   # 0 overhead → 1 full iso
	_ensure_clouds()

	# Grid — only the cells the camera currently shows (the field is large).
	var cull := hex_size * 1.5
	for q in cols:
		var off := row_offset(q)
		for r in range(off, off + rows):
			var c := hex_to_pixel(Vector2i(q, r))
			if c.x < -cull or c.x > size.x + cull or c.y < -cull or c.y > size.y + cull:
				continue
			var pts := _hex_corners(Vector2i(q, r))
			draw_polyline(pts + PackedVector2Array([pts[0]]), GRID, 1.0)

	# Flat terrain ground (dust tint + a footprint for hills/towers). The raised
	# 3D massing of hills/towers is drawn later in the depth-sorted object pass; this
	# is just the tile they stand on, so it reads correctly in overhead too.
	if engine != null:
		for hex: Vector2i in engine.terrain:
			var c := hex_to_pixel(hex)
			if c.x < -cull or c.x > size.x + cull or c.y < -cull or c.y > size.y + cull:
				continue
			var t: int = engine.terrain[hex]
			var col := TerrainDef.render_color(t)
			var pts := _hex_corners(hex)
			draw_colored_polygon(pts, col)
			# Heavier border on LOS-blocking terrain so captains can spot it.
			var edge_col := col.darkened(0.35)
			var edge_w := 2.5 if TerrainDef.blocks_los(t) else 1.0
			draw_polyline(pts + PackedVector2Array([pts[0]]), edge_col, edge_w)
			# Single-letter label: H = Hill, T = Tower, D = Dust.
			draw_string(font, c + Vector2(-4.0, 5.0),
					TerrainDef.display_name(t).substr(0, 1),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
					Color(0.12, 0.08, 0.03, 0.90))

	# Cloud shadows scud across the ground (iso only), beneath everything that stands on it.
	_draw_cloud_shadows(iso_k)

	# Deployment-zone tint (pre-game placement): legal deploy hexes, beneath the
	# legal-move highlights and ships.
	for hex in deploy_hexes:
		var c := hex_to_pixel(hex)
		if c.x < -cull or c.x > size.x + cull or c.y < -cull or c.y > size.y + cull:
			continue
		var pts := _hex_corners(hex)
		draw_colored_polygon(pts, DEPLOY_ZONE)
		draw_polyline(pts + PackedVector2Array([pts[0]]), DEPLOY_ZONE_EDGE, 1.0)

	# Legal-move highlights
	for m in highlight_moves:
		var hx: Vector2i = m["hex"]
		var c := hex_to_pixel(hx)
		var pts := _hex_corners(hx)
		draw_colored_polygon(pts, HIGHLIGHT)
		draw_polyline(pts + PackedVector2Array([pts[0]]), HIGHLIGHT_EDGE, 2.0)
		# Small tick showing the facing the ship will have after this move, drawn in
		# the projected ground direction so it points correctly when the field rotates.
		var base := HexMath.to_cartesian(hx)
		var tip := project(base + _facing_dir(m["facing"]) * 0.55, 0.0)
		draw_line(c, tip, HIGHLIGHT_EDGE, 2.0)

	if engine == null:
		return

	# Depth-sorted 3D pass: extruded terrain massing (hills/towers) and hovering ships
	# share one back-to-front ordering so a flyer behind a mountain is occluded by it.
	# Dust is atmosphere, painted later. Ships get a hair more depth so one sitting on a
	# hill draws on top of it rather than inside it.
	var objs: Array[Dictionary] = []
	# Terrain massing is the flat tile (drawn above) until the field tilts; only then
	# does it rise into prisms/dust columns. Keeps overhead identical to the old map.
	if iso_k > 0.02:
		for hex: Vector2i in engine.terrain:
			var t: int = engine.terrain[hex]
			var kind := "dust" if t == TerrainDef.Type.DUST_STORM else "terrain"
			objs.append({"depth": _depth_of(HexMath.to_cartesian(hex)), "kind": kind,
					"hex": hex, "type": t})
	for s in engine.ships:
		objs.append({"depth": _depth_of(HexMath.to_cartesian(s.hex)) + 0.01,
				"kind": "ship", "ship": s})
	objs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["depth"] < b["depth"])
	for o in objs:
		match o["kind"]:
			"terrain": _draw_terrain_model(font, o["hex"], o["type"])
			"dust": _draw_dust(o["hex"])
			"ship": _draw_ship(font, o["ship"])

	# Fire-target reticles: a red ring + crosshair over each enemy the active
	# ship's chosen guns are aimed at this FIRE phase.
	for hex in fire_targets:
		var c := hex_to_pixel(hex)
		var rad := hex_size * 0.78
		draw_arc(c, rad, 0.0, TAU, 24, TARGET_RETICLE, 2.0)
		draw_line(c + Vector2(-rad, 0), c + Vector2(-rad * 0.4, 0), TARGET_RETICLE, 2.0)
		draw_line(c + Vector2(rad, 0), c + Vector2(rad * 0.4, 0), TARGET_RETICLE, 2.0)
		draw_line(c + Vector2(0, -rad), c + Vector2(0, -rad * 0.4), TARGET_RETICLE, 2.0)
		draw_line(c + Vector2(0, rad), c + Vector2(0, rad * 0.4), TARGET_RETICLE, 2.0)

	# Combat effects, on top of everything (streaks and bursts in the air).
	_draw_effects()

	# Drifting clouds are the highest layer — the open sky over the battle.
	_draw_clouds(iso_k)


## Tracers as fading lines (a small leading bolt at the head); flashes as
## expanding, fading rings with a filled core. All eased on their normalized
## lifetime so they read as quick muzzle work, not lingering decals.
func _draw_effects() -> void:
	for fx in _tracers:
		var k: float = clampf(fx["t"] / fx["life"], 0.0, 1.0)
		var a := hex_to_pixel(fx["from"])
		var b := hex_to_pixel(fx["to"])
		var col: Color = TORPEDO_TRACER if fx["torpedo"] else TRACER
		col.a = 1.0 - k
		var w: float = (3.0 if fx["torpedo"] else 2.0) * hex_size / DEFAULT_HEX
		draw_line(a, b, col, maxf(w, 1.0))
		# A bright bolt travelling along the streak for the first half of its life.
		var head := a.lerp(b, minf(k * 2.0, 1.0))
		draw_circle(head, maxf(w * 1.4, 2.0), Color(1, 1, 1, (1.0 - k) * 0.9))
	for fx in _flashes:
		var k: float = clampf(fx["t"] / fx["life"], 0.0, 1.0)
		var c := hex_to_pixel(fx["hex"])
		var base: float = (0.95 if fx["big"] else 0.55) * hex_size
		var col: Color = FLASH_BOOM if fx["big"] else FLASH_HIT
		# Expanding ring.
		var ring := col
		ring.a = (1.0 - k) * 0.9
		draw_arc(c, base * (0.3 + k * 0.9), 0.0, TAU, 28, ring, maxf(3.0 * hex_size / DEFAULT_HEX, 1.5))
		# Bright core that shrinks as the ring grows.
		var core := col
		core.a = (1.0 - k)
		draw_circle(c, base * 0.4 * (1.0 - k), core)


func _draw_ship(font: Font, s: ShipState) -> void:
	var cart := HexMath.to_cartesian(s.hex)
	var col: Color = WRECK if (s.is_destroyed or s.grounded) else SIDE_COLORS[s.side]

	# Flyers hover; wrecks and grounded hulls have settled onto the sea bottom. A slow
	# idle bob (only visible in iso, where height_scale > 0) keeps the living fleet alive.
	var down: bool = s.is_destroyed or s.grounded
	var bob := sin(_anim_t * 1.6 + float(s.hex.x * 7 + s.hex.y * 13)) * 0.06
	var alt := 0.0 if down else (SHIP_ALT + bob)

	var g := project(cart, 0.0)              # ground point (shadow + altitude post)
	var c := project(cart, alt)              # the hull itself

	# Ground shadow — fades in with the tilt so overhead stays a clean flat token.
	var sh_a := 0.30 * clampf(_height_scale / ISO_HEIGHT, 0.0, 1.0)
	if sh_a > 0.01:
		draw_colored_polygon(_ground_ellipse(cart, 0.5), Color(0.08, 0.06, 0.04, sh_a))
		draw_line(g, c, Color(0.08, 0.06, 0.04, sh_a * 0.8), 1.5)  # altitude post

	# Active-ship ring (around the hull at altitude)
	if s == active_ship:
		draw_arc(c, hex_size * 0.92, 0.0, TAU, 32, ACTIVE_RING, 3.0)

	# Hull: a triangle pointing along facing, its corners projected on the ground at
	# altitude so it foreshortens and turns with the field. A darker keel a touch lower
	# gives the token a hint of thickness in iso.
	var tip_c := cart + _facing_dir(s.facing) * 0.66
	var b1_c := cart + 0.55 * _facing_dir_deg(s.facing * 60.0 + 145.0)
	var b2_c := cart + 0.55 * _facing_dir_deg(s.facing * 60.0 - 145.0)
	if not down and _height_scale > 0.01:
		var keel := PackedVector2Array([project(tip_c, alt - 0.12),
				project(b1_c, alt - 0.12), project(b2_c, alt - 0.12)])
		draw_colored_polygon(keel, col.darkened(0.45))
	var tip := project(tip_c, alt)
	var b1 := project(b1_c, alt)
	var b2 := project(b2_c, alt)
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


## A flat ellipse on the ground plane around a cartesian point, radius in hex units,
## used for soft shadows. Projected so it foreshortens with the tilt.
func _ground_ellipse(cart: Vector2, radius: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 16:
		var a := deg_to_rad(22.5 * i)
		pts.append(project(cart + Vector2(cos(a), sin(a)) * radius, 0.0))
	return pts

## Cartesian unit direction for an absolute screen-angle in degrees (0 = north,
## clockwise), matching _facing_dir's convention but for arbitrary angles.
static func _facing_dir_deg(deg: float) -> Vector2:
	var a := deg_to_rad(deg)
	return Vector2(sin(a), -cos(a))


## Footprint radius (hex units) of a terrain prism: hills fill the hex, towers are a
## narrow column standing on the tile.
func _terrain_radius(t: int) -> float:
	return 0.42 if t == TerrainDef.Type.TOWER else 1.0


## Deterministic model variant for a hex, so a given hill always looks the same.
func _terrain_variant(hex: Vector2i, t: int) -> int:
	var n := _terrain_models.variant_count(t)
	return posmod(hex.x * 7 + hex.y * 13, n) if n > 0 else 0

## Draw a terrain feature using its authored 3D model when one exists, else the prism.
## The baked sprite is blitted at the hex with a soft ground shadow; if the needed angle
## isn't baked yet we request it and draw the prism this frame (it pops in on `baked`).
func _draw_terrain_model(font: Font, hex: Vector2i, t: int) -> void:
	if _terrain_models == null or not _terrain_models.has_model(t):
		_draw_terrain_prism(font, hex, t)
		return
	var view := TerrainModels.View.ISO if _height_scale > 0.02 else TerrainModels.View.TOPDOWN
	var variant := _terrain_variant(hex, t)
	var bucket := _terrain_models.angle_bucket(_theta)
	var tex := _terrain_models.get_texture(t, variant, bucket, view)
	if tex == null:
		_terrain_models.request(t, variant, bucket, view)
		_draw_terrain_prism(font, hex, t)            # fallback until the bake lands
		return

	var base := HexMath.to_cartesian(hex)
	var ground := project(base, 0.0)
	# Soft ground shadow, offset along the sun and fading in with the tilt (as the prism).
	var sh_k := clampf(_height_scale / ISO_HEIGHT, 0.0, 1.0)
	if sh_k > 0.01:
		var shoff := SUN_SCREEN * TerrainDef.render_height(t) * hex_size * 0.5
		var shp := PackedVector2Array()
		for i in 6:
			var a := deg_to_rad(60.0 * i)
			shp.append(project(base + Vector2(cos(a), sin(a)) * _terrain_radius(t), 0.0) + shoff)
		draw_colored_polygon(shp, Color(0.05, 0.04, 0.03, 0.20 * sh_k))
	# The sprite spans MODEL_FRAME_UNITS hex-units; on the map a hex-unit is hex_size px.
	var w := TerrainModels.MODEL_FRAME_UNITS * hex_size
	var rect := Rect2(ground - Vector2(w * 0.5, w * MODEL_GROUND_ANCHOR), Vector2(w, w))
	draw_texture_rect(tex, rect, false)


## Draw a terrain feature as an extruded prism: a cast ground shadow, the visible side
## walls shaded by their orientation to the sun (sorted back-to-front), then the lit top
## face. Reads as flat in overhead (height_scale 0 collapses the walls to nothing).
func _draw_terrain_prism(font: Font, hex: Vector2i, t: int) -> void:
	var base := HexMath.to_cartesian(hex)
	var height := TerrainDef.render_height(t)
	var rad := _terrain_radius(t)
	var col := TerrainDef.render_color(t)
	col.a = 1.0

	# Corner offsets (cartesian), and their projected ground / top rings.
	var coff: Array[Vector2] = []
	var ground := PackedVector2Array()
	var top := PackedVector2Array()
	for i in 6:
		var a := deg_to_rad(60.0 * i)
		var off := Vector2(cos(a), sin(a)) * rad
		coff.append(off)
		ground.append(project(base + off, 0.0))
		top.append(project(base + off, height))

	# Soft cast shadow on the ground, offset along the sun and fading in with the tilt.
	var sh_k := clampf(_height_scale / ISO_HEIGHT, 0.0, 1.0)
	if sh_k > 0.01:
		var shoff := SUN_SCREEN * height * hex_size * 0.5
		var shp := PackedVector2Array()
		for i in 6:
			shp.append(ground[i] + shoff)
		draw_colored_polygon(shp, Color(0.05, 0.04, 0.03, 0.20 * sh_k))

	# Side walls, each shaded by its outward normal vs the sun, painted far-to-near.
	var faces: Array[Dictionary] = []
	for i in 6:
		var j := (i + 1) % 6
		var mid := (coff[i] + coff[j]) * 0.5
		var nrm := mid.normalized().rotated(_theta)
		var lit := maxf(0.0, -nrm.dot(SUN_SCREEN.normalized()))
		var shade := col.darkened(0.42).lerp(col.lightened(0.10), lit)
		faces.append({"d": _depth_of(base + mid),
				"poly": PackedVector2Array([ground[i], ground[j], top[j], top[i]]),
				"c": shade})
	faces.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["d"] < b["d"])
	for f in faces:
		var poly: PackedVector2Array = f["poly"]
		draw_colored_polygon(poly, f["c"])
		draw_polyline(poly + PackedVector2Array([poly[0]]), col.darkened(0.55), 1.0)

	# Lit top face (sunlit from above), with its outline and the type letter.
	draw_colored_polygon(top, col.lightened(0.20))
	draw_polyline(top + PackedVector2Array([top[0]]), col.darkened(0.40), 1.5)
	var ctop := project(base, height)
	draw_string(font, ctop + Vector2(-4.0, 4.0), TerrainDef.display_name(t).substr(0, 1),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.12, 0.08, 0.03, 0.95))


## A dust storm as a billowing column of drifting translucent puffs rising off its
## tile (the flat ochre tint is already laid down in the ground pass). The puffs only
## swell in iso — overhead keeps the clean flat haze. Animated on _anim_t.
func _draw_dust(hex: Vector2i) -> void:
	var k := clampf(_height_scale / ISO_HEIGHT, 0.0, 1.0)
	if k < 0.01:
		return
	var base := HexMath.to_cartesian(hex)
	var seed := float(hex.x * 3 + hex.y * 5)
	var puffs := 5
	for i in puffs:
		var ph := float(i) * 1.7 + seed
		var drift := Vector2(sin(_anim_t * 0.5 + ph) * 0.28, cos(_anim_t * 0.4 + ph) * 0.18)
		var h := lerpf(0.1, 1.1, float(i) / float(puffs - 1)) * (0.35 + 0.75 * k)
		var p := project(base + drift, h)
		var rad := hex_size * (0.6 - 0.06 * i) * (0.55 + 0.45 * k)
		var a := 0.22 * (1.0 - 0.1 * i) * k
		draw_circle(p, maxf(rad, 2.0), Color(0.88, 0.74, 0.34, a))


## Seed the ambient cloud field once the board size is known. Deterministic so clouds
## don't reshuffle between redraws; positions span the board's cartesian bounds.
func _ensure_clouds() -> void:
	if not _clouds.is_empty() or engine == null:
		return
	var b := _board_bounds()
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337
	for _i in 7:
		_clouds.append({
			"x": rng.randf_range(b.position.x, b.end.x),
			"y": rng.randf_range(b.position.y, b.end.y),
			"r": rng.randf_range(1.3, 2.6),
			"spd": rng.randf_range(0.12, 0.32),
			"ph": rng.randf_range(0.0, TAU),
		})

## Soft cloud shadows scudding across the ground, offset along the sun. Iso only.
func _draw_cloud_shadows(k: float) -> void:
	if k < 0.02 or engine == null:
		return
	var b := _board_bounds()
	var shoff := SUN_SCREEN * CLOUD_HEIGHT * hex_size * 0.5
	for c in _clouds:
		var cx := wrapf(c["x"] + _anim_t * c["spd"], b.position.x - 3.0, b.end.x + 3.0)
		var g := project(Vector2(cx, c["y"]), 0.0) + shoff
		draw_circle(g, hex_size * c["r"] * 0.62, Color(0.10, 0.08, 0.05, 0.07 * k))

## Drifting cloud billows high above the field — a cluster of soft white puffs per
## cloud. Drawn last (sky layer), above ships and terrain. Iso only.
func _draw_clouds(k: float) -> void:
	if k < 0.02 or engine == null:
		return
	var b := _board_bounds()
	for c in _clouds:
		var cx := wrapf(c["x"] + _anim_t * c["spd"], b.position.x - 3.0, b.end.x + 3.0)
		var cart := Vector2(cx, c["y"])
		var r: float = c["r"]
		var ph: float = c["ph"]
		var puffs := 5
		for j in puffs:
			var pa := float(j) / float(puffs) * TAU + ph
			var off := Vector2(cos(pa), sin(pa) * 0.5) * r * 0.5
			draw_circle(project(cart + off, CLOUD_HEIGHT), hex_size * r * 0.42,
					Color(0.97, 0.96, 0.92, 0.15 * k))
		draw_circle(project(cart, CLOUD_HEIGHT), hex_size * r * 0.5,
				Color(0.99, 0.98, 0.95, 0.17 * k))
