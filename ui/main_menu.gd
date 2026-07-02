extends Control
## Title screen: a dark sci-fi splash matching the fleet-builder and tactical HUD
## (the shared UiTheme palette over a gradient-and-grid backdrop). This is the
## boot scene; it's pure navigation — no rules, no game state.

# The two hull glyphs keep the map's side colours so the title reads as the same
# game; everything else comes from the shared UiTheme palette.
const SCOUT := Color(0.16, 0.32, 0.62)    # matches HexMapView SIDE_COLORS[0]
const CRUISER := Color(0.62, 0.16, 0.13)  # matches HexMapView SIDE_COLORS[1]

const GAME_SCENE := "res://ui/map_demo.tscn"
const FLEET_SCENE := "res://ui/fleet_builder_screen.tscn"

## The three difficulty ranks, in order, paired to their selector buttons so a
## click can restyle every chip and refresh the blurb.
const DIFFS := [ShipAI.Difficulty.PADWAR, ShipAI.Difficulty.DWAR, ShipAI.Difficulty.ODWAR]
var _diff_buttons: Array[Button] = []
var _diff_blurb: Label
var _save_btn: Button
var _load_btn: Button


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	resized.connect(queue_redraw)   # keep the drawn backdrop in step with size
	_build_ui()


func _build_ui() -> void:
	# The dark gradient + grid backdrop is painted in _draw() (below); the menu
	# UI is added as children so it layers on top of it.
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
	title.add_theme_color_override("font_color", UiTheme.COL_TEXT)
	col.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Tactical airship duels over the dead sea bottoms of Mars"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 18)
	subtitle.add_theme_color_override("font_color", UiTheme.COL_MUTED)
	col.add_child(subtitle)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 24)
	col.add_child(gap)

	_build_difficulty(col)

	var gap_m := Control.new()
	gap_m.custom_minimum_size = Vector2(0, 12)
	col.add_child(gap_m)

	_build_map_picker(col)

	var gap2 := Control.new()
	gap2.custom_minimum_size = Vector2(0, 20)
	col.add_child(gap2)

	# Offered only when a battle was suspended via the in-game gear button. New
	# Game is the primary (green) call to action; Quit is a "leave" warn action.
	if BattleConfig.has_resume():
		_add_menu_button(col, "Resume Battle", _on_resume, "accent")
	_add_menu_button(col, "New Game", _on_new_game, "primary")
	_add_menu_button(col, "Build Fleet", _on_build_fleet)
	# Save captures the suspended battle into the quicksave slot; Load boots it.
	# Both only matter once there's something to act on, so they stay disabled
	# until a battle is suspended / a quicksave exists.
	if BattleConfig.has_resume():
		_save_btn = _add_menu_button(col, "Save", _on_save)
	_load_btn = _add_menu_button(col, "Load", _on_load)
	_load_btn.disabled = not BattleConfig.has_save()
	_add_menu_button(col, "Quit", _on_quit, "warn")


## The difficulty picker: a caption, a row of three "rank" chips (Padwar / Dwar /
## Odwar) styled like the HUD's fleet tabs (accent when chosen), and a one-line
## blurb. Applies to every battle launched from here — it lives in BattleConfig.
func _build_difficulty(col: VBoxContainer) -> void:
	var caption := Label.new()
	caption.text = "ENEMY COMMAND"
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.add_theme_font_size_override("font_size", 13)
	caption.add_theme_color_override("font_color", UiTheme.COL_MUTED)
	col.add_child(caption)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 6)
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
	_diff_blurb.add_theme_color_override("font_color", UiTheme.COL_MUTED)
	col.add_child(_diff_blurb)

	_refresh_difficulty()


func _on_pick_difficulty(level: int) -> void:
	BattleConfig.difficulty = level
	_refresh_difficulty()


## The battlefield picker: a caption + a dropdown of every map in the catalog
## (bundled + mods), by display name. The choice lives in BattleConfig.map_id and
## applies to every battle launched from here. Data-driven — a new map (a mod, or
## one authored in 3d-gen) appears automatically with no menu change.
func _build_map_picker(col: VBoxContainer) -> void:
	var caption := Label.new()
	caption.text = "BATTLEFIELD"
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.add_theme_font_size_override("font_size", 13)
	caption.add_theme_color_override("font_color", UiTheme.COL_MUTED)
	col.add_child(caption)

	var picker := OptionButton.new()
	picker.custom_minimum_size = Vector2(246, 38)
	picker.focus_mode = Control.FOCUS_NONE
	picker.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	picker.add_theme_font_size_override("font_size", 17)

	var ids := MapLibrary.map_ids()
	# If the remembered choice is gone (a removed mod), fall back to the first map.
	if not MapLibrary.has_map(BattleConfig.map_id) and not ids.is_empty():
		BattleConfig.map_id = ids[0]
	for i in ids.size():
		picker.add_item(MapLibrary.map(ids[i]).display_name, i)
		picker.set_item_metadata(i, ids[i])
		if ids[i] == BattleConfig.map_id:
			picker.select(i)
	picker.item_selected.connect(_on_pick_map.bind(picker))

	# Centre the dropdown within the menu column.
	var wrap := HBoxContainer.new()
	wrap.alignment = BoxContainer.ALIGNMENT_CENTER
	wrap.add_child(picker)
	col.add_child(wrap)


