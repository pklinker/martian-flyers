extends Control
## Title screen: a parchment-and-ink splash with Start / Quit. This is the boot
## scene; Start hands off to the playable map. Deliberately tiny — no rules, no
## game state, just navigation.

const PAPER := Color(0.95, 0.93, 0.86)
const INK := Color(0.13, 0.11, 0.09)
const FAINT := Color(0.13, 0.11, 0.09, 0.30)
const SCOUT := Color(0.16, 0.32, 0.62)    # matches HexMapView SIDE_COLORS[0]
const CRUISER := Color(0.62, 0.16, 0.13)  # matches HexMapView SIDE_COLORS[1]

const GAME_SCENE := "res://ui/map_demo.tscn"
const FLEET_SCENE := "res://ui/fleet_builder_screen.tscn"


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	resized.connect(queue_redraw)   # keep the drawn flourishes in step with size
	_build_ui()


func _build_ui() -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 8)
	center.add_child(col)

	var title := Label.new()
	title.text = "BARSOOM FLYERS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_color", INK)
	col.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Tactical airship duels over the dead sea bottoms of Mars"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 18)
	subtitle.add_theme_color_override("font_color", INK)
	col.add_child(subtitle)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 36)
	col.add_child(gap)

	_add_menu_button(col, "Build Fleet", _on_build_fleet)
	_add_menu_button(col, "Quick Engagement", _on_start)
	_add_menu_button(col, "Quit", _on_quit)


func _add_menu_button(parent: Control, label: String, handler: Callable) -> void:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(260, 44)
	b.add_theme_font_size_override("font_size", 20)
	b.pressed.connect(handler)
	parent.add_child(b)


func _on_build_fleet() -> void:
	get_tree().change_scene_to_file(FLEET_SCENE)


func _on_start() -> void:
	BattleConfig.clear()   # Quick Engagement always uses the map's default 2v2
	get_tree().change_scene_to_file(GAME_SCENE)


func _on_quit() -> void:
	get_tree().quit()


# ---------------------------------------------------------------------------
# Drawing: parchment ground, a thin ink rule, and the two hulls nose-to-nose —
# the same facing-triangle glyphs the tactical map draws.
# ---------------------------------------------------------------------------

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), PAPER, true)
	var y := size.y * 0.30
	var m := size.x * 0.20
	draw_line(Vector2(m, y), Vector2(size.x - m, y), FAINT, 2.0)
	_token(Vector2(m + 30.0, y), 2, SCOUT)             # scout, nosing inward
	_token(Vector2(size.x - m - 30.0, y), 5, CRUISER)  # cruiser, facing it down


func _token(c: Vector2, facing: int, col: Color) -> void:
	var r := 20.0
	var dir := _facing_dir(facing)
	var tip := c + dir * r * 0.9
	var a1 := deg_to_rad(facing * 60.0 + 145.0)
	var a2 := deg_to_rad(facing * 60.0 - 145.0)
	var b1 := c + r * 0.8 * Vector2(sin(a1), -cos(a1))
	var b2 := c + r * 0.8 * Vector2(sin(a2), -cos(a2))
	draw_colored_polygon(PackedVector2Array([tip, b1, b2]), col)
	draw_polyline(PackedVector2Array([tip, b1, b2, tip]), Color(0, 0, 0, 0.6), 1.5)


static func _facing_dir(facing: int) -> Vector2:
	var a := deg_to_rad(facing * 60.0)
	return Vector2(sin(a), -cos(a))
