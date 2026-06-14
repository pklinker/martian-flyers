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

## The three difficulty ranks, in order, paired to their selector buttons so a
## click can restyle every chip and refresh the blurb.
const DIFFS := [ShipAI.Difficulty.PADWAR, ShipAI.Difficulty.DWAR, ShipAI.Difficulty.ODWAR]
var _diff_buttons: Array[Button] = []
var _diff_blurb: Label


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
	gap.custom_minimum_size = Vector2(0, 24)
	col.add_child(gap)

	_build_difficulty(col)

	var gap2 := Control.new()
	gap2.custom_minimum_size = Vector2(0, 20)
	col.add_child(gap2)

	# Offered only when a battle was suspended via the in-game Menu button.
	if BattleConfig.has_resume():
		_add_menu_button(col, "Resume Battle", _on_resume)
	_add_menu_button(col, "Build Fleet", _on_build_fleet)
	_add_menu_button(col, "Quick Engagement", _on_start)
	_add_menu_button(col, "Quit", _on_quit)


## The difficulty picker: a caption, a row of three parchment "rank" chips
## (Padwar / Dwar / Odwar), and a one-line blurb describing the live choice.
## Applies to every battle launched from here — it lives in BattleConfig.
func _build_difficulty(col: VBoxContainer) -> void:
	var caption := Label.new()
	caption.text = "ENEMY COMMAND"
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.add_theme_font_size_override("font_size", 13)
	caption.add_theme_color_override("font_color", FAINT)
	col.add_child(caption)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 0)
	col.add_child(row)

	_diff_buttons = []
	for i in DIFFS.size():
		var level: int = DIFFS[i]
		var b := Button.new()
		b.text = ShipAI.difficulty_name(level)
		b.custom_minimum_size = Vector2(120, 38)
		b.focus_mode = Control.FOCUS_NONE
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		b.add_theme_font_size_override("font_size", 17)
		b.pressed.connect(_on_pick_difficulty.bind(level))
		row.add_child(b)
		_diff_buttons.append(b)

	_diff_blurb = Label.new()
	_diff_blurb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_diff_blurb.custom_minimum_size = Vector2(0, 22)
	_diff_blurb.add_theme_font_size_override("font_size", 15)
	_diff_blurb.add_theme_color_override("font_color", INK)
	col.add_child(_diff_blurb)

	_refresh_difficulty()


func _on_pick_difficulty(level: int) -> void:
	BattleConfig.difficulty = level
	_refresh_difficulty()


## Restyle every chip to mark the live choice (INK fill + paper text when
## selected, faint outline otherwise) and update the blurb.
func _refresh_difficulty() -> void:
	for i in DIFFS.size():
		_style_chip(_diff_buttons[i], DIFFS[i] == BattleConfig.difficulty)
	_diff_blurb.text = ShipAI.difficulty_blurb(BattleConfig.difficulty)


func _style_chip(b: Button, selected: bool) -> void:
	var fill := INK if selected else PAPER
	var fg := PAPER if selected else INK
	for state in ["normal", "hover", "pressed", "focus"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = fill if state != "hover" or selected else PAPER.darkened(0.06)
		sb.set_corner_radius_all(6)
		sb.set_border_width_all(1)
		sb.border_color = INK if selected else FAINT
		sb.set_content_margin_all(6)
		b.add_theme_stylebox_override(state, sb)
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", fg)
	b.add_theme_color_override("font_pressed_color", fg)


func _add_menu_button(parent: Control, label: String, handler: Callable) -> void:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(260, 44)
	b.add_theme_font_size_override("font_size", 20)
	b.pressed.connect(handler)
	parent.add_child(b)


func _on_resume() -> void:
	BattleConfig.resume = true   # the map reloads the suspended battle on boot
	get_tree().change_scene_to_file(GAME_SCENE)


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
