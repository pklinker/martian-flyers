class_name ModelBaker
extends Node
## Offscreen 3D-model baker for the isometric map. Authored glTF models — terrain
## (assets/terrain/) and ships (assets/ships/) — are rendered through an orthographic
## Camera3D in a private SubViewport and captured to sprites, one per ~15° of view
## azimuth. HexMapView blits the nearest-angle sprite in its depth-sorted pass; when no
## model exists for a key it keeps drawing the procedural primitive (prism / token).
##
## Pure presentation, fully optional, and adds no 3D nodes or cost until a model is
## actually present. Baking can't happen inside _draw() (it needs a rendered frame), so
## the rig bakes asynchronously: callers request (key, variant, bucket, view), draw the
## primitive meanwhile, and redraw when `baked` fires with the sprite ready.

signal baked   # a new sprite landed in the cache; listeners should queue_redraw

const SHIP_DIR := "res://assets/ships/"
const BAKE_SIZE := 192                  # px square of each baked sprite
const AZIMUTH_BUCKETS := 24             # rotation snap for the cache (15° each)
const ISO_ELEVATION_DEG := 35.0         # camera tilt matching hex_map ISO_TILT (~0.58)
const TOPDOWN_ELEVATION_DEG := 89.0     # near-straight-down for the flat view

enum View { TOPDOWN, ISO }

## key (StringName — a terrain-kind id or a ship-model name) -> Array[PackedScene] variants.
var _models: Dictionary = {}
## key -> { frame: float (camera world-units to fit the model),
##          span: float (on-screen size in hex-units),
##          look_y: float (height the camera aims at) }.
var _cfg: Dictionary = {}
var _cache: Dictionary = {}              # key string -> ImageTexture
var _pending: Array[Dictionary] = []     # bake jobs, processed one per frame
var _baking := false

# Lazily-built 3D rig (only created once something actually needs baking).
var _viewport: SubViewport
var _camera: Camera3D
var _pivot: Node3D
var _mounted := ""                       # which (key,variant) is in the pivot now


func _ready() -> void:
	scan_assets()
	set_process(false)


# ---------------------------------------------------------------------------
# Asset discovery (tree-free — safe to call from a unit test)
# ---------------------------------------------------------------------------

func scan_assets() -> void:
	_models.clear()
	_cfg.clear()
	# Terrain / building kinds come from the catalog: each kind with a render.model
	# block registers a bake entry keyed by its id, resolving assets against the
	# kind's source_root (res:// for core, user://mods/<pack>/ for a mod — §0.3).
	# Authoring units are hex-relative (ART_PLAN §4b): frame ≈ model extent, span ≈
	# hexes covered, look_y ≈ mid-height, anchor ≈ fraction down the sprite where the
	# hex centre sits. (Runtime glb loading from user:// mod packs is T5; core kinds
	# resolve to res:// and load via the editor-baked path today.)
	for kid in MapLibrary.kind_ids():
		var k := MapLibrary.kind(kid)
		if not k.has_model():
			continue
		var mdl: Dictionary = k.render["model"]
		var dir := k.source_root.path_join("assets").path_join(String(mdl["dir"])) + "/"
		_register(kid, dir, String(mdl["prefix"]),
				float(mdl["frame"]), float(mdl["span"]), float(mdl["look_y"]), float(mdl["anchor"]))
	# Ships: AI-authored without a strict scale spec, so frame is tuned by eye to fill
	# the bake; span keeps every class a readable size; anchor centres the hovering hull.
	_register(&"scout", SHIP_DIR, "scout", 2.0, 1.7, 0.2, 0.5)
	_register(&"cruiser", SHIP_DIR, "cruiser", 2.4, 2.1, 0.25, 0.5)
	_register(&"fighter", SHIP_DIR, "fighter", 1.6, 1.4, 0.15, 0.5)

func _register(key: Variant, dir: String, prefix: String, frame: float, span: float, look_y: float, anchor: float) -> void:
	var variants: Array[PackedScene] = []
	for i in range(1, 6):
		var path := "%s%s_%d.glb" % [dir, prefix, i]
		if ResourceLoader.exists(path):
			var res := load(path)
			if res is PackedScene:
				variants.append(res)
	if variants.is_empty():
		return
	_models[key] = variants
	_cfg[key] = {"frame": frame, "span": span, "look_y": look_y, "anchor": anchor}

func has_model(key: Variant) -> bool:
	return _models.has(key) and not (_models[key] as Array).is_empty()

func variant_count(key: Variant) -> int:
	return (_models[key] as Array).size() if has_model(key) else 0

## On-screen size in hex-units for this model's sprite (drives draw scaling).
func span(key: Variant) -> float:
	return _cfg[key]["span"] if _cfg.has(key) else 2.0

## Fraction down the sprite where the anchor point (hex centre / model base) sits.
func anchor(key: Variant) -> float:
	return _cfg[key]["anchor"] if _cfg.has(key) else 0.6


# ---------------------------------------------------------------------------
# Angle bucketing (pure)
# ---------------------------------------------------------------------------

## Snap a view azimuth (radians) to the nearest of AZIMUTH_BUCKETS cache slots.
func angle_bucket(theta: float) -> int:
	var step := TAU / float(AZIMUTH_BUCKETS)
	return posmod(int(round(theta / step)), AZIMUTH_BUCKETS)

