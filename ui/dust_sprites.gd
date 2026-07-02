class_name DustSprites
extends RefCounted
## Optional authored animated-sprite terrain (dust storms, gas clouds…): a looping
## sheet (prefix_<n>.png + .json sidecar) per variant, grouped by terrain KIND.
## Data-driven from the catalog (MAP_MODDING.md §5): every kind whose render_type
## is "sprite" has its sheets scanned from its own source_root — res:// for core
## (editor-imported), user://mods/<pack>/ for a mod. When a kind has sheets
## HexMapView plays the nearest variant at each of its hexes; otherwise it keeps
## the procedural puff column. Pure presentation, optional, zero cost until a
## sheet lands. Tree-free (load / Image / FileAccess) so it's unit-testable.

## Default on-screen sizing when a kind's render.sprite omits span/anchor. Kept as
## the historical dust values; a kind normally carries its own in render.sprite.
const FRAME_SPAN_UNITS := 1.8   # hex-units the sheet spans on the map
const GROUND_ANCHOR := 0.62     # fraction down a frame where the hex centre sits

## kind id -> Array of variant dicts {tex, cols, rows, frames, frame_size, fps}.
var _by_kind: Dictionary = {}


## Scan every sprite-type kind in the catalog for its sheets (prefix_1..prefix_5).
func scan_assets() -> void:
	_by_kind.clear()
	for kid in MapLibrary.kind_ids():
		var k := MapLibrary.kind(kid)
		if k.render_type() != "sprite":
			continue
		var sprite: Dictionary = k.render.get("sprite", {})
		var prefix := String(sprite.get("prefix", ""))
		if prefix.is_empty():
			continue
		# Sprite sheets live under the kind's asset root; default dir "terrain".
		var dir := k.source_root.path_join("assets").path_join(String(sprite.get("dir", "terrain"))) + "/"
		var variants: Array[Dictionary] = []
		for i in range(1, 6):
			var stem := "%s%s_%d" % [dir, prefix, i]
			var tex := _load_texture(stem + ".png")
			if tex == null:
				continue
			var info := _read_meta(stem + ".json", tex)
			if info["frames"] <= 0 or info["cols"] <= 0 or info["frame_size"] <= 0:
				continue   # unusable layout; skip rather than draw garbage
			info["tex"] = tex
			variants.append(info)
		if not variants.is_empty():
			_by_kind[kid] = variants


## Load a sheet texture. Editor-imported res:// assets go through ResourceLoader;
## a user:// mod png is loaded via Image at runtime (a png needs no .import to
## load this way — the sprite counterpart to the ModelBaker glTF path).
static func _load_texture(path: String) -> Texture2D:
	if path.begins_with("res://"):
		return load(path) as Texture2D if ResourceLoader.exists(path) else null
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(path) != OK:
		return null
	return ImageTexture.create_from_image(img)


## Read the JSON sidecar, inferring sane defaults from the texture when fields are
## missing (so a bare square sheet still animates).
func _read_meta(path: String, tex: Texture2D) -> Dictionary:
	var frames := 0
	var frame_size := 0
	var cols := 0
	var rows := 0
	var fps := 24.0
	if FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary:
			frame_size = int(parsed.get("frameSize", 0))
			frames = int(parsed.get("frameCount", 0))
			cols = int(parsed.get("columns", 0))
			rows = int(parsed.get("rows", 0))
			fps = float(parsed.get("fps", 24.0))
	# Fill gaps from the texture dimensions.
	if cols > 0 and frame_size <= 0:
		frame_size = int(tex.get_width() / cols)
	if frame_size > 0 and cols <= 0:
		cols = int(tex.get_width() / frame_size)
	if frame_size > 0 and rows <= 0:
		rows = int(tex.get_height() / frame_size)
	if frames <= 0 and cols > 0 and rows > 0:
		frames = cols * rows
	return {"cols": cols, "rows": rows, "frames": frames, "frame_size": frame_size, "fps": fps}


## Does `kind` have any loaded sprite sheets?
func has_sprites(kind: StringName) -> bool:
	return _by_kind.has(kind) and not (_by_kind[kind] as Array).is_empty()

func variant_count(kind: StringName) -> int:
	return (_by_kind[kind] as Array).size() if _by_kind.has(kind) else 0

func texture(kind: StringName, variant: int) -> Texture2D:
	return _by_kind[kind][variant]["tex"]


## Which frame plays at clock time `t` (seconds), looping at the sheet's fps.
func frame_for_time(kind: StringName, variant: int, t: float) -> int:
	var v: Dictionary = _by_kind[kind][variant]
	var frames: int = v["frames"]
	if frames <= 0:
		return 0
	return posmod(int(t * float(v["fps"])), frames)


## Pixel region of `frame` within the variant's sheet, for draw_texture_rect_region.
func frame_region(kind: StringName, variant: int, frame: int) -> Rect2:
	var v: Dictionary = _by_kind[kind][variant]
	var cols: int = v["cols"]
	var fs: int = v["frame_size"]
	var col := frame % cols
	var row := frame / cols
	return Rect2(col * fs, row * fs, fs, fs)
