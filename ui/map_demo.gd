extends Control
## First playable fleet build: you fly a two-ship squadron (Helium Scout +
## One-Man Flyer) against an AI squadron (Zodangan Cruiser + Helium Battleship).
## Turn flow, now per-ship for your whole fleet:
##   ALLOCATE — for each of your living ships, man guns / engine / damage control
##              from its crew pool; commit each, then Begin Plot.
##   PLOT     — set each ship's speed.
##   MOVE     — 8 impulses; the engine hands back whichever ship moves next (yours
##              or the AI's); click a green hex for yours, the AI flies its own.
##   FIRE     — each of your ships' bearing guns picks a target among the live
##              enemies (default nearest in arc/range; click an enemy to retarget);
##              Resolve fires both fleets at once.
##   UPKEEP   — reloads, fires, buoyancy; then the next turn.
## All rules live in the engine; this scene is choreography. Victory is decided by
## the engine on a side basis (a fleet loses only when its last ship is out).

enum DemoPhase { ALLOCATE, PLOT, MOVE, FIRE, OVER }

const PLAYER_SIDE := 0
const AI_SIDE := 1

## Single quicksave slot. user:// keeps it in the per-user data dir, off in the
## project tree, so it survives reinstalls of the game build but not the player.
const SAVE_PATH := "user://quicksave.flyersave"

var engine: TurnEngine
var ais: Dictionary = {}              # ShipState (AI side) -> ShipAI
var map: HexMapView
var sound: SoundBank
var panels: Array[SSDPanel] = []      # one SSD per ship, rebuilt per game
var log_box: RichTextLabel
var phase_label: Label

# SSD overlay (floats over the map's right edge; toggled so the player can see
# the whole hex field).
var ssd_overlay: Panel
var ssd_toggle_btn: Button
var ssd_stack: VBoxContainer          # holds the per-ship SSD panels

# Game-over overlay (centered modal shown on victory/defeat/draw).
var game_over_overlay: Panel
var game_over_title: Label
var game_over_detail: Label

# Roster strip (shown in ALLOCATE/PLOT/FIRE): one button per living player ship,
# selecting which ship the phase bar edits.
var roster_bar: HBoxContainer

# Phase bars (only one visible at a time, beneath the persistent top bar).
var alloc_bar: VBoxContainer
var plot_bar: HBoxContainer
var fire_bar: HBoxContainer

# Plot-bar widgets (built once).
var speed_label: Label
var spd_up: Button
var spd_dn: Button
var begin_btn: Button

# Allocation widgets (alloc_bar is rebuilt for each selected ship). The module
# vars below mirror the active ship's steppers; per-ship plans live in `_alloc`.
var engine_value := 0
var dc_value := 0
var lookout_value := 0
var engine_label: Label
var dc_label: Label
var lookout_label: Label          # null when no dust on the field
var crew_label: Label
var confirm_btn: Button           # commit the active ship's crew plan
var alloc_proceed_btn: Button     # leave ALLOCATE; gated on every ship committed
var alloc_guns_row: HBoxContainer

# Per-ship phase state, keyed by ShipState.
var _alloc: Dictionary = {}       # ship -> { guns:Array, engine, dc, lookout, committed }
var _alloc_initialized := false   # prefill once per game; carry plans forward after
var _plot_base: Dictionary = {}   # ship -> speed at the start of PLOT (accel limit)
var _fire_targets: Dictionary = {}  # ship -> { mount_index -> enemy ShipState }
var _fire_choice: Dictionary = {}   # ship -> Array[int] of mounts the player will fire

var _active: ShipState            # the player ship the phase bar is editing

var phase := DemoPhase.ALLOCATE


func _ready() -> void:
	_build_ui()
	_new_game()


# ---------------------------------------------------------------------------
# UI scaffolding
# ---------------------------------------------------------------------------