func bucket_theta(bucket: int) -> float:
	return float(bucket) * (TAU / float(AZIMUTH_BUCKETS))


# ---------------------------------------------------------------------------
# Cache access + background baking
# ---------------------------------------------------------------------------

func _key(key: Variant, variant: int, bucket: int, view: int) -> String:
	return "%s:%d:%d:%d" % [str(key), variant, bucket, view]

func get_texture(key: Variant, variant: int, bucket: int, view: int) -> Texture2D:
	return _cache.get(_key(key, variant, bucket, view), null)

## Best sprite available right now: the exact bucket if cached, otherwise the nearest
## already-baked azimuth (searching outward both ways). Lets the map keep a model on
## screen — just a few degrees off — while a freshly-rotated bucket bakes, instead of
## flickering back to the procedural primitive each time rotation crosses a bucket edge.
## Returns null only when nothing for this key/variant/view is cached yet.
func nearest_texture(key: Variant, variant: int, bucket: int, view: int) -> Texture2D:
	var exact := get_texture(key, variant, bucket, view)
	if exact != null:
		return exact
	for d in range(1, AZIMUTH_BUCKETS / 2 + 1):
		var hi := get_texture(key, variant, posmod(bucket + d, AZIMUTH_BUCKETS), view)
		if hi != null:
			return hi
		var lo := get_texture(key, variant, posmod(bucket - d, AZIMUTH_BUCKETS), view)
		if lo != null:
			return lo
	return null

## Ask for a sprite to be baked (no-op if cached/queued). Triggers lazy rig setup.
func request(key: Variant, variant: int, bucket: int, view: int) -> void:
	if not has_model(key):
		return
	var k := _key(key, variant, bucket, view)
	if _cache.has(k):
		return
	for p in _pending:
		if p["k"] == k:
			return
	_pending.append({"k": k, "key": key, "variant": variant, "bucket": bucket, "view": view})
	set_process(true)

func _process(_delta: float) -> void:
	if _baking or _pending.is_empty():
		if _pending.is_empty():
			set_process(false)
		return
	_baking = true
	var job: Dictionary = _pending.pop_front()
	await _bake(job)
	_baking = false
	baked.emit()

func _bake(job: Dictionary) -> void:
	_ensure_rig()
	_mount(job["key"], job["variant"])
	_set_camera(job["view"], job["key"])
	# Negated: a +Y pivot turn reads counter-clockwise through the bake camera, but the
	# 2D map rotates clockwise for +theta (project()'s cart.rotated). Without this the
	# baked hull/terrain spins mirror-handed and a ship's heading drifts off the world
	# as the camera turns. facing 0 / theta 0 is unchanged (−0 == 0).
	_pivot.rotation = Vector3(0.0, -bucket_theta(job["bucket"]), 0.0)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await get_tree().process_frame
	await get_tree().process_frame
	var img := _viewport.get_texture().get_image()
	if img != null and _image_has_content(img):
		_cache[job["k"]] = ImageTexture.create_from_image(img)


# ---------------------------------------------------------------------------
# The 3D rig (built lazily on first bake)
# ---------------------------------------------------------------------------

func _ensure_rig() -> void:
	if _viewport != null:
		return
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(BAKE_SIZE, BAKE_SIZE)
	_viewport.transparent_bg = true
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)

	_pivot = Node3D.new()
	_viewport.add_child(_pivot)

	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.near = 0.05
	_camera.far = 100.0
	_viewport.add_child(_camera)

	# Key light roughly matching the map's SUN_SCREEN (down-right) + ambient fill so the
	# shadowed faces don't go black and the bake agrees with the hand-drawn shading.
	var light := DirectionalLight3D.new()
	light.rotation = Vector3(deg_to_rad(-50.0), deg_to_rad(-35.0), 0.0)
	light.light_energy = 1.1
	_viewport.add_child(light)

	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.82, 0.80, 0.74)
	env.ambient_light_energy = 0.55
	var we := WorldEnvironment.new()
	we.environment = env
	_viewport.add_child(we)

## Returns false if every sampled pixel is transparent — guards against caching
## an empty render (can happen when 3D SubViewport baking fails silently in
## the Compatibility renderer). Without this check drew_model would be set true
## while the model texture is invisible, suppressing the vector-token fallback.
func _image_has_content(img: Image) -> bool:
	var w := img.get_width()
	var h := img.get_height()
	var step: int = maxi(w / 8, 1)
	for y in range(0, h, step):
		for x in range(0, w, step):
			if img.get_pixel(x, y).a > 0.02:
				return true
	return false


func _mount(key: Variant, variant: int) -> void:
	var k := "%s:%d" % [str(key), variant]
	if k == _mounted:
		return
	for c in _pivot.get_children():
		c.queue_free()
	var scene: PackedScene = (_models[key] as Array)[variant]
	_pivot.add_child(scene.instantiate())
	_mounted = k

func _set_camera(view: int, key: Variant) -> void:
	var cfg: Dictionary = _cfg[key]
	_camera.size = cfg["frame"]
	var elev := deg_to_rad(ISO_ELEVATION_DEG if view == View.ISO else TOPDOWN_ELEVATION_DEG)
	var look := Vector3(0.0, cfg["look_y"], 0.0)
	_camera.position = look + Vector3(0.0, sin(elev), cos(elev)) * 10.0
	var up := Vector3.UP if view == View.ISO else Vector3(0.0, 0.0, -1.0)
	_camera.look_at(look, up)
