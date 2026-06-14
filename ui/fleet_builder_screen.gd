extends Control
## Pre-battle fleet-builder: pick a points budget and spend it on hulls for your
## squadron. The AI's roster is generated to the same budget via FleetBuilder.
## "Launch" hands both rosters to the map through BattleConfig; "Quick Battle"
## skips the builder with the map's default 2v2. All cost/validation logic lives
## in FleetBuilder / ShipDef.point_cost — this screen only chooses and displays.

const PAPER := Color(0.95, 0.93, 0.86)
const INK := Color(0.13, 0.11, 0.09)
const OVER := Color(0.72, 0.18, 0.13)
const GAME_SCENE := "res://ui/map_demo.tscn"
const MENU_SCENE := "res://ui/main_menu.tscn"

const BUDGET_STEP := 25
const BUDGET_MIN := 50
const BUDGET_MAX := 2000

var _budget := 250
var _player: Array[StringName] = []
var _ai: Array[StringName] = []
var _ai_seed_base := 0

# Widgets refreshed on every change.
var budget_label: Label
var spent_label: Label
var roster_box: VBoxContainer
var ai_box: VBoxContainer
var launch_btn: Button


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	resized.connect(queue_redraw)
	_ai_seed_base = int(Time.get_unix_time_from_system())
	_build_ui()
	_regen_ai()
	_refresh()


func _build_ui() -> void:
	var pad := MarginContainer.new()
	pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	for s in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + s, 24)
	add_child(pad)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	pad.add_child(root)

	var title := Label.new()
	title.text = "ASSEMBLE YOUR SQUADRON"
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", INK)
	root.add_child(title)

	# Budget row.
	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 8)
	root.add_child(brow)
	var bl := Label.new()
	bl.text = "Budget:"
	bl.add_theme_color_override("font_color", INK)
	brow.add_child(bl)
	_btn(brow, "-", _budget_step.bind(-1))
	budget_label = Label.new()
	budget_label.add_theme_color_override("font_color", INK)
	brow.add_child(budget_label)
	_btn(brow, "+", _budget_step.bind(1))
	spent_label = Label.new()
	spent_label.add_theme_color_override("font_color", INK)
	brow.add_child(spent_label)

	# Three columns: catalog | your roster | enemy preview.
	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 18)
	root.add_child(cols)

	cols.add_child(_catalog_column())

	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.add_theme_constant_override("separation", 4)
	cols.add_child(mid)
	mid.add_child(_heading("YOUR SQUADRON"))
	roster_box = VBoxContainer.new()
	roster_box.add_theme_constant_override("separation", 3)
	mid.add_child(roster_box)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 4)
	cols.add_child(right)
	right.add_child(_heading("ENEMY SQUADRON (auto)"))
	ai_box = VBoxContainer.new()
	ai_box.add_theme_constant_override("separation", 3)
	right.add_child(ai_box)

	# Action row.
	var arow := HBoxContainer.new()
	arow.add_theme_constant_override("separation", 8)
	root.add_child(arow)
	launch_btn = _btn(arow, "Launch", _on_launch)
	_btn(arow, "Quick Battle", _on_quick)
	_btn(arow, "Back", _on_back)


## The buyable-class catalog: one card per class with its cost and an Add button.
func _catalog_column() -> Control:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 4)
	col.add_child(_heading("HULLS"))
	for c in FleetBuilder.available_classes():
		var card := HBoxContainer.new()
		card.add_theme_constant_override("separation", 6)
		col.add_child(card)
		var lbl := Label.new()
		lbl.text = "%s  —  %d pts" % [c["display_name"], c["point_cost"]]
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.add_theme_color_override("font_color", INK)
		card.add_child(lbl)
		var id: StringName = c["id"]
		_btn(card, "Add", func() -> void: _add_ship(id))
	return col


func _heading(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 16)
	l.add_theme_color_override("font_color", INK)
	return l


func _btn(parent: Control, label: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = label
	b.pressed.connect(handler)
	parent.add_child(b)
	return b


# ---------------------------------------------------------------------------
# State changes
# ---------------------------------------------------------------------------

func _budget_step(dir: int) -> void:
	_budget = clampi(_budget + dir * BUDGET_STEP, BUDGET_MIN, BUDGET_MAX)
	_regen_ai()
	_refresh()


func _add_ship(id: StringName) -> void:
	_player.append(id)
	_refresh()


func _remove_ship(index: int) -> void:
	if index >= 0 and index < _player.size():
		_player.remove_at(index)
	_refresh()


## Regenerate the enemy roster to the current budget. Seeded by a per-session
## base XOR the budget, so the preview matches what launches and varies per visit.
func _regen_ai() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _ai_seed_base ^ (_budget * 2654435761)
	_ai = FleetBuilder.generate_roster(_budget, rng)


func _refresh() -> void:
	budget_label.text = "  %d pts  " % _budget
	var spent := FleetBuilder.roster_cost(_player)
	spent_label.text = "    Spent: %d / %d" % [spent, _budget]
	spent_label.add_theme_color_override("font_color", OVER if spent > _budget else INK)

	_fill_roster(roster_box, _player, true)
	_fill_roster(ai_box, _ai, false)

	launch_btn.disabled = not FleetBuilder.is_valid(_player, _budget)


## Render a roster into `box`. Player rows get a Remove button; the enemy preview
## is read-only.
func _fill_roster(box: VBoxContainer, roster: Array, removable: bool) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()
	if roster.is_empty():
		var empty := Label.new()
		empty.text = "(none)"
		empty.add_theme_color_override("font_color", INK)
		box.add_child(empty)
		return
	for i in roster.size():
		var d := ShipLibrary.ship(roster[i])
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		box.add_child(row)
		var lbl := Label.new()
		lbl.text = "%s  (%d)" % [d.display_name, d.point_cost()]
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.add_theme_color_override("font_color", INK)
		row.add_child(lbl)
		if removable:
			var idx := i
			_btn(row, "x", func() -> void: _remove_ship(idx))


# ---------------------------------------------------------------------------
# Navigation
# ---------------------------------------------------------------------------

func _on_launch() -> void:
	if not FleetBuilder.is_valid(_player, _budget):
		return
	BattleConfig.set_battle(_player, _ai, _budget)
	get_tree().change_scene_to_file(GAME_SCENE)


func _on_quick() -> void:
	BattleConfig.clear()   # the map falls back to its default 2v2
	get_tree().change_scene_to_file(GAME_SCENE)


func _on_back() -> void:
	get_tree().change_scene_to_file(MENU_SCENE)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), PAPER, true)
