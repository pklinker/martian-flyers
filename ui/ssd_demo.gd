extends Control
## SSD panel demo: the two starting ships parked at range 2, nose to nose,
## with buttons to trade volleys and watch the sheets mark themselves off.
## Everything flows through TurnEngine signals — this scene contains no rules.

var engine: TurnEngine
var panels: Array[SSDPanel] = []
var log_box: RichTextLabel
var turn_label: Label


func _ready() -> void:
	_build_ui()
	_new_game()


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	# Toolbar
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	root.add_child(bar)
	_add_button(bar, "Scout Volley", _on_volley.bind(0))
	_add_button(bar, "Cruiser Volley", _on_volley.bind(1))
	_add_button(bar, "Exchange Fire", _on_exchange)
	_add_button(bar, "Next Turn", _on_next_turn)
	_add_button(bar, "New Game", _new_game)
	turn_label = Label.new()
	turn_label.text = "Turn 1"
	bar.add_child(turn_label)

	# The two SSDs, side by side
	var sheets := HBoxContainer.new()
	sheets.add_theme_constant_override("separation", 12)
	sheets.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(sheets)
	for _i in 2:
		var scroll := ScrollContainer.new()
		scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		sheets.add_child(scroll)
		var panel := SSDPanel.new()
		scroll.add_child(panel)
		panels.append(panel)

	# Combat log
	log_box = RichTextLabel.new()
	log_box.custom_minimum_size = Vector2(0, 150)
	log_box.scroll_following = true
	root.add_child(log_box)


func _add_button(parent: Control, label: String, handler: Callable) -> void:
	var b := Button.new()
	b.text = label
	b.pressed.connect(handler)
	parent.add_child(b)


func _new_game() -> void:
	engine = TurnEngine.new()
	engine.setup(int(Time.get_unix_time_from_system()))
	engine.shot_resolved.connect(_on_shot)
	engine.game_over.connect(_on_game_over)

	# Park them nose to nose at range 2 so bow facings take the heat.
	engine.ships[0].hex = Vector2i(0, 2)
	engine.ships[0].facing = 0
	engine.ships[1].hex = Vector2i(0, 0)
	engine.ships[1].facing = 3
	_man_all_guns()

	for i in 2:
		panels[i].set_ship(engine.ships[i])
	log_box.clear()
	log_box.append_text("New engagement. Range 2, bows on.\n")
	turn_label.text = "Turn %d" % engine.turn_number


func _man_all_guns() -> void:
	for s in engine.ships:
		var picks: Array[int] = []
		var crew_left := s.crew_pool()
		for i in s.def.gun_mounts.size():
			if s.gun_states[i]["destroyed"]:
				continue
			var cost: int = ShipLibrary.gun(s.def.gun_mounts[i]["gun_id"]).crew_required
			if crew_left >= cost:
				picks.append(i)
				crew_left -= cost
		s.apply_allocation({ "guns": picks, "engine": 0, "damage_control": min(crew_left, 1) })


func _on_volley(side: int) -> void:
	if engine.phase == TurnEngine.Phase.GAME_OVER:
		return
	var firer := engine.ships[side]
	var target := engine.ships[1 - side]
	var declared := firer.guns_bearing(target.hex)
	if declared.is_empty():
		log_box.append_text("%s: no guns bear (arc, range, reload, or crew).\n"
				% firer.def.display_name)
		return
	for mi in declared:
		engine.declare_fire(firer, mi, target)
	engine.resolve_fire_phase()
	_refresh()


func _on_exchange() -> void:
	if engine.phase == TurnEngine.Phase.GAME_OVER:
		return
	for s in engine.ships:
		var enemy := engine.ships[1 - s.side]
		for mi in s.guns_bearing(enemy.hex):
			engine.declare_fire(s, mi, enemy)
	engine.resolve_fire_phase()
	_refresh()


func _on_next_turn() -> void:
	if engine.phase == TurnEngine.Phase.GAME_OVER:
		return
	engine.run_upkeep()
	_man_all_guns()
	turn_label.text = "Turn %d" % engine.turn_number
	log_box.append_text("— Turn %d: reloads tick, crews re-man guns. —\n" % engine.turn_number)
	_refresh()


func _refresh() -> void:
	for p in panels:
		p.refresh()


func _on_shot(r: Dictionary) -> void:
	if not r["hit"]:
		log_box.append_text("%s %s: MISS at range %d (rolled %d, needed %d)\n" % [
				r["firer"], r["gun"], r["range"], r["roll"], r["needed"]])
		return
	log_box.append_text("%s %s HITS %s facing #%d for %d (armor %d, internals %d)\n" % [
			r["firer"], r["gun"], r["target"], r["facing_struck"],
			r["damage"], r["armor_absorbed"], (r["internals"] as Array).size()])
	for hit in r["internals"]:
		log_box.append_text("    > %s: %s\n" % [hit["system"], hit["effect"]])


func _on_game_over(side: int, reason: String) -> void:
	log_box.append_text("\n*** %s VICTORIOUS — %s ***\n" % [
			engine.ships[side].def.display_name.to_upper(), reason])
	_refresh()
