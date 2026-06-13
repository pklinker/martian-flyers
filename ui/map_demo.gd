extends Control
## First playable build: you fly the Helium Scout against a greedy AI cruiser.
## Turn flow: ALLOCATE (man guns / assign damage control from your crew pool)
## -> PLOT (set your speed) -> MOVE (8 impulses; click a green hex when it's
## your impulse, the AI moves itself) -> FIRE (pick which bearing guns shoot,
## with a to-hit preview) -> upkeep -> next turn.
## All rules live in the engine; this scene is choreography.

enum DemoPhase { ALLOCATE, PLOT, MOVE, FIRE, OVER }

const PLAYER := 0
const AI := 1

var engine: TurnEngine
var ai: ShipAI
var map: HexMapView
var panels: Array[SSDPanel] = []
var log_box: RichTextLabel
var phase_label: Label

# SSD overlay (floats over the map's right edge; toggled so the player can see
# the whole hex field).
var ssd_overlay: Panel
var ssd_toggle_btn: Button

# Game-over overlay (centered modal shown on victory/defeat).
var game_over_overlay: Panel
var game_over_title: Label
var game_over_detail: Label

# Phase bars (only one visible at a time, beneath the persistent top bar).
var alloc_bar: VBoxContainer
var plot_bar: HBoxContainer
var fire_bar: HBoxContainer

# Plot-bar widgets (built once).
var speed_label: Label
var spd_up: Button
var spd_dn: Button
var begin_btn: Button

# Allocation working state + widgets (alloc_bar is rebuilt each turn).
var alloc := { "guns": [], "damage_control": 0 }
var engine_value := 0
var dc_value := 0
var lookout_value := 0
var _alloc_initialized := false   # prefill once per game; preserve thereafter
var engine_label: Label
var dc_label: Label
var lookout_label: Label          # null when no dust on the field
var crew_label: Label
var confirm_btn: Button
var alloc_guns_row: HBoxContainer  # row 1 of alloc_bar (checkboxes); used by _checked_mounts

var phase := DemoPhase.ALLOCATE
var plot_base_speed := 0   # player's speed at the start of PLOT (accel limit)


func _ready() -> void:
	_build_ui()
	_new_game()


# ---------------------------------------------------------------------------
# UI scaffolding
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	# Main content fills the whole view; the map gets all the space. The SSDs
	# live in a separate overlay (built below) so the map is never cut off.
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	# Persistent top bar: phase prompt + SSD toggle + New Game.
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	root.add_child(top)
	phase_label = Label.new()
	phase_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(phase_label)
	ssd_toggle_btn = _add_button(top, "Hide Ships", _toggle_ssd)
	_add_button(top, "New Game", _new_game)
	_add_button(top, "Menu", _on_quit_to_menu)

	# ALLOCATE bar (two-row VBox: gun checkboxes above, steppers below).
	alloc_bar = VBoxContainer.new()
	alloc_bar.add_theme_constant_override("separation", 3)
	root.add_child(alloc_bar)

	# PLOT bar (static).
	plot_bar = HBoxContainer.new()
	plot_bar.add_theme_constant_override("separation", 8)
	root.add_child(plot_bar)
	spd_dn = _add_button(plot_bar, "Spd -", _on_speed.bind(-1))
	speed_label = Label.new()
	plot_bar.add_child(speed_label)
	spd_up = _add_button(plot_bar, "Spd +", _on_speed.bind(1))
	begin_btn = _add_button(plot_bar, "Begin Movement", _on_begin_movement)

	# FIRE bar (contents rebuilt each fire phase from the shot previews).
	fire_bar = HBoxContainer.new()
	fire_bar.add_theme_constant_override("separation", 6)
	root.add_child(fire_bar)

	map = HexMapView.new()
	map.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map.move_clicked.connect(_on_move_clicked)
	map.map_pressed.connect(_on_map_pressed)
	root.add_child(map)

	log_box = RichTextLabel.new()
	log_box.custom_minimum_size = Vector2(0, 120)
	log_box.scroll_following = true
	root.add_child(log_box)

	_build_ssd_overlay()
	_build_game_over_overlay()