func _build_ui() -> void:
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
	_add_button(top, "Save", _on_save)
	_add_button(top, "Load", _on_load)
	_add_button(top, "New Game", _new_game)
	_add_button(top, "Menu", _on_quit_to_menu)

	# Roster strip: which of your ships the phase bar is editing.
	roster_bar = HBoxContainer.new()
	roster_bar.add_theme_constant_override("separation", 6)
	root.add_child(roster_bar)

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
	map.hex_clicked.connect(_on_hex_clicked)
	map.map_pressed.connect(_on_map_pressed)
	root.add_child(map)

	sound = SoundBank.new()
	add_child(sound)

	log_box = RichTextLabel.new()
	log_box.custom_minimum_size = Vector2(0, 120)
	log_box.scroll_following = true
	root.add_child(log_box)

	_build_ssd_overlay()
	_build_game_over_overlay()


## The SSD overlay: a panel hugging the right edge, on top of the map, holding
## every ship's sheet in one scroll. Toggled with the top-bar button (and its own
## Close) so the player can clear it off the map. The panels themselves are built
## per game in _build_ssd_panels (the fleet size is known only once the engine is).
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
	ssd_stack = VBoxContainer.new()
	ssd_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ssd_stack.add_theme_constant_override("separation", 8)
	scroll.add_child(ssd_stack)


## One SSD per ship in the current engagement (both sides), rebuilt per game.
func _build_ssd_panels() -> void:
	for c in ssd_stack.get_children():
		ssd_stack.remove_child(c)
		c.queue_free()
	panels = []
	for s in engine.ships:
		var p := SSDPanel.new()
		ssd_stack.add_child(p)
		p.set_ship(s)
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
	roster_bar.visible = ph == DemoPhase.ALLOCATE or ph == DemoPhase.PLOT or ph == DemoPhase.FIRE
	alloc_bar.visible = ph == DemoPhase.ALLOCATE
	plot_bar.visible = ph == DemoPhase.PLOT
	fire_bar.visible = ph == DemoPhase.FIRE


# ---------------------------------------------------------------------------
# Game setup / turn flow
# ---------------------------------------------------------------------------

func _new_game() -> void:
	var e := TurnEngine.new()
	# A fixed 2-v-2: your squadron (Scout + One-Man Flyer) against the AI's
	# (Cruiser + Battleship). Placed nose-to-nose, no overlap (the engine nudges
	# any clash off the stack anyway).
	e.setup_fleet([
		{ "ship_id": &"helium_scout", "side": PLAYER_SIDE, "hex": Vector2i(20, 10), "facing": 1 },
		{ "ship_id": &"one_man_flyer", "side": PLAYER_SIDE, "hex": Vector2i(20, 12), "facing": 1 },
		{ "ship_id": &"zodanga_cruiser", "side": AI_SIDE, "hex": Vector2i(32, 4), "facing": 4 },
		{ "ship_id": &"helium_battleship", "side": AI_SIDE, "hex": Vector2i(32, 6), "facing": 4 },
	], int(Time.get_unix_time_from_system()))
	_bind_engine(e)
	_alloc = {}
	_alloc_initialized = false
	_plot_base = {}
	_fire_targets = {}
	_fire_choice = {}
	log_box.clear()
	log_box.append_text("Engagement over the dead sea bottom. You command the blue squadron.\n")
	_enter_allocate()


## Adopt `e` as the live engine: wire its signals, build an AI for every enemy
## hull, point the map and SSD panels at it. Shared by new-game and load — a
## fresh TurnEngine object each time, so no signal is ever double-connected.
func _bind_engine(e: TurnEngine) -> void:
	if game_over_overlay != null:
		game_over_overlay.visible = false
	engine = e
	ais = {}
	for s in engine.ships:
		if s.side == AI_SIDE:
			ais[s] = ShipAI.for_ship(s.def)
	engine.shot_resolved.connect(_on_shot)
	engine.damage_control_repaired.connect(_on_repair)
	engine.fire_changed.connect(_on_fire)
	engine.game_over.connect(_on_game_over)
	map.set_engine(engine)
	map.clear_highlights()
	map.clear_effects()
	map.set_fire_targets([])
	_build_ssd_panels()


