class_name TerrainModels
extends Node
## Offscreen 3D-model baker for terrain features (hills/towers) in the isometric map.
##
## Authored glTF models (assets/terrain/<type>_<n>.glb, see ART_PLAN §4b) are rendered
## through an orthographic Camera3D in a private SubViewport and captured to sprites,
## one per ~15° of field rotation. HexMapView blits the nearest-angle sprite in its
## depth-sorted pass; when no model exists for a type it keeps drawing the procedural
## prism. So this is pure presentation, fully optional, and adds zero cost (and no 3D
## nodes at all) until a model is actually present.
##
## Baking can't happen inside _draw() (it needs a rendered frame), so the rig bakes
## asynchronously in the background: HexMapView requests (type, variant, bucket, view),
## draws the prism meanwhile, and redraws when `baked` fires with the sprite ready.

signal baked   # a new sprite landed in the cache; listeners should queue_redraw

const TERRAIN_DIR := "res://assets/terrain/"
const BAKE_SIZE := 192                  # px square of each baked sprite
const MODEL_FRAME_UNITS := 2.6          # world units the bake camera spans (hex units)
const AZIMUTH_BUCKETS := 24             # rotation snap for the cache (15° each)
const ISO_ELEVATION_DEG := 35.0         # camera tilt matching hex_map ISO_TILT (~0.58)
const TOPDOWN_ELEVATION_DEG := 89.0     # near-straight-down for the flat view

enum View { TOPDOWN, ISO }

## type:int (TerrainDef.Type) -> Array[PackedScene] of loaded variant models.
var _models: Dictionary = {}
## cache key string -> ImageTexture (the baked sprite).
var _cache: Dictionary = {}
## pending bake keys (as dicts), processed one per frame in the background.
var _pending: Array[Dictionary] = []
var _baking := false

# Lazily-built 3D rig (only created once something actually needs baking).
var _viewport: SubViewport
var _camera: Camera3D
var _pivot: Node3D
var _mounted_key := ""                   # which (type,variant) model is in the pivot now


func _ready() -> void:
	scan_assets()
	set_process(false)                    # only tick while there's baking to do


# ---------------------------------------------------------------------------
# Asset discovery (tree-free — safe to call from a unit test)
# ---------------------------------------------------------------------------

## Look for assets/terrain/<prefix>_1.glb, _2.glb … and load any that exist. No assets
## means _models stays empty and has_model() is false everywhere → prism fallback.
func scan_assets() -> void:
	_models.clear()
	_scan_one("hill", TerrainDef.Type.HILL)
	_scan_one("tower", TerrainDef.Type.TOWER)

func _scan_one(prefix: String, type: int) -> void:
	var variants: Array[PackedScene] = []
	for i in range(1, 6):
		var path := "%s%s_%d.glb" % [TERRAIN_DIR, prefix, i]
		if ResourceLoader.exists(path):
			var res := load(path)
			if res is PackedScene:
				variants.append(res)
	if not variants.is_empty():
		_models[type] = variants

func has_model(type: int) -> bool:
	return _models.has(type) and not (_models[type] as Array).is_empty()

func variant_count(type: int) -> int:
	return (_models[type] as Array).size() if has_model(type) else 0


# ---------------------------------------------------------------------------
# Angle bucketing (pure)
# ---------------------------------------------------------------------------

## Snap a field rotation (radians) to the nearest of AZIMUTH_BUCKETS cache slots.
func angle_bucket(theta: float) -> int:
	var step := TAU / float(AZIMUTH_BUCKETS)
	return posmod(int(round(theta / step)), AZIMUTH_BUCKETS)

func bucket_theta(bucket: int) -> float:
	return float(bucket) * (TAU / float(AZIMUTH_BUCKETS))


# ---------------------------------------------------------------------------
# Cache access + background baking
# ---------------------------------------------------------------------------

func _key(type: int, variant: int, bucket: int, view: int) -> String:
	return "%d:%d:%d:%d" % [type, variant, bucket, view]

## The baked sprite for this combo, or null if it hasn't been baked yet.
func get_texture(type: int, variant: int, bucket: int, view: int) -> Texture2D:
	return _cache.get(_key(type, variant, bucket, view), null)

## Ask for a sprite to be baked (no-op if cached/queued). Triggers lazy rig setup.
func request(type: int, variant: int, bucket: int, view: int) -> void:
	if not has_model(type):
		return
	var k := _key(type, variant, bucket, view)
	if _cache.has(k):
		return
	for p in _pending:
		if p["k"] == k:
			return
	_pending.append({"k": k, "type": type, "variant": variant, "bucket": bucket, "view": view})
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
	_mount(job["type"], job["variant"])
	_set_camera(job["view"])
	_pivot.rotation = Vector3(0.0, bucket_theta(job["bucket"]), 0.0)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	# Let the SubViewport render the frame before reading it back.
	await get_tree().process_frame
	await get_tree().process_frame
	var img := _viewport.get_texture().get_image()
	if img != null:
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
	_viewport.own_world_3d = true                       # isolated world, no scene bleed
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)

	_pivot = Node3D.new()
	_viewport.add_child(_pivot)

	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = MODEL_FRAME_UNITS
	_camera.near = 0.05
	_camera.far = 100.0
	_viewport.add_child(_camera)

	# Key light roughly matching the map's SUN_SCREEN (down-right); ambient fill so the
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

## Swap the model in the pivot to the requested (type, variant), reused across bakes.
func _mount(type: int, variant: int) -> void:
	var k := "%d:%d" % [type, variant]
	if k == _mounted_key:
		return
	for c in _pivot.get_children():
		c.queue_free()
	var scene: PackedScene = (_models[type] as Array)[variant]
	_pivot.add_child(scene.instantiate())
	_mounted_key = k

## Aim the camera from the requested view. The pivot supplies the field rotation; the
## camera only sets elevation, looking at roughly the model's mid-height.
func _set_camera(view: int) -> void:
	var elev := deg_to_rad(ISO_ELEVATION_DEG if view == View.ISO else TOPDOWN_ELEVATION_DEG)
	var look := Vector3(0.0, 0.4, 0.0)
	var dist := 10.0
	_camera.position = look + Vector3(0.0, sin(elev), cos(elev)) * dist
	# Up is +Y except looking near-straight-down, where +Y is parallel to the view.
	var up := Vector3.UP if view == View.ISO else Vector3(0.0, 0.0, -1.0)
	_camera.look_at(look, up)
