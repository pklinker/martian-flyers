extends Control
## Pre-battle fleet-builder — a retro sci-fi "assemble your squadron" screen.
##
## Built in code (the project convention), but laid out along this node tree so it
## resizes cleanly via Containers (no manual positioning anywhere):
##
##   Control (this, full-rect root — plays the CanvasLayer/Main-Wrapper role)
##     _Backdrop            … dark gradient + faint grid (the "TextureRect")
##     MarginContainer      … one source of screen padding
##       VBoxContainer      … header / content / footer stack
##         PanelContainer   … HEADER: title, budget steppers, spent + progress bar
##         HBoxContainer    … CONTENT split (expands to fill)
##           PanelContainer … LEFT: "Hulls Available"  -> ScrollContainer -> VBox
##           PanelContainer … RIGHT: "Your Squadron"   -> ScrollContainer -> VBox
##         PanelContainer   … FOOTER: Back | Quick Battle | (spacer) | Launch
##
## (If you preferred building this in the editor, each labelled node above would be
##  a real scene node and you'd grab them with `@onready var x := $Path`. Here we
##  hold the same handles as plain members assigned during _build_ui.)
##
## The enemy fleet is never shown — it's assembled in secret at Launch (same
## budget, no knowledge of your picks), so there's nothing to counter-pick.

const GAME_SCENE := "res://ui/map_demo.tscn"
const MENU_SCENE := "res://ui/main_menu.tscn"

const BUDGET_STEP := 25
const BUDGET_MIN := 50
const BUDGET_MAX := 2000

# --- Palette (cohesive dark sci-fi: cyan = budget/accent, amber = points,
#     green = primary action, red = warning). All in 0..1 Color literals so they
#     can be `const`. -----------------------------------------------------------
const COL_PANEL := Color(0.086, 0.122, 0.220, 0.92)
const COL_ROW := Color(0.118, 0.161, 0.275, 0.92)
const COL_BORDER := Color(0.188, 0.259, 0.408)
const COL_TEXT := Color(0.875, 0.906, 0.949)
const COL_MUTED := Color(0.541, 0.627, 0.761)
const COL_ACCENT := Color(0.204, 0.820, 0.788)   # cyan — budget / headings
const COL_POINTS := Color(0.941, 0.690, 0.220)   # amber — point costs
const COL_WARN := Color(0.886, 0.333, 0.294)     # red — over budget
const COL_LAUNCH := Color(0.200, 0.820, 0.478)   # green — primary action
const COL_BTN := Color(0.133, 0.188, 0.322)      # neutral button
const COL_BTN_HOVER := Color(0.188, 0.259, 0.424)

var _budget := 250
var _player: Array[StringName] = []

# Node handles (assigned during _build_ui — the code-built equivalent of @onready).
var budget_edit: LineEdit
var spent_label: Label
var launch_btn: Button
var catalog_list: VBoxContainer
var roster_list: VBoxContainer
var _bar: ProgressBar
var _bar_fill: StyleBoxFlat     # kept so the fill colour can change with budget state


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_refresh()


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	# Backdrop: a dark vertical gradient with a faint grid — the immersive
	# "TextureRect" stand-in. mouse_filter IGNORE so it never eats clicks.
	add_child(_Backdrop.new())

	# One MarginContainer owns ALL outer screen padding (responsive: margins are
	# theme constants, not hard-coded offsets, so every child reflows on resize).
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for s in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + s, 28)
	add_child(margin)

	# Vertical stack: header (fixed height), content (expands), footer (fixed).
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 16)
	margin.add_child(col)

	col.add_child(_build_header())

	var content := HBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL   # take the middle space
	content.add_theme_constant_override("separation", 16)
	col.add_child(content)
	# Two equal columns; each is a panel wrapping a scrollable list.
	catalog_list = _add_list_column(content, "HULLS AVAILABLE")
	roster_list = _add_list_column(content, "YOUR SQUADRON")

	col.add_child(_build_footer())