func _players() -> Array[ShipState]:
	return engine.living_ships(PLAYER_SIDE)


## Nearest living enemy of `s` (mirrors ShipAI's own target pick). Null if its
## whole opposing side is out of action.
func _nearest_enemy(s: ShipState) -> ShipState:
	var best: ShipState = null
	var best_d := 1 << 30
	for o in engine.ships:
		if o.side == s.side or engine.is_out_of_action(o):
			continue
		var d := HexMath.distance(s.hex, o.hex)
		if d < best_d:
			best_d = d
			best = o
	return best


func _ship_at(hex: Vector2i) -> ShipState:
	for s in engine.ships:
		if s.hex == hex and not engine.is_out_of_action(s):
			return s
	return null


# --- Save / load -----------------------------------------------------------

func _on_save() -> void:
	if engine == null:
		return
	var err := SaveGame.save_to_file(engine, SAVE_PATH)
	if err == OK:
		log_box.append_text("[Saved — turn %d]\n" % engine.turn_number)
	else:
		log_box.append_text("[Save failed: error %d]\n" % err)


## Restore the saved engine and resume at the start of that turn's allocation.
## A save can be taken at any point in a turn; on load we re-open ALLOCATE (the
## clean per-turn entry point) with each ship's saved crew plan carried forward.
func _on_load() -> void:
	var loaded := SaveGame.load_from_file(SAVE_PATH)
	if loaded == null:
		log_box.append_text("[No save to load]\n")
		return
	_bind_engine(loaded)
	_alloc = {}
	_plot_base = {}
	_fire_targets = {}
	_fire_choice = {}
	for ps in _players():
		var pa := ps.allocation
		_alloc[ps] = {
			"guns": (pa.get("guns", []) as Array).duplicate(),
			"engine": int(pa.get("engine", 0)),
			"dc": int(pa.get("damage_control", 0)),
			"lookout": int(pa.get("lookout", 0)),
			"committed": false,
		}
	_alloc_initialized = true
	log_box.append_text("[Loaded — turn %d]\n" % engine.turn_number)
	_enter_allocate()


func _on_quit_to_menu() -> void:
	get_tree().change_scene_to_file("res://ui/main_menu.tscn")


# ---------------------------------------------------------------------------
# Roster strip
# ---------------------------------------------------------------------------

## Rebuild the per-ship selector for the current phase. Each button selects that
## ship as active; the active one is marked, and ALLOCATE shows a commit tick.
func _rebuild_roster() -> void:
	for c in roster_bar.get_children():
		roster_bar.remove_child(c)
		c.queue_free()
	var title := Label.new()
	title.text = "Your ships:"
	roster_bar.add_child(title)
	for ps in _players():
		var b := Button.new()
		b.text = _roster_label(ps)
		if ps == _active:
			b.add_theme_color_override("font_color", Color(0.95, 0.75, 0.15))
		var target := ps
		b.pressed.connect(func() -> void: _select_ship(target))
		roster_bar.add_child(b)


func _roster_label(ps: ShipState) -> String:
	var disp := ps.def.display_name
	var mark := "> " if ps == _active else "  "
	match phase:
		DemoPhase.ALLOCATE:
			var done := _alloc.has(ps) and bool(_alloc[ps].get("committed", false))
			return "%s%s %s" % [mark, disp, "[ready]" if done else ""]
		DemoPhase.PLOT:
			return "%s%s (spd %d)" % [mark, disp, ps.speed]
		DemoPhase.FIRE:
			return "%s%s (%d guns)" % [mark, disp, _fire_choice.get(ps, []).size()]
		_:
			return disp


## Switch which of the player's ships the phase bar edits.
func _select_ship(s: ShipState) -> void:
	if s == null or engine.is_out_of_action(s):
		return
	_active = s
	map.set_active_ship(s)
	match phase:
		DemoPhase.ALLOCATE:
			_load_active_alloc()
		DemoPhase.PLOT:
			_update_speed_label()
		DemoPhase.FIRE:
			_rebuild_fire_bar()
			_update_fire_markers()
	_rebuild_roster()