func _on_pick_map(index: int, picker: OptionButton) -> void:
	BattleConfig.map_id = picker.get_item_metadata(index)


## Restyle every chip to mark the live choice (bright accent fill + frame when
## selected, dim neutral otherwise) and update the blurb.
func _refresh_difficulty() -> void:
	for i in DIFFS.size():
		_style_chip(_diff_buttons[i], DIFFS[i] == BattleConfig.difficulty)
	_diff_blurb.text = ShipAI.difficulty_blurb(BattleConfig.difficulty)


func _style_chip(b: Button, selected: bool) -> void:
	var fg := UiTheme.COL_ACCENT.lightened(0.3) if selected else UiTheme.COL_MUTED
	for state in ["normal", "hover", "pressed", "focus"]:
		var sb := StyleBoxFlat.new()
		if selected:
			sb.bg_color = UiTheme.COL_ACCENT.darkened(0.45)
			sb.border_color = UiTheme.COL_ACCENT
			sb.set_border_width_all(2)
		else:
			sb.bg_color = UiTheme.COL_BTN_HOVER if state == "hover" else UiTheme.COL_BTN.darkened(0.1)
			sb.border_color = UiTheme.COL_BORDER
			sb.set_border_width_all(1)
		sb.set_corner_radius_all(8)
		sb.set_content_margin_all(6)
		b.add_theme_stylebox_override(state, sb)
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", fg if selected else UiTheme.COL_TEXT)
	b.add_theme_color_override("font_pressed_color", fg)


func _add_menu_button(parent: Control, label: String, handler: Callable, kind := "neutral") -> Button:
	# Shared UiTheme button, scaled up for a prominent menu stack.
	var b := UiTheme.button(label, kind)
	b.custom_minimum_size = Vector2(280, 46)
	b.add_theme_font_size_override("font_size", 20)
	b.pressed.connect(handler)
	parent.add_child(b)
	return b


func _on_resume() -> void:
	BattleConfig.resume = true   # the map reloads the suspended battle on boot
	get_tree().change_scene_to_file(GAME_SCENE)


func _on_build_fleet() -> void:
	get_tree().change_scene_to_file(FLEET_SCENE)


func _on_new_game() -> void:
	BattleConfig.clear()   # a fresh battle always uses the map's default 2v2
	get_tree().change_scene_to_file(GAME_SCENE)


## Copy the suspended battle into the quicksave slot. Confirms in place so the
## player knows it took, and enables Load now that a quicksave exists.
func _on_save() -> void:
	if BattleConfig.save_suspended() != OK:
		return
	if _save_btn != null:
		_save_btn.text = "Saved ✓"
		_save_btn.disabled = true
	if _load_btn != null:
		_load_btn.disabled = false


func _on_load() -> void:
	# Verify the quicksave actually restores before handing off — a save from an
	# older catalog (a hull's guns changed) is rejected here instead of booting
	# into a crash. SaveGame.load_error carries the reason.
	if SaveGame.load_from_file(BattleConfig.SAVE_PATH) == null:
		_load_btn.text = "Load — incompatible save"
		_load_btn.disabled = true
		if SaveGame.load_error != "":
			push_warning("Load: " + SaveGame.load_error)
		return
	BattleConfig.load_save = true   # the map restores the quicksave on boot
	get_tree().change_scene_to_file(GAME_SCENE)


func _on_quit() -> void:
	get_tree().quit()


# ---------------------------------------------------------------------------
# Drawing: the dark gradient + faint grid backdrop (identical to the fleet
# builder's, so the two screens read as one game), then a thin accent rule
# across the title band with the two hulls nose-to-nose — the same facing-
# triangle glyphs the tactical map draws. Painted here (not as a child) so it
# layers cleanly beneath the menu UI, which is added as children.
# ---------------------------------------------------------------------------

const BG_TOP := Color(0.039, 0.055, 0.094)
const BG_BOTTOM := Color(0.071, 0.106, 0.188)
const BG_GRID := Color(0.45, 0.65, 0.95, 0.05)
const BG_GRID_STEP := 56.0

func _draw() -> void:
	_draw_backdrop()
	var y := size.y * 0.30
	var m := size.x * 0.20
	draw_line(Vector2(m, y), Vector2(size.x - m, y), Color(0.45, 0.65, 0.95, 0.18), 2.0)
	_token(Vector2(m + 30.0, y), 2, SCOUT)             # scout, nosing inward
	_token(Vector2(size.x - m - 30.0, y), 5, CRUISER)  # cruiser, facing it down


func _draw_backdrop() -> void:
	var bands := 48
	for i in bands:
		var t := float(i) / float(maxi(1, bands - 1))
		draw_rect(Rect2(0.0, size.y * float(i) / bands, size.x, size.y / bands + 1.0),
				BG_TOP.lerp(BG_BOTTOM, t))
	var x := BG_GRID_STEP
	while x < size.x:
		draw_line(Vector2(x, 0), Vector2(x, size.y), BG_GRID, 1.0)
		x += BG_GRID_STEP
	var gy := BG_GRID_STEP
	while gy < size.y:
		draw_line(Vector2(0, gy), Vector2(size.x, gy), BG_GRID, 1.0)
		gy += BG_GRID_STEP


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