func _build_header() -> PanelContainer:
	var panel := _panel()
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	panel.add_child(v)

	var title := Label.new()
	title.text = "ASSEMBLE YOUR SQUADRON"
	title.add_theme_font_size_override("font_size", 32)
	title.add_theme_color_override("font_color", COL_TEXT)
	v.add_child(title)

	# Budget steppers + spent readout on one row.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	v.add_child(row)
	row.add_child(_muted("BUDGET", 14))
	row.add_child(_stepper("–", _budget_step.bind(-1)))
	# Editable budget: type a value directly (faster than stepping by 25), or use
	# the +/- buttons. Commits on Enter or when the field loses focus, clamped to
	# the legal range.
	budget_edit = LineEdit.new()
	budget_edit.text = str(_budget)
	budget_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	budget_edit.custom_minimum_size = Vector2(72, 0)
	budget_edit.max_length = 5
	budget_edit.add_theme_font_size_override("font_size", 18)
	budget_edit.add_theme_color_override("font_color", COL_ACCENT)
	budget_edit.text_submitted.connect(_on_budget_submitted)
	budget_edit.focus_exited.connect(func() -> void: _apply_budget_text(budget_edit.text))
	row.add_child(budget_edit)
	row.add_child(_muted("pts", 14))
	row.add_child(_stepper("+", _budget_step.bind(1)))
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL    # pushes spent to the right
	row.add_child(gap)
	spent_label = Label.new()
	spent_label.add_theme_font_size_override("font_size", 15)
	spent_label.add_theme_color_override("font_color", COL_MUTED)
	row.add_child(spent_label)

	# Visual budget meter: fills with spend, recolours at/over budget.
	_bar = ProgressBar.new()
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(0, 14)
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.05, 0.07, 0.12)
	track.set_corner_radius_all(7)
	track.set_border_width_all(1)
	track.border_color = COL_BORDER
	_bar_fill = StyleBoxFlat.new()
	_bar_fill.bg_color = COL_ACCENT
	_bar_fill.set_corner_radius_all(7)
	# ProgressBar themes its track via "background" and the filled part via "fill".
	_bar.add_theme_stylebox_override("background", track)
	_bar.add_theme_stylebox_override("fill", _bar_fill)
	v.add_child(_bar)

	return panel


## A titled, scrollable list column. Returns the inner VBox the rows go into.
func _add_list_column(parent: HBoxContainer, title: String) -> VBoxContainer:
	var panel := _panel()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL   # equal halves, responsive
	parent.add_child(panel)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)

	var head := Label.new()
	head.text = title
	head.add_theme_font_size_override("font_size", 17)
	head.add_theme_color_override("font_color", COL_ACCENT)
	v.add_child(head)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL    # rows stretch to width
	list.add_theme_constant_override("separation", 8)
	scroll.add_child(list)
	return list


func _build_footer() -> PanelContainer:
	var panel := _panel()
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	panel.add_child(row)

	var back := _button("◄  Back", "neutral")
	back.pressed.connect(_on_back)
	row.add_child(back)

	var quick := _button("Quick Battle", "neutral")
	quick.pressed.connect(_on_quick)
	row.add_child(quick)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	# Launch is the primary action — bright green, larger, eye-drawing.
	launch_btn = _button("Launch  ▶", "primary")
	launch_btn.custom_minimum_size = Vector2(160, 0)
	launch_btn.pressed.connect(_on_launch)
	row.add_child(launch_btn)
	return panel


# ---------------------------------------------------------------------------
# Row builders (rebuilt on every change so disabled/empty states stay correct)
# ---------------------------------------------------------------------------

func _rebuild_catalog() -> void:
	for c in catalog_list.get_children():
		catalog_list.remove_child(c)
		c.queue_free()
	var remaining := _budget - FleetBuilder.roster_cost(_player)
	for entry in FleetBuilder.available_classes():
		var pc := _row_panel()
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 10)
		pc.add_child(hb)

		var name_lbl := Label.new()
		name_lbl.text = entry["display_name"]
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.add_theme_color_override("font_color", COL_TEXT)
		hb.add_child(name_lbl)

		var cost := Label.new()
		cost.text = "%d pts" % int(entry["point_cost"])
		cost.add_theme_color_override("font_color", COL_POINTS)
		hb.add_child(cost)

		var add := _button("＋ Add", "accent")
		add.disabled = int(entry["point_cost"]) > remaining   # can't overspend
		var id: StringName = entry["id"]
		add.pressed.connect(func() -> void: _add_ship(id))
		hb.add_child(add)
		catalog_list.add_child(pc)