# --- ALLOCATE --------------------------------------------------------------

func _enter_allocate() -> void:
	phase = DemoPhase.ALLOCATE
	map.clear_highlights()
	map.set_fire_targets([])
	# Every AI ship allocates itself.
	for es in engine.living_ships(AI_SIDE):
		ais[es].allocate(engine, es)
	# Build each player ship's working plan: prefill on the first turn, otherwise
	# carry last turn's plan forward (re-validated against losses).
	for ps in _players():
		if _alloc_initialized and _alloc.has(ps):
			_alloc[ps] = _revalidate_alloc(ps, _alloc[ps])
		else:
			_alloc[ps] = _prefill_alloc(ps)
	_alloc_initialized = true
	_active = _players()[0]
	map.set_active_ship(_active)
	_load_active_alloc()
	_rebuild_roster()
	_show_bar(DemoPhase.ALLOCATE)
	phase_label.text = "Allocation — set each ship's crew, commit it, then Begin Plot"


## Sensible default: reserve engine crew for a cruising speed (never a stall),
## man every gun the rest can afford, leftover to damage control.
func _prefill_alloc(p: ShipState) -> Dictionary:
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
	return { "guns": picks, "engine": eng, "dc": left, "lookout": 0, "committed": false }


## Carry a ship's plan forward, dropping only what's no longer possible: guns
## since knocked out, engine crew above this turn's ceiling, and — if casualties
## shrank the pool — load shed (lookout, then DC, then guns, then engine).
func _revalidate_alloc(p: ShipState, prev: Dictionary) -> Dictionary:
	var pool := p.crew_pool()
	var picks: Array[int] = []
	for i in (prev["guns"] as Array):
		if int(i) < p.def.gun_mounts.size() and not p.gun_states[int(i)]["destroyed"]:
			picks.append(int(i))
	var max_eng: int = mini(p.engine_crew_for_speed(p.effective_max_speed()), pool)
	var eng := clampi(int(prev["engine"]), 0, max_eng)
	var dc := maxi(int(prev["dc"]), 0)
	var lk := maxi(int(prev["lookout"]), 0)
	while _plan_cost(p, picks, eng, dc, lk) > pool and lk > 0:
		lk -= 1
	while _plan_cost(p, picks, eng, dc, lk) > pool and dc > 0:
		dc -= 1
	while _plan_cost(p, picks, eng, dc, lk) > pool and not picks.is_empty():
		picks.pop_back()
	while _plan_cost(p, picks, eng, dc, lk) > pool and eng > 0:
		eng -= 1
	return { "guns": picks, "engine": eng, "dc": dc, "lookout": lk, "committed": false }


func _plan_cost(p: ShipState, picks: Array, eng: int, dc: int, lk: int) -> int:
	var g := 0
	for i in picks:
		g += ShipLibrary.gun(p.def.gun_mounts[int(i)]["gun_id"]).crew_required
	return g + eng + dc + lk


## Load the active ship's stored plan into the steppers and rebuild its bar.
func _load_active_alloc() -> void:
	var st: Dictionary = _alloc[_active]
	engine_value = int(st["engine"])
	dc_value = int(st["dc"])
	lookout_value = int(st["lookout"])
	_rebuild_alloc_bar()
	_refresh_alloc_display()


func _rebuild_alloc_bar() -> void:
	# queue_free() is deferred — detach now so the budget reads only fresh rows.
	for c in alloc_bar.get_children():
		alloc_bar.remove_child(c)
		c.queue_free()
	var p := _active
	var picked: Array = _alloc[p]["guns"]

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
		cb.button_pressed = i in picked
		cb.set_meta("mount", i)
		cb.toggled.connect(func(_on: bool) -> void: _edit_alloc())
		guns_row.add_child(cb)

	# Row 2: engine/DC/lookout steppers, budget label, commit + proceed.
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
	confirm_btn = _add_button(ctrl_row, "Commit Ship", _commit_active_alloc)
	alloc_proceed_btn = _add_button(ctrl_row, "Begin Plot", _begin_plot)