## The SSD overlay: a panel hugging the right edge, on top of the map, holding
## both ship sheets in one scroll. Toggled with the top-bar button (and its own
## Close) so the player can clear it off the map.
func _build_ssd_overlay() -> void:
	ssd_overlay = Panel.new()
	ssd_overlay.anchor_left = 1.0
	ssd_overlay.anchor_right = 1.0
	ssd_overlay.anchor_top = 0.0
	ssd_overlay.anchor_bottom = 1.0
	ssd_overlay.offset_left = -452.0
	ssd_overlay.offset_right = 0.0
	ssd_overlay.offset_top = 0.0
	ssd_overlay.offset_bottom = 0.0
	add_child(ssd_overlay)

	var pad := MarginContainer.new()
	pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 8)
	ssd_overlay.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	pad.add_child(col)

	var header := HBoxContainer.new()
	col.add_child(header)
	var title := Label.new()
	title.text = "SHIP DISPLAYS"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_add_button(header, "Close", _toggle_ssd)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	var stack := VBoxContainer.new()
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack.add_theme_constant_override("separation", 8)
	scroll.add_child(stack)
	for _i in 2:
		var p := SSDPanel.new()
		stack.add_child(p)
		panels.append(p)


func _toggle_ssd() -> void:
	_set_ssd_visible(not ssd_overlay.visible)


func _set_ssd_visible(v: bool) -> void:
	ssd_overlay.visible = v
	ssd_toggle_btn.text = "Hide Ships" if v else "Show Ships"


## Clicking the exposed map clears the overlay out of the way.
func _on_map_pressed() -> void:
	if ssd_overlay.visible:
		_set_ssd_visible(false)


## Centered modal shown when the game ends; hidden at new-game start.
func _build_game_over_overlay() -> void:
	game_over_overlay = Panel.new()
	game_over_overlay.anchor_left = 0.5
	game_over_overlay.anchor_right = 0.5
	game_over_overlay.anchor_top = 0.5
	game_over_overlay.anchor_bottom = 0.5
	game_over_overlay.offset_left = -240.0
	game_over_overlay.offset_right = 240.0
	game_over_overlay.offset_top = -120.0
	game_over_overlay.offset_bottom = 120.0
	game_over_overlay.visible = false
	add_child(game_over_overlay)

	var pad := MarginContainer.new()
	pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 20)
	game_over_overlay.add_child(pad)

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 10)
	pad.add_child(col)

	game_over_title = Label.new()
	game_over_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	game_over_title.add_theme_font_size_override("font_size", 26)
	col.add_child(game_over_title)

	game_over_detail = Label.new()
	game_over_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	game_over_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(game_over_detail)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 12)
	col.add_child(spacer)

	_add_button(col, "Play Again", _new_game)
	_add_button(col, "Main Menu", _on_quit_to_menu)