func _rebuild_roster() -> void:
	for c in roster_list.get_children():
		roster_list.remove_child(c)
		c.queue_free()
	if _player.is_empty():
		var empty := Label.new()
		empty.text = "No ships yet — add hulls from the left."
		empty.add_theme_color_override("font_color", COL_MUTED)
		roster_list.add_child(empty)
		return
	for i in _player.size():
		var d := ShipLibrary.ship(_player[i])
		var pc := _row_panel()
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 10)
		pc.add_child(hb)

		var name_lbl := Label.new()
		name_lbl.text = d.display_name
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.add_theme_color_override("font_color", COL_TEXT)
		hb.add_child(name_lbl)

		var cost := Label.new()
		cost.text = "(%d)" % d.point_cost()
		cost.add_theme_color_override("font_color", COL_MUTED)
		hb.add_child(cost)

		# Sleek red-tinted remove button (✕) on the far right.
		var rm := _button("✕", "danger")
		rm.custom_minimum_size = Vector2(36, 0)
		var idx := i
		rm.pressed.connect(func() -> void: _remove_ship(idx))
		hb.add_child(rm)
		roster_list.add_child(pc)


# ---------------------------------------------------------------------------
# State / logic
# ---------------------------------------------------------------------------

func _budget_step(dir: int) -> void:
	_budget = clampi(_budget + dir * BUDGET_STEP, BUDGET_MIN, BUDGET_MAX)
	_refresh()


func _on_budget_submitted(_text: String) -> void:
	_apply_budget_text(budget_edit.text)
	budget_edit.release_focus()


## Parse the typed budget and commit it, clamped to the legal range. A blank or
## junk entry falls back to the current budget (the field is rewritten on refresh).
func _apply_budget_text(text: String) -> void:
	var trimmed := text.strip_edges()
	var n := int(trimmed) if trimmed.is_valid_int() else _budget
	_budget = clampi(n, BUDGET_MIN, BUDGET_MAX)
	_refresh()


func _add_ship(id: StringName) -> void:
	_player.append(id)
	_refresh()


func _remove_ship(index: int) -> void:
	if index >= 0 and index < _player.size():
		_player.remove_at(index)
	_refresh()


## Single place that pushes state -> widgets: labels, the progress meter's value
## and colour, the two lists, and the Launch gate.
func _refresh() -> void:
	var spent := FleetBuilder.roster_cost(_player)
	var over := spent > _budget
	# Don't fight the user mid-type: only rewrite the field when it isn't focused.
	if not budget_edit.has_focus():
		budget_edit.text = str(_budget)
	spent_label.text = "SPENT  %d / %d" % [spent, _budget]
	spent_label.add_theme_color_override("font_color", COL_WARN if over else COL_MUTED)

	_bar.max_value = maxi(1, _budget)
	_bar.value = clampi(spent, 0, _budget)
	# Meter colour: red over budget, green when exactly spent out, else cyan.
	if over:
		_bar_fill.bg_color = COL_WARN
	elif spent == _budget:
		_bar_fill.bg_color = COL_LAUNCH
	else:
		_bar_fill.bg_color = COL_ACCENT

	_rebuild_catalog()
	_rebuild_roster()
	launch_btn.disabled = not FleetBuilder.is_valid(_player, _budget)


# ---------------------------------------------------------------------------
# Navigation
# ---------------------------------------------------------------------------

func _on_launch() -> void:
	if not FleetBuilder.is_valid(_player, _budget):
		return
	# Generate the enemy fleet now, from fresh entropy — same budget, no knowledge
	# of the player's roster (and unseen until the battle opens).
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var ai := FleetBuilder.generate_roster(_budget, rng)
	BattleConfig.set_battle(_player, ai, _budget)
	get_tree().change_scene_to_file(GAME_SCENE)


func _on_quick() -> void:
	BattleConfig.clear()   # the map falls back to its default 2v2
	get_tree().change_scene_to_file(GAME_SCENE)


func _on_back() -> void:
	get_tree().change_scene_to_file(MENU_SCENE)


# ---------------------------------------------------------------------------
# Styling helpers (StyleBoxFlat-driven — corner radius + border + content margin
# are what make panels/buttons read as "designed" rather than default grey).
# ---------------------------------------------------------------------------

## A section panel (header / column / footer).
func _panel() -> PanelContainer:
	var pc := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = COL_PANEL
	s.set_corner_radius_all(12)
	s.set_border_width_all(1)
	s.border_color = COL_BORDER
	s.set_content_margin_all(16)   # inner padding so children aren't flush to the edge
	pc.add_theme_stylebox_override("panel", s)
	return pc