func _eng(delta: int) -> void:
	engine_value += delta
	_edit_alloc()


func _dc(delta: int) -> void:
	dc_value += delta
	_edit_alloc()


func _lookout(delta: int) -> void:
	lookout_value += delta
	_edit_alloc()


func _has_dust() -> bool:
	if engine == null:
		return false
	for t in engine.terrain.values():
		if int(t) == TerrainDef.Type.DUST_STORM:
			return true
	return false


## A user edit to the active ship's plan: store it (clearing its commit), then
## refresh the budget readout and the roster's ready-marks.
func _edit_alloc() -> void:
	var p := _active
	var guns := _checked_mounts(alloc_guns_row)
	var pool := p.crew_pool()
	var max_eng: int = mini(p.engine_crew_for_speed(p.effective_max_speed()), pool)
	engine_value = clampi(engine_value, 0, max_eng)
	dc_value = clampi(dc_value, 0, pool)
	lookout_value = clampi(lookout_value, 0, pool)
	var typed_guns: Array[int] = []
	typed_guns.assign(guns)
	_alloc[p] = { "guns": typed_guns, "engine": engine_value, "dc": dc_value,
			"lookout": lookout_value, "committed": false }
	_refresh_alloc_display()
	_rebuild_roster()


## Recompute the active ship's crew budget, update labels, gate the buttons.
## Does NOT alter commit state (so selecting a committed ship keeps it ready).
func _refresh_alloc_display() -> void:
	var p := _active
	var st: Dictionary = _alloc[p]
	var pool := p.crew_pool()
	var rate: int = p.def.speed_per_engine_crew
	var used := _plan_cost(p, st["guns"], int(st["engine"]), int(st["dc"]), int(st["lookout"]))
	engine_label.text = str(engine_value)
	dc_label.text = str(dc_value)
	if lookout_label != null:
		lookout_label.text = str(lookout_value)
	var cap: int = mini(p.effective_max_speed(), engine_value * rate)
	crew_label.text = "   CREW %d / %d   (top speed %d)   " % [used, pool, cap]
	crew_label.modulate = Color(0.85, 0.3, 0.2) if used > pool else Color.WHITE
	confirm_btn.disabled = used > pool
	alloc_proceed_btn.disabled = not _all_alloc_committed()


## Commit the active ship's plan (must fit budget), then jump to the next ship
## still needing crew, or just refresh once every ship is ready.
func _commit_active_alloc() -> void:
	var p := _active
	var st: Dictionary = _alloc[p]
	if _plan_cost(p, st["guns"], int(st["engine"]), int(st["dc"]), int(st["lookout"])) > p.crew_pool():
		return
	st["committed"] = true
	_alloc[p] = st
	var next := _next_uncommitted_player()
	if next != null:
		_select_ship(next)
	else:
		_refresh_alloc_display()
		_rebuild_roster()


func _next_uncommitted_player() -> ShipState:
	for ps in _players():
		if not bool(_alloc.get(ps, {}).get("committed", false)):
			return ps
	return null


func _all_alloc_committed() -> bool:
	for ps in _players():
		if not bool(_alloc.get(ps, {}).get("committed", false)):
			return false
	return true


## Leave ALLOCATE: apply every player ship's committed plan, then enter PLOT.
func _begin_plot() -> void:
	if not _all_alloc_committed():
		return
	for ps in _players():
		var st: Dictionary = _alloc[ps]
		ps.apply_allocation({ "guns": st["guns"], "engine": int(st["engine"]),
				"damage_control": int(st["dc"]), "lookout": int(st["lookout"]) })
		# A speed plotted last turn may now exceed this turn's crew-gated cap.
		ps.speed = mini(ps.speed, ps.usable_max_speed())
	_refresh_panels()
	_enter_plot()


