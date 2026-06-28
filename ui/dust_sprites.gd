class_name DustSprites
extends RefCounted
## Optional authored dust-storm animations (assets/terrain/duststorm_<n>.png + .json,
## produced by the 3d-gen editor, see ART_PLAN §4b). Each pair is a looping sprite
## sheet: a square grid of frames plus a JSON sidecar describing the layout. When any
## are present HexMapView plays the nearest variant at each dust hex; with none it keeps
## drawing the procedural puff column. Pure presentation, fully optional, zero cost until
## an asset lands.
##
## Tree-free (load + FileAccess only) so it's safe to construct from a unit test.

const TERRAIN_DIR := "res://assets/terrain/"
const FRAME_SPAN_UNITS := 1.8   # hex-units the sheet spans on the map (matches the editor billboard)
const GROUND_ANCHOR := 0.62     # fraction down a frame where the hex centre sits (matches editor cy)

## One entry per loaded variant: {tex, cols, rows, frames, frame_size, fps}.
var _variants: Array[Dictionary] = []


## Look for duststorm_1.png … duststorm_5.png (+ matching .json) and load any that exist.
func scan_assets() -> void:
	_variants.clear()
	for i in range(1, 6):
		var stem := "%sduststorm_%d" % [TERRAIN_DIR, i]
		var png := stem + ".png"
		if not ResourceLoader.exists(png):
			continue
		var tex := load(png) as Texture2D
		if tex == null:
			continue
		var info := _read_meta(stem + ".json", tex)
		if info["frames"] <= 0 or info["cols"] <= 0 or info["frame_size"] <= 0:
			continue   # unusable layout; skip rather than draw garbage
		info["tex"] = tex
		_variants.append(info)


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


func has_sprites() -> bool:
	return not _variants.is_empty()

func variant_count() -> int:
	return _variants.size()

func texture(variant: int) -> Texture2D:
	return _variants[variant]["tex"]


## Which frame plays at clock time `t` (seconds), looping at the sheet's fps.
func frame_for_time(variant: int, t: float) -> int:
	var v := _variants[variant]
	var frames: int = v["frames"]
	if frames <= 0:
		return 0
	return posmod(int(t * float(v["fps"])), frames)


## Pixel region of `frame` within the variant's sheet, for draw_texture_rect_region.
func frame_region(variant: int, frame: int) -> Rect2:
	var v := _variants[variant]
	var cols: int = v["cols"]
	var fs: int = v["frame_size"]
	var col := frame % cols
	var row := frame / cols
	return Rect2(col * fs, row * fs, fs, fs)