func _add_button(parent: Control, label: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = label
	b.pressed.connect(handler)
	parent.add_child(b)
	return b


func _show_bar(ph: DemoPhase) -> void:
	alloc_bar.visible = ph == DemoPhase.ALLOCATE
	plot_bar.visible = ph == DemoPhase.PLOT
	fire_bar.visible = ph == DemoPhase.FIRE


# ---------------------------------------------------------------------------
# Game setup / turn flow
# ---------------------------------------------------------------------------

func _new_game() -> void:
	if game_over_overlay != null:
		game_over_overlay.visible = false
	engine = TurnEngine.new()
	engine.setup(int(Time.get_unix_time_from_system()))
	_alloc_initialized = false
	ai = ShipAI.for_ship(engine.ships[AI].def)
	engine.shot_resolved.connect(_on_shot)
	engine.damage_control_repaired.connect(_on_repair)
	engine.game_over.connect(_on_game_over)
	map.set_engine(engine)
	map.clear_highlights()
	for i in 2:
		panels[i].set_ship(engine.ships[i])
	log_box.clear()
	log_box.append_text("Engagement over the dead sea bottom. You fly the Scout (blue).\n")
	_enter_allocate()


func _on_quit_to_menu() -> void:
	get_tree().change_scene_to_file("res://ui/main_menu.tscn")


# --- ALLOCATE --------------------------------------------------------------

func _enter_allocate() -> void:
	phase = DemoPhase.ALLOCATE
	map.clear_highlights()
	ai.allocate(engine, engine.ships[AI])
	# Prefill a sensible default only on the first turn; afterwards carry the
	# player's own crew plan forward (re-validated against losses).
	if _alloc_initialized:
		_revalidate_player_alloc()
	else:
		_prefill_player_alloc()
		_alloc_initialized = true
	_rebuild_alloc_bar()
	_on_alloc_changed()
	_show_bar(DemoPhase.ALLOCATE)
	phase_label.text = "Allocation — man guns or hold crew for damage control, then Confirm"


## Sensible default: reserve engine crew for a cruising speed (never a stall),
## man every gun the rest can afford, leftover to damage control. The player
## then tweaks the speed-vs-guns tradeoff.
func _prefill_player_alloc() -> void:
	var p := engine.ships[PLAYER]
	var pool := p.crew_pool()
	var cruise: int = maxi(p.speed, int(ceil(p.effective_max_speed() / 2.0)))
	var eng: int = mini(p.engine_crew_for_speed(cruise), pool)
	var left := pool - eng
	var picks: Array[int] = []
	for i in p.def.gun_mounts.size():
		if p.gun_states[i]["destroyed"]:
			continue
		var cost: int = ShipLibrary.gun(p.def.gun_mounts[i]["gun_id"]).crew_required
		if left >= cost:
			picks.append(i)
			left -= cost
	engine_value = eng
	dc_value = left
	lookout_value = 0
	alloc = { "guns": picks, "damage_control": left, "lookout": 0 }


## Carry last turn's crew assignment forward, dropping only what is no longer
## possible: guns since knocked out, engine crew above this turn's ceiling, and —
## if crew casualties shrank the pool — load shed (lookout first, then damage
## control, then guns last-manned-first, then engine) until the plan fits again.
func _revalidate_player_alloc() -> void:
	var p := engine.ships[PLAYER]
	var pool := p.crew_pool()
	var picks: Array[int] = []
	for i in alloc["guns"]:
		if int(i) < p.def.gun_mounts.size() and not p.gun_states[int(i)]["destroyed"]:
			picks.append(int(i))
	var max_eng: int = mini(p.engine_crew_for_speed(p.effective_max_speed()), pool)
	engine_value = clampi(engine_value, 0, max_eng)
	dc_value = maxi(dc_value, 0)
	lookout_value = maxi(lookout_value, 0)
	while _alloc_cost(p, picks) > pool and lookout_value > 0:
		lookout_value -= 1
	while _alloc_cost(p, picks) > pool and dc_value > 0:
		dc_value -= 1
	while _alloc_cost(p, picks) > pool and not picks.is_empty():
		picks.pop_back()
	while _alloc_cost(p, picks) > pool and engine_value > 0:
		engine_value -= 1
	alloc = { "guns": picks, "damage_control": dc_value, "lookout": lookout_value }


## Crew cost of a candidate plan: manned guns + engine, DC, and lookout crew.
func _alloc_cost(p: ShipState, picks: Array[int]) -> int:
	var g := 0
	for i in picks:
		g += ShipLibrary.gun(p.def.gun_mounts[i]["gun_id"]).crew_required
	return g + engine_value + dc_value + lookout_value


func _rebuild_alloc_bar() -> void:
	# queue_free() is deferred — the old widgets would linger for the rest of
	# this frame and be double-counted by the _on_alloc_changed() that follows.
	# Detach them now so the budget reads only the freshly built rows.
	for c in alloc_bar.get_children():
		alloc_bar.remove_child(c)
		c.queue_free()
	var p := engine.ships[PLAYER]

	# Row 1: gun checkboxes.
	var guns_row := HBoxContainer.new()
	guns_row.add_theme_constant_override("separation", 6)
	alloc_bar.add_child(guns_row)
	alloc_guns_row = guns_row

	var title := Label.new()
	title.text = "Crew:"
	guns_row.add_child(title)

	for i in p.def.gun_mounts.size():
		var mount: Dictionary = p.def.gun_mounts[i]
		if p.gun_states[i]["destroyed"]:
			var dl := Label.new()
			dl.text = "%s [destroyed]" % str(mount["label"])
			dl.modulate = Color(0.6, 0.6, 0.6)
			guns_row.add_child(dl)
			continue
		var gun: GunDef = ShipLibrary.gun(mount["gun_id"])
		var cb := CheckBox.new()
		cb.text = "%s (%d)" % [str(mount["label"]), gun.crew_required]
		cb.button_pressed = i in alloc["guns"]
		cb.set_meta("mount", i)
		cb.toggled.connect(func(_on: bool) -> void: _on_alloc_changed())
		guns_row.add_child(cb)

	# Row 2: engine/DC/lookout steppers, budget label, and Confirm.
	var ctrl_row := HBoxContainer.new()
	ctrl_row.add_theme_constant_override("separation", 6)
	alloc_bar.add_child(ctrl_row)

	var eng_title := Label.new()
	eng_title.text = "Engine:"
	ctrl_row.add_child(eng_title)
	_add_button(ctrl_row, "-", _eng.bind(-1))
	engine_label = Label.new()
	ctrl_row.add_child(engine_label)
	_add_button(ctrl_row, "+", _eng.bind(1))

	var dc_title := Label.new()
	dc_title.text = "  DC:"
	ctrl_row.add_child(dc_title)
	_add_button(ctrl_row, "-", _dc.bind(-1))
	dc_label = Label.new()
	ctrl_row.add_child(dc_label)
	_add_button(ctrl_row, "+", _dc.bind(1))

	# Lookout crew: only shown when there is dust on the field.
	if _has_dust():
		var lk_title := Label.new()
		lk_title.text = "  Lookout:"
		ctrl_row.add_child(lk_title)
		_add_button(ctrl_row, "-", _lookout.bind(-1))
		lookout_label = Label.new()
		ctrl_row.add_child(lookout_label)
		_add_button(ctrl_row, "+", _lookout.bind(1))
	else:
		lookout_label = null

	crew_label = Label.new()
	ctrl_row.add_child(crew_label)
	confirm_btn = _add_button(ctrl_row, "Confirm Crew", _confirm_allocation)


func _eng(delta: int) -> void:
	engine_value += delta
	_on_alloc_changed()


func _dc(delta: int) -> void:
	dc_value += delta
	_on_alloc_changed()


func _lookout(delta: int) -> void:
	lookout_value += delta
	_on_alloc_changed()


func _has_dust() -> bool:
	if engine == null:
		return false
	for t in engine.terrain.values():
		if int(t) == TerrainDef.Type.DUST_STORM:
			return true
	return false


## Recompute the crew budget, clamp all steppers, and gate the Confirm button.
func _on_alloc_changed() -> void:
	var p := engine.ships[PLAYER]
	var guns := _checked_mounts(alloc_guns_row)
	var gun_cost := 0
	for i in guns:
		gun_cost += ShipLibrary.gun(p.def.gun_mounts[i]["gun_id"]).crew_required
	var pool := p.crew_pool()
	var rate: int = p.def.speed_per_engine_crew
	var max_eng: int = mini(p.engine_crew_for_speed(p.effective_max_speed()), pool)
	engine_value = clampi(engine_value, 0, max_eng)
	dc_value = clampi(dc_value, 0, pool)
	lookout_value = clampi(lookout_value, 0, pool)
	var used := gun_cost + engine_value + dc_value + lookout_value
	alloc = { "guns": guns, "damage_control": dc_value, "lookout": lookout_value }
	engine_label.text = str(engine_value)
	dc_label.text = str(dc_value)
	if lookout_label != null:
		lookout_label.text = str(lookout_value)
	var cap: int = mini(p.effective_max_speed(), engine_value * rate)
	crew_label.text = "   CREW %d / %d   (top speed %d)   " % [used, pool, cap]
	crew_label.modulate = Color(0.85, 0.3, 0.2) if used > pool else Color.WHITE
	confirm_btn.disabled = used > pool


func _confirm_allocation() -> void:
	if phase != DemoPhase.ALLOCATE:
		return
	var p := engine.ships[PLAYER]
	if not p.apply_allocation({ "guns": alloc["guns"], "engine": engine_value,
			"damage_control": dc_value, "lookout": lookout_value }):
		return  # over budget; Confirm should already be disabled
	# A speed plotted last turn may now exceed this turn's crew-gated cap.
	p.speed = mini(p.speed, p.usable_max_speed())
	_refresh_panels()
	_enter_plot()


# --- PLOT ------------------------------------------------------------------

func _enter_plot() -> void:
	phase = DemoPhase.PLOT
	plot_base_speed = engine.ships[PLAYER].speed
	ai.plot(engine, engine.ships[AI])
	_show_bar(DemoPhase.PLOT)
	phase_label.text = "Plot — set speed, then Begin Movement"
	_update_speed_label()


## This turn's plottable speed range: bounded below/above by propeller
## acceleration (±max_speed_change from last turn's speed), and capped by the
## crew-gated top speed.
func _plot_speed_bounds() -> Vector2i:
	var p := engine.ships[PLAYER]
	var dv := p.max_speed_change()
	var lo: int = maxi(plot_base_speed - dv, 0)
	var hi: int = mini(plot_base_speed + dv, p.usable_max_speed())
	return Vector2i(lo, hi)


func _on_speed(delta: int) -> void:
	if phase != DemoPhase.PLOT:
		return
	var p := engine.ships[PLAYER]
	var b := _plot_speed_bounds()
	p.speed = clampi(p.speed + delta, b.x, b.y)
	_update_speed_label()


func _update_speed_label() -> void:
	var p := engine.ships[PLAYER]
	var b := _plot_speed_bounds()
	speed_label.text = "  Speed %d   (top speed %d, accel +/-%d per turn)  " % [
			p.speed, p.usable_max_speed(), p.max_speed_change()]
	# Grey the buttons at the accel/top-speed limits so the cap is visible.
	spd_dn.disabled = p.speed <= b.x
	spd_up.disabled = p.speed >= b.y


# --- MOVE ------------------------------------------------------------------

func _on_begin_movement() -> void:
	if phase != DemoPhase.PLOT:
		return
	phase = DemoPhase.MOVE
	_show_bar(DemoPhase.MOVE)
	engine.begin_movement()
	_advance_movement()


## Walks the engine's shared impulse sequencer, pausing only when the player
## must click a move. The engine counts impulses and emits impulse_advanced;
## this loop just executes (AI) or hands off (player) each offered move.
func _advance_movement() -> void:
	while true:
		var s := engine.next_mover()
		if s == null:
			_enter_fire()
			return
		var moves := engine.legal_moves_for(s)   # already collision/bounds filtered
		if moves.is_empty():
			continue   # boxed in or hard against the map edge: holds this impulse
		if s.side == PLAYER:
			map.set_highlights(moves, s)
			phase_label.text = "Movement — impulse %d / 8: click a green hex" % engine.current_impulse
			return     # wait for the click
		engine.execute_move(s, ai.choose_move(engine, s, moves))
		map.queue_redraw()


func _on_move_clicked(move: Dictionary) -> void:
	if phase != DemoPhase.MOVE:
		return
	engine.execute_move(engine.ships[PLAYER], move)
	map.clear_highlights()
	_advance_movement()


# --- FIRE ------------------------------------------------------------------

func _enter_fire() -> void:
	phase = DemoPhase.FIRE
	map.clear_highlights()
	var bearing := _rebuild_fire_bar()
	_show_bar(DemoPhase.FIRE)
	phase_label.text = "Fire — %d of your guns bear; choose and Resolve" % bearing


## Builds a toggle per bearing gun (with its shot preview) and a greyed line
## per gun that can't fire (with the reason). Returns the count that bear.
func _rebuild_fire_bar() -> int:
	for c in fire_bar.get_children():
		fire_bar.remove_child(c)   # detach now; queue_free is deferred a frame
		c.queue_free()
	var p := engine.ships[PLAYER]
	var e := engine.ships[AI]
	var bearing := 0
	var title := Label.new()
	title.text = "Guns:"
	fire_bar.add_child(title)
	for i in p.def.gun_mounts.size():
		var label := str(p.def.gun_mounts[i]["label"])
		var pv := p.fire_preview(i, e.hex, engine.terrain)
		if pv["bears"]:
			var cb := CheckBox.new()
			var dust_tag := ""
			if int(pv.get("dust_penalty", 0)) > 0:
				dust_tag = " [dust+%d]" % int(pv["dust_penalty"])
			cb.text = "%s  rng %d  %d+ -> %d%s" % [label, pv["range"], pv["to_hit"], pv["damage"], dust_tag]
			if pv["is_torpedo"]:
				# Spell out the finite salvo and the armour-piercing bite, and
				# leave it OFF by default — spending a torpedo is a deliberate call.
				cb.text += "  AP%d  [%d left]" % [pv["armor_piercing"], pv["ammo"]]
				cb.button_pressed = false
			else:
				cb.button_pressed = true
			cb.set_meta("mount", i)
			fire_bar.add_child(cb)
			bearing += 1
		else:
			var dl := Label.new()
			dl.text = "%s [%s]" % [label, str(pv["reason"])]
			dl.modulate = Color(0.6, 0.6, 0.6)
			fire_bar.add_child(dl)
	_add_button(fire_bar, "Resolve Fire", _on_resolve_fire)
	return bearing


func _on_resolve_fire() -> void:
	if phase != DemoPhase.FIRE:
		return
	var p := engine.ships[PLAYER]
	var e := engine.ships[AI]
	# Player fires only the guns left checked; the AI picks its own shots.
	for i in _checked_mounts(fire_bar):
		engine.declare_fire(p, i, e)
	for i in ai.choose_fire(e, p, engine.terrain):
		engine.declare_fire(e, i, p)
	engine.resolve_fire_phase()
	map.queue_redraw()
	_refresh_panels()
	if engine.phase == TurnEngine.Phase.GAME_OVER:
		return
	engine.run_upkeep()   # reloads, buoyancy, DC repairs (logged via _on_repair)
	_refresh_panels()     # reflect upkeep changes (patched tanks) on the sheets
	if engine.phase == TurnEngine.Phase.GAME_OVER:
		map.queue_redraw()
		return
	log_box.append_text("— Turn %d —\n" % engine.turn_number)
	_enter_allocate()


# ---------------------------------------------------------------------------
# Helpers / feedback
# ---------------------------------------------------------------------------

## Mount indices whose checkbox in `bar` is currently ticked.
func _checked_mounts(bar: Control) -> Array[int]:
	var out: Array[int] = []
	for c in bar.get_children():
		if c is CheckBox and c.button_pressed and c.has_meta("mount"):
			out.append(int(c.get_meta("mount")))
	return out


func _refresh_panels() -> void:
	for p in panels:
		p.refresh()


## Damage control patched a buoyancy tank during upkeep — surface it so the
## sheet's tank count recovering doesn't look like a glitch.
func _on_repair(ship: ShipState, tanks_remaining: int) -> void:
	log_box.append_text("%s: damage control patches a buoyancy tank (%d aloft, falls at %d)\n" % [
			ship.def.display_name, tanks_remaining, ship.def.grounding_threshold])


func _on_shot(r: Dictionary) -> void:
	if r.get("los_blocked", false):
		log_box.append_text("%s %s: LOS blocked at range %d\n" % [
				r["firer"], r["gun"], r["range"]])
		return
	var dust_note := ""
	if int(r.get("dust_penalty", 0)) > 0:
		dust_note = " [dust +%d]" % int(r["dust_penalty"])
	if not r["hit"]:
		log_box.append_text("%s %s: miss at range %d (rolled %d, needed %d%s)\n" % [
				r["firer"], r["gun"], r["range"], r["roll"], r["needed"], dust_note])
		return
	log_box.append_text("%s %s HITS %s facing #%d for %d (armor %d, internals %d)%s\n" % [
			r["firer"], r["gun"], r["target"], r["facing_struck"],
			r["damage"], r["armor_absorbed"], (r["internals"] as Array).size(), dust_note])
	for hit in r["internals"]:
		log_box.append_text("    > %s: %s\n" % [hit["system"], hit["effect"]])


func _on_game_over(side: int, reason: String) -> void:
	phase = DemoPhase.OVER
	_show_bar(DemoPhase.OVER)
	map.clear_highlights()

	var winner := engine.ships[side]
	var loser  := engine.ships[1 - side]
	var flavor := "settled on the dead sea bottom" if loser.grounded \
			else "consumed in radium fire"
	var player_won := side == PLAYER

	if player_won:
		game_over_title.text = "VICTORY"
		game_over_detail.text = "%s\n%s — turn %d" % [
				winner.def.display_name.to_upper(), flavor, engine.turn_number]
	else:
		game_over_title.text = "DEFEAT"
		game_over_detail.text = "Your flyer %s — turn %d\n%s victorious" % [
				flavor, engine.turn_number, winner.def.display_name.to_upper()]

	game_over_overlay.visible = true
	log_box.append_text("\n*** %s VICTORIOUS — %s ***\n" % [
			winner.def.display_name.to_upper(), reason])
	phase_label.text = "Game over — turn %d" % engine.turn_number