# --- PLOT ------------------------------------------------------------------

func _enter_plot() -> void:
	phase = DemoPhase.PLOT
	for es in engine.living_ships(AI_SIDE):
		ais[es].plot(engine, es)
	for ps in _players():
		_plot_base[ps] = ps.speed
	_active = _players()[0]
	map.set_active_ship(_active)
	_rebuild_roster()
	_show_bar(DemoPhase.PLOT)
	phase_label.text = "Plot — set each flyer's speed, then Begin Movement"
	_update_speed_label()


## This turn's plottable speed range for the active ship: bounded by propeller
## acceleration (±max_speed_change from last turn) and the crew-gated top speed.
func _plot_speed_bounds() -> Vector2i:
	var p := _active
	var base: int = int(_plot_base.get(p, p.speed))
	var dv := p.max_speed_change()
	var lo: int = maxi(base - dv, 0)
	var hi: int = mini(base + dv, p.usable_max_speed())
	return Vector2i(lo, hi)


func _on_speed(delta: int) -> void:
	if phase != DemoPhase.PLOT:
		return
	var p := _active
	var b := _plot_speed_bounds()
	p.speed = clampi(p.speed + delta, b.x, b.y)
	_update_speed_label()
	_rebuild_roster()


func _update_speed_label() -> void:
	var p := _active
	var b := _plot_speed_bounds()
	speed_label.text = "  %s — Speed %d   (top %d, accel +/-%d)  " % [
			p.def.display_name, p.speed, p.usable_max_speed(), p.max_speed_change()]
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


## Walks the engine's shared impulse sequencer, pausing only when one of the
## player's ships must click a move. The engine counts impulses and hands back
## each mover (yours or the AI's); this loop executes the AI's and hands off yours.
func _advance_movement() -> void:
	while true:
		var s := engine.next_mover()
		if s == null:
			_enter_fire()
			return
		var moves := engine.legal_moves_for(s)   # already collision/bounds filtered
		if moves.is_empty():
			continue   # boxed in or hard against the map edge: holds this impulse
		if s.side == PLAYER_SIDE:
			_active = s
			map.set_highlights(moves, s)
			phase_label.text = "Movement — impulse %d / 8: move the %s (click a green hex)" % [
					engine.current_impulse, s.def.display_name]
			return     # wait for the click
		engine.execute_move(s, ais[s].choose_move(engine, s, moves))
		map.queue_redraw()


func _on_move_clicked(move: Dictionary) -> void:
	if phase != DemoPhase.MOVE or _active == null:
		return
	engine.execute_move(_active, move)
	map.clear_highlights()
	_advance_movement()


# --- FIRE ------------------------------------------------------------------

func _enter_fire() -> void:
	phase = DemoPhase.FIRE
	map.clear_highlights()
	_fire_targets = {}
	_fire_choice = {}
	for ps in _players():
		_build_fire_defaults(ps)
	_active = _players()[0]
	map.set_active_ship(_active)
	_rebuild_roster()
	_rebuild_fire_bar()
	_update_fire_markers()
	_show_bar(DemoPhase.FIRE)
	phase_label.text = "Fire — each ship's guns target an enemy (click a foe to retarget); Resolve"


## Default each of a ship's mounts to the nearest enemy it bears on (else the
## nearest enemy at all, so the gun still shows a reason). Deck guns default ON,
## torpedoes OFF (spending one is a deliberate call).
func _build_fire_defaults(ps: ShipState) -> void:
	var targets: Dictionary = {}
	var choice: Array[int] = []
	for i in ps.def.gun_mounts.size():
		var tgt := _best_target_for_mount(ps, i)
		if tgt == null:
			continue
		targets[i] = tgt
		var pv := ps.fire_preview(i, tgt.hex, engine.terrain)
		if pv["bears"] and not pv["is_torpedo"]:
			choice.append(i)
	_fire_targets[ps] = targets
	_fire_choice[ps] = choice