## A single list row's card — slightly lighter than its column so rows pop.
func _row_panel() -> PanelContainer:
	var pc := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = COL_ROW
	s.set_corner_radius_all(8)
	s.set_border_width_all(1)
	s.border_color = COL_BORDER
	s.set_content_margin_all(10)
	pc.add_theme_stylebox_override("panel", s)
	return pc


func _muted(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", COL_MUTED)
	return l


func _stepper(text: String, handler: Callable) -> Button:
	var b := _button(text, "neutral")
	b.custom_minimum_size = Vector2(40, 0)
	b.pressed.connect(handler)
	return b


## A styled button. `kind`: "primary" (Launch), "accent" (Add), "danger"
## (Remove), or "neutral" (everything else). Each state (normal/hover/pressed/
## disabled) gets its own StyleBoxFlat so the button responds to the mouse.
func _button(text: String, kind: String) -> Button:
	var fill := COL_BTN
	var hover := COL_BTN_HOVER
	var press := COL_BTN.darkened(0.15)
	var border := COL_BORDER
	var fg := COL_TEXT
	match kind:
		"primary":
			fill = COL_LAUNCH.darkened(0.05)
			hover = COL_LAUNCH.lightened(0.12)
			press = COL_LAUNCH.darkened(0.2)
			border = COL_LAUNCH.lightened(0.2)
			fg = Color(0.04, 0.10, 0.06)        # dark text on the bright accent
		"accent":
			fill = COL_ACCENT.darkened(0.08)
			hover = COL_ACCENT.lightened(0.1)
			press = COL_ACCENT.darkened(0.22)
			border = COL_ACCENT.lightened(0.15)
			fg = Color(0.03, 0.10, 0.10)
		"danger":
			fill = Color(0.42, 0.13, 0.13, 0.55)
			hover = Color(0.62, 0.18, 0.16, 0.85)
			press = Color(0.30, 0.10, 0.10, 0.95)
			border = COL_WARN
			fg = Color(0.98, 0.82, 0.80)

	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_stylebox_override("normal", _btn_style(fill, border))
	b.add_theme_stylebox_override("hover", _btn_style(hover, border))
	b.add_theme_stylebox_override("pressed", _btn_style(press, border))
	b.add_theme_stylebox_override("focus", _btn_style(fill, border))
	b.add_theme_stylebox_override("disabled",
			_btn_style(Color(0.16, 0.20, 0.30, 0.55), Color(0.30, 0.36, 0.48, 0.4)))
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", fg.lightened(0.12))
	b.add_theme_color_override("font_pressed_color", fg)
	b.add_theme_color_override("font_disabled_color", COL_MUTED.darkened(0.15))
	b.add_theme_font_size_override("font_size", 15)
	return b


func _btn_style(col: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = col
	s.set_corner_radius_all(8)
	s.set_border_width_all(1)
	s.border_color = border
	s.set_content_margin_all(8)
	s.content_margin_left = 14    # roomier horizontal padding reads as a real button
	s.content_margin_right = 14
	return s


# ---------------------------------------------------------------------------
# Backdrop: a dark vertical gradient + faint grid. Self-contained Control so the
# whole screen has one immersive background instead of flat beige. Swap in a
# TextureRect with authored art here if you ever want a painted starfield.
# ---------------------------------------------------------------------------

class _Backdrop extends Control:
	const TOP := Color(0.039, 0.055, 0.094)
	const BOTTOM := Color(0.071, 0.106, 0.188)
	const GRID := Color(0.45, 0.65, 0.95, 0.05)
	const GRID_STEP := 56.0

	func _ready() -> void:
		set_anchors_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE   # never intercept clicks
		resized.connect(queue_redraw)

	func _draw() -> void:
		# Banded vertical gradient (cheap; only redraws on resize).
		var bands := 48
		for i in bands:
			var t := float(i) / float(maxi(1, bands - 1))
			draw_rect(Rect2(0.0, size.y * float(i) / bands, size.x, size.y / bands + 1.0),
					TOP.lerp(BOTTOM, t))
		# Faint grid for the retro-tactical feel.
		var x := GRID_STEP
		while x < size.x:
			draw_line(Vector2(x, 0), Vector2(x, size.y), GRID, 1.0)
			x += GRID_STEP
		var y := GRID_STEP
		while y < size.y:
			draw_line(Vector2(0, y), Vector2(size.x, y), GRID, 1.0)
			y += GRID_STEP
