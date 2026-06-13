extends SceneTree
## Temporary visual check: loads the map demo, waits a few frames, saves a
## screenshot to user://, and quits. Run windowed (not headless):
##   Godot --path . -s res://tests/screenshot_check.gd -- out.png

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out_path: String = args[0] if args.size() > 0 else "screenshot.png"
	var scene: PackedScene = load("res://ui/map_demo.tscn")
	root.add_child(scene.instantiate())
	_capture(out_path)


func _capture(out_path: String) -> void:
	for _i in 20:
		await process_frame
	var img := root.get_texture().get_image()
	img.save_png("res://" + out_path)
	print("saved %s (%dx%d)" % [out_path, img.get_width(), img.get_height()])
	quit(0)