func _best_target_for_mount(ps: ShipState, mount: int) -> ShipState:
	var enemies := engine.living_ships(AI_SIDE)
	if enemies.is_empty():
		return null
	var bearing_best: ShipState = null
	var bearing_d := 1 << 30
	var nearest: ShipState = null
	var nearest_d := 1 << 30
	for e in enemies:
		var d := HexMath.distance(ps.hex, e.hex)
		if d < nearest_d:
			nearest_d = d
			nearest = e
		var pv := ps.fire_preview(mount, e.hex, engine.terrain)
		if pv["bears"] and d < bearing_d:
			bearing_d = d
			bearing_best = e
	return bearing_best if bearing_best != null else nearest


## Builds a toggle per bearing gun (with its shot preview against its current
## target) and a greyed line per gun that can't fire (with the reason).
func _rebuild_fire_bar() -> void:
	for c in fire_bar.get_children():
		fire_bar.remove_child(c)   # detach now; queue_free is deferred a frame
		c.queue_free()
	var p := _active
	var targets: Dictionary = _fire_targets.get(p, {})
	var choice: Array = _fire_choice.get(p, [])
	var title := Label.new()
	title.text = "%s guns:" % p.def.display_name
	fire_bar.add_child(title)
	for i in p.def.gun_mounts.size():
		var label := str(p.def.gun_mounts[i]["label"])
		var tgt: ShipState = targets.get(i, null)
		if tgt == null:
			var nl := Label.new()
			nl.text = "%s [no target]" % label
			nl.modulate = Color(0.6, 0.6, 0.6)
			fire_bar.add_child(nl)
			continue
		var pv := p.fire_preview(i, tgt.hex, engine.terrain)
		var tname := tgt.def.display_name
		if pv["bears"]:
			var cb := CheckBox.new()
			var dust_tag := ""
			if int(pv.get("dust_penalty", 0)) > 0:
				dust_tag = " [dust+%d]" % int(pv["dust_penalty"])
			cb.text = "%s -> %s  rng %d  %d+ -> %d%s" % [
					label, tname, pv["range"], pv["to_hit"], pv["damage"], dust_tag]
			if pv["is_torpedo"]:
				cb.text += "  AP%d  [%d left]" % [pv["armor_piercing"], pv["ammo"]]
			cb.button_pressed = i in choice
			cb.set_meta("mount", i)
			cb.toggled.connect(func(_on: bool) -> void: _on_fire_toggled())
			fire_bar.add_child(cb)
		else:
			var dl := Label.new()
			dl.text = "%s -> %s [%s]" % [label, tname, str(pv["reason"])]
			dl.modulate = Color(0.6, 0.6, 0.6)
			fire_bar.add_child(dl)
	_add_button(fire_bar, "Resolve Fire", _on_resolve_fire)


func _on_fire_toggled() -> void:
	var typed: Array[int] = []
	typed.assign(_checked_mounts(fire_bar))
	_fire_choice[_active] = typed
	_update_fire_markers()
	_rebuild_roster()


## Point every bearing mount of the active ship at the clicked enemy.
func _retarget_active(enemy: ShipState) -> void:
	var p := _active
	var targets: Dictionary = _fire_targets.get(p, {})
	for i in p.def.gun_mounts.size():
		if p.fire_preview(i, enemy.hex, engine.terrain)["bears"]:
			targets[i] = enemy
	_fire_targets[p] = targets
	log_box.append_text("%s shifts fire to the %s\n" % [p.def.display_name, enemy.def.display_name])
	_rebuild_fire_bar()
	_update_fire_markers()


## Draw a reticle on every enemy the active ship's chosen guns are aimed at.
func _update_fire_markers() -> void:
	var targets: Dictionary = _fire_targets.get(_active, {})
	var hexes: Array[Vector2i] = []
	for i in (_fire_choice.get(_active, []) as Array):
		if targets.has(int(i)):
			var h: Vector2i = (targets[int(i)] as ShipState).hex
			if not h in hexes:
				hexes.append(h)
	map.set_fire_targets(hexes)


func _on_resolve_fire() -> void:
	if phase != DemoPhase.FIRE:
		return
	# Every player ship fires its chosen mounts at their per-mount targets...
	for ps in _players():
		var targets: Dictionary = _fire_targets.get(ps, {})
		for i in (_fire_choice.get(ps, []) as Array):
			var tgt: ShipState = targets.get(int(i), null)
			if tgt != null and not engine.is_out_of_action(tgt):
				engine.declare_fire(ps, int(i), tgt)
	# ...and every AI ship fires everything bearing at its nearest enemy.
	for es in engine.living_ships(AI_SIDE):
		var enemy := _nearest_enemy(es)
		if enemy == null:
			continue
		for mi in ais[es].choose_fire(es, enemy, engine.terrain):
			engine.declare_fire(es, mi, enemy)
	map.set_fire_targets([])
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
# Input routing / feedback
# ---------------------------------------------------------------------------

## A bare hex click (not a move highlight): in ALLOCATE/PLOT/FIRE, clicking one
## of your ships selects it; in FIRE, clicking an enemy retargets the active ship.
func _on_hex_clicked(hex: Vector2i) -> void:
	var s := _ship_at(hex)
	if s == null:
		return
	if s.side == PLAYER_SIDE and (phase == DemoPhase.ALLOCATE
			or phase == DemoPhase.PLOT or phase == DemoPhase.FIRE):
		_select_ship(s)
	elif s.side == AI_SIDE and phase == DemoPhase.FIRE:
		_retarget_active(s)


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
	_refresh_panels()


func _on_fire(ship: ShipState, fires: int, note: String) -> void:
	log_box.append_text("%s: %s (%d burning)\n" % [ship.def.display_name, note, fires])
	_refresh_panels()


func _on_shot(r: Dictionary) -> void:
	_play_shot_effects(r)
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


## Map tracers, hit flashes, and SFX for one resolved shot (or an internal-fire
## burn, which has no firer hex — just a small flash, no tracer/report sound).
func _play_shot_effects(r: Dictionary) -> void:
	var from: Vector2i = r.get("firer_hex", Vector2i.ZERO)
	var to: Vector2i = r.get("target_hex", Vector2i.ZERO)
	var is_fire_burn: bool = r.get("fire", false)
	if r.get("los_blocked", false):
		return
	if not is_fire_burn:
		map.add_tracer(from, to, r.get("is_torpedo", false))
		sound.play("fire", -4.0)
	if r.get("hit", false):
		var killed: bool = r.get("destroyed_target", false)
		map.add_flash(to, killed)
		sound.play("explosion" if killed else "hit", -2.0 if killed else -6.0)


func _on_game_over(side: int, reason: String) -> void:
	phase = DemoPhase.OVER
	_show_bar(DemoPhase.OVER)
	map.clear_highlights()
	map.set_fire_targets([])
	# A final burst over each downed flyer — and the only map effect for a
	# grounding (a destruction already flashed via _on_shot).
	for s in engine.ships:
		if s.is_destroyed or s.grounded:
			map.add_flash(s.hex, true)
	sound.play("explosion")

	if side == -1:
		game_over_title.text = "STALEMATE"
		game_over_detail.text = "Both squadrons are swept from the sky — turn %d\n%s" % [
				engine.turn_number, reason]
	elif side == PLAYER_SIDE:
		game_over_title.text = "VICTORY"
		game_over_detail.text = "Your squadron holds the sky — turn %d\n%s" % [
				engine.turn_number, reason]
	else:
		game_over_title.text = "DEFEAT"
		game_over_detail.text = "Your squadron is broken — turn %d\n%s" % [
				engine.turn_number, reason]

	game_over_overlay.visible = true
	log_box.append_text("\n*** %s ***\n" % reason)
	phase_label.text = "Game over — turn %d" % engine.turn_number
