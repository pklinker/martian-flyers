extends SceneTree
## Headless test runner for the Barsoom rules engine.
##
## Run from the project root:
##   godot --headless --path . -s res://tests/test_rules.gd
##
## Exit code 0 = all tests passed, 1 = failures (CI-friendly).
## Tests reach into underscore-prefixed methods where determinism requires it;
## that's deliberate — they're tests, not clients.

var _passed := 0
var _failed := 0
var _current_suite := ""


func _init() -> void:
	_suite("HexMath")
	_test_distance()
	_test_neighbors_and_bearing()
	_test_relative_bearing_and_struck_facing()

	_suite("Impulse chart")
	_test_impulse_chart()

	_suite("Movement / turn mode")
	_test_turn_mode_and_legal_moves()
	_test_map_bounds()
	_test_impulse_sequencer()

	_suite("Guns")
	_test_range_brackets()
	_test_guns_bearing()
	_test_guns_bearing_from()
	_test_fire_preview()
	_test_engine_crew_speed_gate()
	_test_reload_and_crew_allocation()

	_suite("Damage")
	_test_armor_absorption()
	_test_dac_determinism()
	_test_magazine_explosion()

	_suite("Torpedoes")
	_test_torpedo_armor_piercing()
	_test_torpedo_ammo_and_gating()

	_suite("Buoyancy")
	_test_buoyancy_grounding()
	_test_damage_control_feedback()
	_test_damage_control_claws_back()

	_suite("Capability erosion")
	_test_derived_capabilities()

	_suite("Terrain")
	_test_hex_line()
	_test_terrain_los()
	_test_terrain_dust()
	_test_terrain_fire_preview()

	_suite("Listing")
	_test_listing()

	_suite("Critical hits")
	_test_steering_jam()
	_test_fire_ignite_and_burn()
	_test_fire_doused()
	_test_officer_casualties()
	_test_damage_control_capacity()

	_suite("Ship classes")
	_test_new_ship_classes()
	_test_new_class_battles()

	_suite("Fleets")
	_test_fleet_setup()
	_test_catalog_migration()
	_test_ship_loadouts()
	_test_one_man_pilot_loss()
	_test_rebalance_crew_budget()
	_test_catalog_validation()
	_test_catalog_mods()
	_test_save_missing_dependency()
	_test_deployment_rules()
	_test_side_victory()
	_test_fleet_cadence()
	_test_fleet_ai_battle()

	_suite("Points-buy fleets")
	_test_point_cost()
	_test_fleet_builder()

	_suite("AI")
	_test_ai_evaluator()
	_test_ai_armor_awareness()
	_test_ai_battle()

	_suite("AI lookahead")
	_test_engine_clone()
	_test_lookahead_value_function()
	_test_lookahead_plot_choice()
	_test_lookahead_battle()
	_test_difficulty_presets()

	_suite("Save / load")
	_test_save_roundtrip()
	_test_save_rng_determinism()
	_test_save_file_and_rejects()

	_suite("View projection")
	_test_view_projection()
	_test_model_baker()
	_test_dust_sprites()

	_suite("Smoke battle")
	_test_full_battle()

	print("\n========================================")
	print("  %d passed, %d failed" % [_passed, _failed])
	print("========================================")
	quit(1 if _failed > 0 else 0)


# ---------------------------------------------------------------------------
# View projection (HexMapView overhead ⇄ isometric transform)
# ---------------------------------------------------------------------------

## The map's pixel<->hex transform must be invertible on the ground plane in every
## view it offers: flat overhead (where it must also match the original flat formula
## exactly) and isometric at all six snapped field orientations. Picking depends on it.
func _test_view_projection() -> void:
	var view := HexMapView.new()
	view.hex_size = 34.0
	view._origin = Vector2(640.0, 400.0)
	var hexes: Array[Vector2i] = [Vector2i(0, 0), Vector2i(3, -1), Vector2i(10, 4),
			Vector2i(23, 11), Vector2i(5, -3), Vector2i(18, 2)]

	# Overhead: numerically identical to the legacy flat hex_to_pixel, and round-trips.
	view._theta = 0.0
	view._tilt = 1.0
	view._height_scale = 0.0
	var overhead_ok := true
	var overhead_rt := true
	for h in hexes:
		var legacy := view._origin + HexMath.to_cartesian(h) * view.hex_size
		if view.hex_to_pixel(h).distance_to(legacy) > 0.001:
			overhead_ok = false
		if view.pixel_to_hex(view.hex_to_pixel(h)) != h:
			overhead_rt = false
	_check(overhead_ok, "overhead projection matches the legacy flat formula")
	_check(overhead_rt, "overhead ground picking round-trips")

	# Rotated overhead (flat, no tilt/height) — rotation is allowed in top-down too,
	# so picking must round-trip at every orientation there as well.
	for o in 6:
		view._theta = o * (TAU / 6.0)
		var rt_flat := true
		for h in hexes:
			if view.pixel_to_hex(view.hex_to_pixel(h)) != h:
				rt_flat = false
		_check(rt_flat, "rotated overhead ground picking round-trips at orientation %d" % o)

	# Isometric at each of the six snapped orientations: ground picking still round-trips.
	view._tilt = HexMapView.ISO_TILT
	view._height_scale = HexMapView.ISO_HEIGHT
	for o in 6:
		view._theta = o * (TAU / 6.0)
		var rt := true
		for h in hexes:
			if view.pixel_to_hex(view.hex_to_pixel(h)) != h:
				rt = false
		_check(rt, "isometric ground picking round-trips at orientation %d" % o)
	view.free()


## The 3D terrain-model baker is optional: has_model() must agree with whatever .glb
## assets are actually present (so the map blits a model where one exists and falls back
## to the procedural prism where none does), and its rotation bucketing must snap a field
## angle to the nearest cache slot. A hill model ships in assets/terrain/; towers don't.
func _test_model_baker() -> void:
	var tm := ModelBaker.new()
	tm.scan_assets()
	# Self-consistency: a type reports a model exactly when it loaded >= 1 variant.
	for type in [TerrainDef.Type.HILL, TerrainDef.Type.TOWER]:
		_check(tm.has_model(type) == (tm.variant_count(type) > 0),
				"has_model agrees with variant_count for type %d" % type)
	# Shipped assets load: a hill (assets/terrain/), a tower building (assets/buildings/),
	# and the three ship classes (assets/ships/). Classes without a model fall back.
	_check(tm.has_model(TerrainDef.Type.HILL), "shipped hill model is loaded")
	_check(tm.variant_count(TerrainDef.Type.HILL) >= 1, "at least one hill variant present")
	_check(tm.has_model(TerrainDef.Type.TOWER), "shipped tower building model is loaded")
	_check(tm.has_model(&"scout"), "scout ship model is loaded")
	_check(tm.has_model(&"cruiser"), "cruiser ship model is loaded")
	_check(tm.has_model(&"fighter"), "fighter ship model is loaded")
	_check(not tm.has_model(&"battleship"), "battleship has no model → token fallback")

	# Angle bucketing: 24 slots of 15°, nearest-rounded and wrapping.
	var n: int = ModelBaker.AZIMUTH_BUCKETS
	_check(tm.angle_bucket(0.0) == 0, "bucket of 0 rad is 0")
	_check(tm.angle_bucket(deg_to_rad(7.0)) == 0, "7° rounds down to bucket 0")
	_check(tm.angle_bucket(deg_to_rad(8.0)) == 1, "8° rounds up to bucket 1")
	_check(tm.angle_bucket(deg_to_rad(358.0)) == 0, "358° wraps to bucket 0")
	_check(tm.angle_bucket(TAU) == 0, "a full turn wraps to bucket 0")
	_check(tm.angle_bucket(-deg_to_rad(8.0)) == posmod(-1, n), "negative angle wraps correctly")
	tm.free()


## Authored dust-storm sheets are optional: a fresh (unscanned) loader reports nothing
## so the map draws the procedural puffs, the shipped sheet in assets/terrain/ loads, and
## the frame clock + atlas math must loop on frame count and map indices to grid cells.
func _test_dust_sprites() -> void:
	# Empty loader (never scanned) → procedural fallback path.
	var empty := DustSprites.new()
	_check(not empty.has_sprites(), "unscanned loader has no sprites → procedural fallback")
	_check(empty.variant_count() == 0, "variant_count is 0 before scanning")

	# Scanned loader picks up the shipped duststorm_1 sheet.
	var ds := DustSprites.new()
	ds.scan_assets()
	_check(ds.has_sprites(), "shipped dust sheet is loaded")
	_check(ds.variant_count() >= 1, "at least one dust variant present")

	# Pure playback math on a synthetic 5×5, 24-frame sheet (appended past any real ones).
	var v := ds.variant_count()
	ds._variants.append({"cols": 5, "rows": 5, "frames": 24, "frame_size": 128, "fps": 24.0})
	_check(ds.frame_for_time(v, 0.0) == 0, "t=0 → frame 0")
	_check(ds.frame_for_time(v, 0.5) == 12, "0.5s at 24fps → frame 12")
	_check(ds.frame_for_time(v, 1.0) == 0, "24 frames at 24fps loop back to 0 after 1s")
	_check(ds.frame_region(v, 6) == Rect2(128, 128, 128, 128), "frame 6 maps to grid cell (1,1)")


# ---------------------------------------------------------------------------
# Tiny assert framework
# ---------------------------------------------------------------------------

func _suite(name: String) -> void:
	_current_suite = name
	print("\n--- %s ---" % name)

func _check(cond: bool, name: String) -> void:
	if cond:
		_passed += 1
		print("  PASS  %s" % name)
	else:
		_failed += 1
		print("  FAIL  %s" % name)

func _check_eq(actual, expected, name: String) -> void:
	if actual == expected:
		_passed += 1
		print("  PASS  %s" % name)
	else:
		_failed += 1
		print("  FAIL  %s  (expected %s, got %s)" % [name, str(expected), str(actual)])


# ---------------------------------------------------------------------------
# HexMath
# ---------------------------------------------------------------------------

func _test_distance() -> void:
	_check_eq(HexMath.distance(Vector2i(0, 0), Vector2i(0, 0)), 0, "distance to self is 0")
	_check_eq(HexMath.distance(Vector2i(0, 0), Vector2i(0, -3)), 3, "straight north distance")
	_check_eq(HexMath.distance(Vector2i(0, 0), Vector2i(3, -3)), 3, "diagonal NE distance")
	_check_eq(HexMath.distance(Vector2i(0, 0), Vector2i(3, 1)), 4, "mixed-axis distance")
	_check_eq(HexMath.distance(Vector2i(2, 10), Vector2i(14, 4)), 12, "starting-position distance")

func _test_neighbors_and_bearing() -> void:
	# Walking one hex in each facing, the bearing back-computed must match.
	var origin := Vector2i(5, 5)
	var ok := true
	for f in 6:
		var n := HexMath.neighbor(origin, f)
		if HexMath.bearing(origin, n) != f:
			ok = false
	_check(ok, "bearing(origin, neighbor(f)) == f for all six facings")
	_check_eq(HexMath.bearing(origin, origin), -1, "bearing to self is -1")
	# Long-range bearing snaps to nearest sector: 3 hexes N, 1 hex NE is still ~N.
	var target := origin + Vector2i(0, -3) + HexMath.DIRS[1]
	_check_eq(HexMath.bearing(origin, target), 0, "near-north target snaps to bearing 0")

func _test_relative_bearing_and_struck_facing() -> void:
	# Ship facing SE (2); a target due north of it is dead astern-port side:
	# absolute bearing 0, relative = (0 - 2 + 6) % 6 = 4 (aft-port).
	var rb := HexMath.relative_bearing(Vector2i(0, 0), 2, Vector2i(0, -4))
	_check_eq(rb, 4, "target due north of SE-facing ship is aft-port (4)")
	# Struck facing is symmetric: fire from due south hits a north-facing
	# ship's stern (3).
	var sf := HexMath.struck_facing(Vector2i(0, 0), 0, Vector2i(0, 6))
	_check_eq(sf, 3, "fire from astern strikes facing 3")


# ---------------------------------------------------------------------------
# Impulse chart
# ---------------------------------------------------------------------------

func _test_impulse_chart() -> void:
	# A ship at speed S must move exactly S times across 8 impulses.
	var ok := true
	for speed in range(0, 9):
		var moves := 0
		for imp in range(1, TurnEngine.IMPULSES_PER_TURN + 1):
			if TurnEngine.moves_on_impulse(speed, imp):
				moves += 1
		if moves != speed:
			ok = false
			print("    speed %d produced %d moves" % [speed, moves])
	_check(ok, "speed S yields exactly S moves per turn, S in 0..8")
	# Speed 4 should be evenly distributed: impulses 2, 4, 6, 8.
	var pattern: Array[int] = []
	for imp in range(1, 9):
		if TurnEngine.moves_on_impulse(4, imp):
			pattern.append(imp)
	_check_eq(pattern, [2, 4, 6, 8], "speed 4 moves on impulses 2/4/6/8")


# ---------------------------------------------------------------------------
# Movement / turn mode
# ---------------------------------------------------------------------------

func _test_turn_mode_and_legal_moves() -> void:
	var engine := TurnEngine.new()
	var ship := ShipState.create(ShipLibrary.ship(&"zodanga_cruiser"), 0, Vector2i(0, 0), 0)
	ship.speed = 4
	ship.straight_moved = 0
	# Cruiser turn mode at speed 4 is 3: fresh off a turn, only straight is legal.
	_check_eq(ship.turn_mode(), 3, "cruiser turn mode at speed 4 is 3")
	_check_eq(TurnEngine.legal_moves(ship).size(), 1, "cannot turn before satisfying turn mode")
	# Move straight three times; turning becomes legal.
	for _i in 3:
		engine.execute_move(ship, TurnEngine.legal_moves(ship)[0])
	_check_eq(TurnEngine.legal_moves(ship).size(), 3, "straight/port/starboard legal after turn mode met")
	# Execute a starboard turn; counter resets.
	var turn_move: Dictionary = {}
	for m in TurnEngine.legal_moves(ship):
		if m["kind"] == "starboard":
			turn_move = m
	engine.execute_move(ship, turn_move)
	_check_eq(ship.facing, 1, "starboard turn changes facing 0 -> 1")
	_check_eq(ship.straight_moved, 0, "turning resets straight-moved counter")
	# Grounded ships do not move.
	ship.grounded = true
	_check_eq(TurnEngine.legal_moves(ship).size(), 0, "grounded ship has no legal moves")
	# Collision blocking: an occupied hex is not a legal destination.
	ship.grounded = false
	ship.straight_moved = ship.turn_mode()  # make turning legal again
	var blocked: Array[Vector2i] = [HexMath.neighbor(ship.hex, ship.facing)]
	var moves_blocked := TurnEngine.legal_moves(ship, blocked)
	var contains_blocked := false
	for m in moves_blocked:
		if m["hex"] == blocked[0]:
			contains_blocked = true
	_check(not contains_blocked, "occupied hex is excluded from legal moves")
	_check_eq(moves_blocked.size(), 2, "straight blocked: only the two turns remain")


func _test_map_bounds() -> void:
	# The playfield is an engine rule now (legal_moves_for drops off-field moves),
	# not a UI filter.
	var engine := TurnEngine.new()
	engine.setup(1)
	_check(engine.map_contains(Vector2i(0, engine.map_row_offset(0))),
			"a corner hex is on the field")
	_check(not engine.map_contains(Vector2i(-1, 0)), "negative column is off the field")
	_check(not engine.map_contains(Vector2i(engine.map_cols, 0)),
			"column past the last is off the field")

	# A ship jammed into the top-left corner: some neighbours leave the board, so
	# the bounded move set must (a) keep every move on the field and (b) be a
	# strict subset of the raw set for at least one facing — proving the rule prunes.
	var ship := engine.ships[0]
	ship.hex = Vector2i(0, engine.map_row_offset(0))
	ship.speed = 4
	ship.straight_moved = 99   # turn mode satisfied: all three directions open
	var all_on_field := true
	var pruned_somewhere := false
	for f in 6:
		ship.facing = f
		var bounded := engine.legal_moves_for(ship)
		for m in bounded:
			if not engine.map_contains(m["hex"]):
				all_on_field = false
		if bounded.size() < TurnEngine.legal_moves(ship).size():
			pruned_somewhere = true
	_check(all_on_field, "no legal move ever leaves the playfield")
	_check(pruned_somewhere, "engine bounds prune off-field moves at a corner")


func _test_impulse_sequencer() -> void:
	# begin_movement()/next_mover() is the engine-owned cadence every client
	# shares. Pin speeds so the chart is predictable and walk the sequence.
	var engine := TurnEngine.new()
	engine.setup(12345)
	engine.ships[0].speed = 8   # moves on all 8 impulses
	engine.ships[1].speed = 4   # moves on 2, 4, 6, 8
	var impulses_seen: Array[int] = []
	engine.impulse_advanced.connect(
			func(imp: int, _movers: Array) -> void: impulses_seen.append(imp))
	engine.begin_movement()
	_check_eq(engine.phase, TurnEngine.Phase.MOVEMENT, "begin_movement enters MOVEMENT phase")
	var offered := { 0: 0, 1: 0 }
	while true:
		var s: ShipState = engine.next_mover()
		if s == null:
			break
		offered[s.side] += 1   # count cadence; don't actually move
	_check_eq(offered[0], 8, "speed-8 ship is offered a move on all 8 impulses")
	_check_eq(offered[1], 4, "speed-4 ship is offered a move on 4 impulses")
	_check_eq(impulses_seen, [1, 2, 3, 4, 5, 6, 7, 8],
			"impulse_advanced fires once per impulse, in order")
	_check(engine.next_mover() == null, "next_mover stays exhausted past the last impulse")


# ---------------------------------------------------------------------------
# Guns
# ---------------------------------------------------------------------------

func _test_range_brackets() -> void:
	var heavy := ShipLibrary.gun(&"heavy_gun")
	_check_eq(int(heavy.bracket_for_range(1)["damage"]), 7, "heavy gun point-blank damage")
	_check_eq(int(heavy.bracket_for_range(10)["damage"]), 5, "heavy gun mid-band damage")
	_check_eq(int(heavy.bracket_for_range(18)["to_hit"]), 5, "heavy gun long-band to-hit")
	_check(heavy.bracket_for_range(19).is_empty(), "beyond max range returns empty bracket")
	_check_eq(heavy.max_range(), 18, "heavy gun max range")

func _test_guns_bearing() -> void:
	# The cruiser keeps arc-limited mounts (bow/stern medium, port/stbd heavy), so
	# it's the fixture for bearing/arc mechanics now the scout carries a 360° turret.
	var cruiser := ShipState.create(ShipLibrary.ship(&"zodanga_cruiser"), 0, Vector2i(0, 0), 0)
	cruiser.apply_allocation({ "guns": [0, 1, 2, 3], "engine": 0, "damage_control": 0 })
	# Dead ahead: only the bow medium (arcs 5,0,1) bears.
	_check_eq(cruiser.guns_bearing(Vector2i(0, -2)), [0], "dead-ahead target: bow gun bears")
	# Dead astern: only the stern medium (arcs 2,3,4) bears.
	_check_eq(cruiser.guns_bearing(Vector2i(0, 2)), [3], "dead-astern target: stern gun bears")
	# Beyond the bow medium's reach (max 12), nothing bears dead ahead.
	_check_eq(cruiser.guns_bearing(Vector2i(0, -13)).size(), 0,
			"dead-ahead beyond bow range: no gun bears")
	# Unmanned guns never bear.
	cruiser.apply_allocation({ "guns": [], "engine": 0, "damage_control": 0 })
	_check_eq(cruiser.guns_bearing(Vector2i(0, -2)).size(), 0, "unmanned guns cannot fire")

func _test_guns_bearing_from() -> void:
	var cruiser := ShipState.create(ShipLibrary.ship(&"zodanga_cruiser"), 0, Vector2i(8, 8), 0)
	cruiser.apply_allocation({ "guns": [0, 1, 2, 3], "engine": 0, "damage_control": 0 })
	# From the real pose, the north target is dead ahead → bow gun bears.
	_check_eq(cruiser.guns_bearing(Vector2i(8, 5)), [0],
			"guns_bearing_from at own pose matches guns_bearing (bow)")
	# Re-evaluated as if facing SE (2): the north target falls aft-port (relative
	# bearing 4), into both the port heavy (4,5) and stern medium (2,3,4) arcs.
	_check_eq(cruiser.guns_bearing_from(Vector2i(8, 8), 2, Vector2i(8, 5)), [2, 3],
			"hypothetical facing changes which mounts bear (port + stern)")

func _test_fire_preview() -> void:
	var cruiser := ShipState.create(ShipLibrary.ship(&"zodanga_cruiser"), 0, Vector2i(0, 0), 0)
	cruiser.apply_allocation({ "guns": [0, 1, 2, 3], "engine": 0, "damage_control": 0 })
	# Bow medium at range 2 dead ahead: near bracket, 3+ to hit for 4 dmg.
	var p := cruiser.fire_preview(0, Vector2i(0, -2))
	_check(p["bears"], "bow gun bears dead ahead at range 2")
	_check_eq(p["range"], 2, "preview reports the range")
	_check_eq(p["to_hit"], 3, "near bracket to-hit is 3+")
	_check_eq(p["damage"], 4, "near bracket damage is 4")
	# Starboard heavy (arcs 1,2) cannot bear on a dead-ahead target.
	_check_eq(cruiser.fire_preview(1, Vector2i(0, -2))["reason"], "out of arc",
			"off-arc gun reports out of arc")
	# Bow medium past its max range (12): out of range.
	_check_eq(cruiser.fire_preview(0, Vector2i(0, -13))["reason"], "out of range",
			"medium gun beyond range 12 reports out of range")
	# Unmanned guns report unmanned, not a false bearing.
	cruiser.apply_allocation({ "guns": [], "engine": 0, "damage_control": 0 })
	_check_eq(cruiser.fire_preview(0, Vector2i(0, -2))["reason"], "unmanned",
			"unmanned gun reports unmanned")

func _test_engine_crew_speed_gate() -> void:
	# The cruiser has a crew-gated engine (15 crew per hex, box ceiling 6) — the
	# fixture for the engine economy now small ships fly on a free pilot's engine.
	var cruiser := ShipState.create(ShipLibrary.ship(&"zodanga_cruiser"), 0, Vector2i(0, 0), 0)
	_check_eq(cruiser.effective_max_speed(), 6, "cruiser engine-box ceiling is 6")
	_check_eq(cruiser.def.engine_crew_per_speed, 15, "cruiser costs 15 engine crew per hex")
	# No engine crew powering the radium engine: the ship can't make way.
	cruiser.apply_allocation({ "guns": [], "engine": 0, "damage_control": 0 })
	_check_eq(cruiser.usable_max_speed(), 0, "no engine crew: no way on")
	# 30 engine crew (15/hex) drive speed 2; partial crew floors down.
	cruiser.apply_allocation({ "guns": [], "engine": 30, "damage_control": 0 })
	_check_eq(cruiser.usable_max_speed(), 2, "30 engine crew drive speed 2 (15/hex)")
	cruiser.apply_allocation({ "guns": [], "engine": 44, "damage_control": 0 })
	_check_eq(cruiser.usable_max_speed(), 2, "extra crew below the next hex floors to 2")
	# The whole pool to the engine reaches — but cannot exceed — the box ceiling.
	cruiser.apply_allocation({ "guns": [], "engine": 120, "damage_control": 0 })
	_check_eq(cruiser.usable_max_speed(), 6, "full engine crew reaches the box ceiling (speed 6)")
	# Crew needed for a target speed is the per-hex cost times the target.
	_check_eq(cruiser.engine_crew_for_speed(6), 90, "speed 6 needs 90 engine crew")
	_check_eq(cruiser.engine_crew_for_speed(2), 30, "speed 2 needs 30 engine crew")
	# Damaged engine boxes lower the ceiling even with crew to spare.
	cruiser.systems_remaining[ShipDef.SystemType.ENGINE] = 3  # of 6 -> ceil(6*0.5)=3
	cruiser.apply_allocation({ "guns": [], "engine": 120, "damage_control": 0 })
	_check_eq(cruiser.usable_max_speed(), 3, "half engine boxes cap usable speed at 3 regardless of crew")

func _test_reload_and_crew_allocation() -> void:
	var cruiser := ShipState.create(ShipLibrary.ship(&"zodanga_cruiser"), 0, Vector2i(0, 0), 0)
	# Cruiser crew pool is 120; manning all four guns costs 6+14+14+6 = 40, leaving
	# 80 for the engine room. Exactly at pool is legal; one more crew is not.
	_check(cruiser.apply_allocation({ "guns": [0, 1, 2, 3], "engine": 80, "damage_control": 0 }),
			"allocation exactly at crew pool is accepted")
	_check(not cruiser.apply_allocation({ "guns": [0, 1, 2, 3], "engine": 81, "damage_control": 0 }),
			"over-allocation is rejected")
	# Reload: fire the bow medium (reload 1), confirm it goes on cooldown and ticks back.
	cruiser.apply_allocation({ "guns": [0], "engine": 0, "damage_control": 0 })
	var target := ShipState.create(ShipLibrary.ship(&"helium_battleship"), 1, Vector2i(0, -3), 3)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	DamageResolver.resolve_shot(cruiser, 0, target, rng)
	_check_eq(int(cruiser.gun_states[0]["reload"]), 1, "medium gun on 1-turn cooldown after firing")
	_check(not cruiser.gun_ready(0), "gun not ready while reloading")
	cruiser.tick_reloads()
	_check(cruiser.gun_ready(0), "gun ready again after reload ticks down")


# ---------------------------------------------------------------------------
# Damage
# ---------------------------------------------------------------------------

func _test_armor_absorption() -> void:
	var firer := ShipState.create(ShipLibrary.ship(&"helium_scout"), 0, Vector2i(0, 6), 0)
	var target := ShipState.create(ShipLibrary.ship(&"zodanga_cruiser"), 1, Vector2i(0, 0), 0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	# Fire from dead astern: stern armor (facing 3) starts at 3.
	var report := { "internals": [] }
	DamageResolver._apply_damage(firer, target, 2, report, rng)
	_check_eq(target.armor_remaining[3], 1, "2 damage from astern leaves stern armor 3 -> 1")
	_check_eq(report["armor_absorbed"], 2, "all damage absorbed by armor")
	_check_eq((report["internals"] as Array).size(), 0, "no internals when armor holds")
	# 4 more damage: 1 absorbed, 3 internal.
	report = { "internals": [] }
	DamageResolver._apply_damage(firer, target, 4, report, rng)
	_check_eq(target.armor_remaining[3], 0, "stern armor exhausted")
	_check_eq(report["armor_absorbed"], 1, "partial absorption on the breaking volley")
	_check_eq((report["internals"] as Array).size(), 3, "overflow becomes internal hits")
	_check(target.armor_remaining[3] >= 0, "armor never goes negative")
	# Other facings untouched.
	_check_eq(target.armor_remaining[0], 5, "unstruck facings keep full armor")
	# A full resolve_shot report carries the firer/target hexes (UI tracer
	# endpoints — positional metadata, not read back by the rules).
	firer.gun_states[0]["manned"] = true
	var sr := DamageResolver.resolve_shot(firer, 0, target, rng, {})
	_check_eq(sr["firer_hex"], firer.hex, "shot report carries the firer hex")
	_check_eq(sr["target_hex"], target.hex, "shot report carries the target hex")

func _test_dac_determinism() -> void:
	# Same seed, same ship state => identical internal damage sequence.
	var results: Array = []
	for trial in 2:
		var target := ShipState.create(ShipLibrary.ship(&"zodanga_cruiser"), 1, Vector2i(0, 0), 0)
		var firer := ShipState.create(ShipLibrary.ship(&"helium_scout"), 0, Vector2i(0, 6), 0)
		var rng := RandomNumberGenerator.new()
		rng.seed = 42
		var report := { "internals": [] }
		DamageResolver._apply_damage(firer, target, 10, report, rng)
		var sequence: Array[String] = []
		for hit in report["internals"]:
			sequence.append(str(hit["system"]))
		results.append(sequence)
	_check_eq(results[0], results[1], "seeded RNG reproduces identical DAC sequences")

func _test_magazine_explosion() -> void:
	# Strip a target down to magazine boxes only; every internal hit must
	# strike the magazine, and a roll of 5+ detonates it.
	var target := ShipState.create(ShipLibrary.ship(&"zodanga_cruiser"), 1, Vector2i(0, 0), 0)
	for t in target.systems_remaining.keys():
		if t != ShipDef.SystemType.MAGAZINE:
			target.systems_remaining[t] = 0
	for g in target.gun_states:
		g["destroyed"] = true
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var exploded := false
	for _i in 20:
		if target.is_destroyed:
			exploded = true
			break
		DamageResolver._roll_internal(target, rng)
	_check(exploded, "repeated magazine hits eventually detonate the ship")
	# A fully stripped ship becomes a hulk on the next internal.
	var hulk := ShipState.create(ShipLibrary.ship(&"helium_scout"), 1, Vector2i(0, 0), 0)
	for t in hulk.systems_remaining.keys():
		hulk.systems_remaining[t] = 0
	for g in hulk.gun_states:
		g["destroyed"] = true
	DamageResolver._roll_internal(hulk, rng)
	_check(hulk.is_destroyed, "ship with nothing left to destroy becomes a destroyed hulk")


# ---------------------------------------------------------------------------
# Torpedoes
# ---------------------------------------------------------------------------

func _test_torpedo_armor_piercing() -> void:
	# Same geometry as the armour test: firer astern of the target, so the shot
	# strikes the stern facing (cruiser stern armour = 3).
	var firer := ShipState.create(ShipLibrary.ship(&"helium_scout"), 0, Vector2i(0, 6), 0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var target := ShipState.create(ShipLibrary.ship(&"zodanga_cruiser"), 1, Vector2i(0, 0), 0)
	var report := { "internals": [] }
	DamageResolver._apply_damage(firer, target, 6, report, rng, 3)   # AP 3
	_check_eq(report["facing_struck"], 3, "torpedo strikes the stern facing")
	_check_eq(int(report["armor_absorbed"]), 0, "AP 3 fully bypasses stern armour 3")
	_check_eq((report["internals"] as Array).size(), 6, "all 6 damage reaches internals")
	_check_eq(target.armor_remaining[3], 3, "bypassed plating is punched through, not marked off")
	# Contrast: a plain shell on the same facing is mostly stopped by the armour.
	var target2 := ShipState.create(ShipLibrary.ship(&"zodanga_cruiser"), 1, Vector2i(0, 0), 0)
	var report2 := { "internals": [] }
	DamageResolver._apply_damage(firer, target2, 6, report2, rng, 0)
	_check_eq(int(report2["armor_absorbed"]), 3, "a plain shell is stopped by all 3 stern armour")
	_check_eq((report2["internals"] as Array).size(), 3, "only the overflow gets through")


func _test_torpedo_ammo_and_gating() -> void:
	const TUBE := 1   # scout: mount 0 = turret, mount 1 = torpedo tube
	var scout := ShipState.create(ShipLibrary.ship(&"helium_scout"), 0, Vector2i(0, 0), 0)
	var enemy := ShipState.create(ShipLibrary.ship(&"zodanga_cruiser"), 1, Vector2i(0, -3), 3)
	_check_eq(str(scout.def.gun_mounts[TUBE]["label"]), "Torpedo Tube", "tube is mount index 1")
	_check_eq(int(scout.gun_states[TUBE]["ammo"]), 3, "tube starts with a full rack of 3")
	# Man only the tube so the ammo machinery is isolated from the deck guns.
	scout.apply_allocation({ "guns": [TUBE], "engine": 0, "damage_control": 0 })
	var pv := scout.fire_preview(TUBE, enemy.hex)
	_check(pv["bears"] and pv["is_torpedo"], "manned tube in arc/range bears as a torpedo")
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for shot in 3:
		_check(scout.gun_ready(TUBE), "tube ready with %d torpedoes left" % (3 - shot))
		DamageResolver.resolve_shot(scout, TUBE, enemy, rng)
		scout.gun_states[TUBE]["reload"] = 0   # ignore the long reload for the ammo probe
	_check_eq(int(scout.gun_states[TUBE]["ammo"]), 0, "rack empty after three launches")
	_check(not scout.gun_ready(TUBE), "empty tube is not ready even when manned and bearing")
	_check_eq(str(scout.fire_preview(TUBE, enemy.hex)["reason"]), "out of ammo",
			"empty tube preview explains why it can't fire")
	# Even mid-reload, a spent tube reads "out of ammo", not "reloading" — the
	# reload counter on a no-ammo tube would never produce another torpedo.
	scout.gun_states[TUBE]["reload"] = 2
	_check_eq(str(scout.fire_preview(TUBE, enemy.hex)["reason"]), "out of ammo",
			"a spent tube reads 'out of ammo' even with a reload counter pending")
	scout.gun_states[TUBE]["reload"] = 0
	_check(not (TUBE in scout.guns_bearing(enemy.hex)), "empty tube drops out of guns_bearing")
	# An ordinary deck gun is untouched by all of this.
	scout.apply_allocation({ "guns": [0], "engine": 0, "damage_control": 0 })
	var gpv := scout.fire_preview(0, enemy.hex)
	_check(not gpv["is_torpedo"] and int(gpv["ammo"]) == -1, "a deck gun reports infinite ammo")


# ---------------------------------------------------------------------------
# Buoyancy
# ---------------------------------------------------------------------------

func _test_buoyancy_grounding() -> void:
	var scout := ShipState.create(ShipLibrary.ship(&"helium_scout"), 0, Vector2i(0, 0), 0)
	scout.speed = 4
	_check(scout.is_buoyant(), "undamaged scout is buoyant")
	# Hole tanks down to one above the threshold (scout falls at <= 1).
	scout.systems_remaining[ShipDef.SystemType.BUOYANCY] = 2
	scout.enforce_buoyancy()
	_check(not scout.grounded, "scout one tank above the falling line stays aloft")
	# One more tank gone: at the threshold, the ship settles at upkeep.
	scout.systems_remaining[ShipDef.SystemType.BUOYANCY] = 1
	_check(not scout.is_buoyant(), "scout at the falling line is no longer buoyant")
	scout.enforce_buoyancy()
	_check(scout.grounded, "ship at the grounding threshold is grounded at upkeep")
	_check_eq(scout.speed, 0, "grounded ship speed forced to 0")


func _test_damage_control_feedback() -> void:
	# Damage control patching tanks at upkeep must announce itself (the player
	# saw "tank holed" but the sheet silently recovering looked like a bug).
	var engine := TurnEngine.new()
	engine.setup(424242)
	var s := engine.ships[0]   # the scout
	var maxb := s.def.system_count(ShipDef.SystemType.BUOYANCY)
	# Hole four tanks (well above the falling line so it isn't grounded) and put
	# a generous repair party on the job.
	s.systems_remaining[ShipDef.SystemType.BUOYANCY] = maxi(maxb - 4, s.def.grounding_threshold + 1)
	s.allocation = { "damage_control": 6 }
	var before := s.sys(ShipDef.SystemType.BUOYANCY)
	var seen := { "count": 0, "last": -1 }
	engine.damage_control_repaired.connect(func(sh: ShipState, rem: int) -> void:
		if sh == s:
			seen["count"] += 1
			seen["last"] = rem)
	engine.run_upkeep()
	var after := s.sys(ShipDef.SystemType.BUOYANCY)
	_check_eq(int(seen["count"]), after - before,
			"a repair signal fires once per buoyancy tank patched")
	if int(seen["count"]) > 0:
		_check_eq(int(seen["last"]), after, "repair signal reports the running tank total")


func _test_damage_control_claws_back() -> void:
	# A flyer sitting exactly on its falling line must get its damage-control
	# chance BEFORE the grounding check — patched back above the line, it lives.
	# Find a seed whose first DC roll succeeds, so the test is deterministic
	# without reaching into the resolver internals.
	var seed_val := -1
	for candidate in range(1, 500):
		var probe := RandomNumberGenerator.new()
		probe.seed = candidate
		if probe.randi_range(1, 6) >= 5:
			seed_val = candidate
			break
	_check(seed_val != -1, "found a seed whose first repair roll succeeds")

	var engine := TurnEngine.new()
	engine.setup(1)
	engine.rng.seed = seed_val
	# The cruiser has damage control (the scout is now a no-DC flyer); put it on its
	# falling line and let the repair party claw it back before the grounding check.
	var s := engine.ships[1]   # the cruiser, falls at 3
	s.systems_remaining[ShipDef.SystemType.BUOYANCY] = s.def.grounding_threshold  # on the line
	s.allocation = { "damage_control": 1 }
	_check(not s.is_buoyant(), "cruiser starts the upkeep at/below its falling line")
	# Keep the enemy alive and clear so this is the only victory trigger in play.
	engine.run_upkeep()
	_check(not s.grounded, "damage control lifts the cruiser back above the line before grounding")
	_check(s.is_buoyant(), "patched tank restores buoyancy")
	_check_eq(engine.phase, TurnEngine.Phase.ALLOCATION,
			"clawed-back flyer does not trigger game over")


# ---------------------------------------------------------------------------
# Capability erosion
# ---------------------------------------------------------------------------

func _test_derived_capabilities() -> void:
	var cruiser := ShipState.create(ShipLibrary.ship(&"zodanga_cruiser"), 0, Vector2i(0, 0), 0)
	_check_eq(cruiser.effective_max_speed(), 6, "undamaged cruiser max speed")
	cruiser.systems_remaining[ShipDef.SystemType.ENGINE] = 3  # of 6
	_check_eq(cruiser.effective_max_speed(), 3, "half engines: ceil(6 * 0.5) = 3")
	cruiser.systems_remaining[ShipDef.SystemType.ENGINE] = 0
	_check_eq(cruiser.effective_max_speed(), 0, "no engines: dead in the air")
	# Rudder damage worsens turn mode.
	cruiser.speed = 4
	var base_tm := cruiser.def.turn_mode(4)
	cruiser.systems_remaining[ShipDef.SystemType.RUDDER] = 1  # of 3, <= 50%
	_check_eq(cruiser.turn_mode(), base_tm + 1, "half rudder adds 1 to turn mode")
	cruiser.systems_remaining[ShipDef.SystemType.RUDDER] = 0
	_check_eq(cruiser.turn_mode(), base_tm + 2, "no rudder adds 2 to turn mode")


# ---------------------------------------------------------------------------
# Terrain: LOS, dust, line_hexes
# ---------------------------------------------------------------------------

func _test_hex_line() -> void:
	# Distance-3 straight line north has 2 intermediate hexes.
	var pts := HexMath.line_hexes(Vector2i(0, 0), Vector2i(0, -3))
	_check_eq(pts.size(), 2, "line (0,0)→(0,-3) has 2 intermediates")
	_check_eq(pts[0], Vector2i(0, -1), "first intermediate is (0,-1)")
	_check_eq(pts[1], Vector2i(0, -2), "second intermediate is (0,-2)")
	# Adjacent hexes have no intermediate hexes.
	_check_eq(HexMath.line_hexes(Vector2i(0, 0), Vector2i(1, 0)).size(), 0,
			"adjacent hexes: 0 intermediates")
	# Same hex to same hex: 0 intermediates.
	_check_eq(HexMath.line_hexes(Vector2i(3, 3), Vector2i(3, 3)).size(), 0,
			"same hex: 0 intermediates")
	# Distance 4: 3 intermediates.
	_check_eq(HexMath.line_hexes(Vector2i(0, 0), Vector2i(0, -4)).size(), 3,
			"distance-4 line has 3 intermediates")


func _test_terrain_los() -> void:
	# Hill at an intermediate hex blocks LOS.
	var hill := { Vector2i(0, -1): TerrainDef.Type.HILL }
	_check(not TerrainDef.los_clear(Vector2i(0, 0), Vector2i(0, -3), hill),
			"hill at (0,-1) blocks LOS from (0,0) to (0,-3)")
	# Hill at the target hex does NOT block — only intermediates count.
	var hill_target := { Vector2i(0, -3): TerrainDef.Type.HILL }
	_check(TerrainDef.los_clear(Vector2i(0, 0), Vector2i(0, -3), hill_target),
			"hill at the target hex does not block LOS (endpoint excluded)")
	# Tower behaves like a hill.
	var tower := { Vector2i(0, -1): TerrainDef.Type.TOWER }
	_check(not TerrainDef.los_clear(Vector2i(0, 0), Vector2i(0, -3), tower),
			"ruined tower in the path blocks LOS")
	# Dust storm does NOT block LOS (only imposes a spotting penalty).
	var dust := { Vector2i(0, -1): TerrainDef.Type.DUST_STORM }
	_check(TerrainDef.los_clear(Vector2i(0, 0), Vector2i(0, -3), dust),
			"dust storm in the path does not block LOS")
	# Empty terrain: LOS always clear.
	_check(TerrainDef.los_clear(Vector2i(0, 0), Vector2i(8, -6), {}),
			"empty terrain: LOS clear at any range")


func _test_terrain_dust() -> void:
	# One dust hex at the intermediate → penalty 1.
	var dust_mid := { Vector2i(0, -1): TerrainDef.Type.DUST_STORM }
	_check_eq(TerrainDef.dust_along(Vector2i(0, 0), Vector2i(0, -2), dust_mid), 1,
			"dust at intermediate hex → penalty 1")
	# Dust at the target hex also counts.
	var dust_target := { Vector2i(0, -2): TerrainDef.Type.DUST_STORM }
	_check_eq(TerrainDef.dust_along(Vector2i(0, 0), Vector2i(0, -2), dust_target), 1,
			"dust at the target hex counts (penalty 1)")
	# Dust at the firer's own hex is NOT counted.
	var dust_firer := { Vector2i(0, 0): TerrainDef.Type.DUST_STORM }
	_check_eq(TerrainDef.dust_along(Vector2i(0, 0), Vector2i(0, -2), dust_firer), 0,
			"dust at the firer's own hex is not counted")
	# Hill along path contributes 0 penalty (blocks LOS but no dust penalty).
	var hill := { Vector2i(0, -1): TerrainDef.Type.HILL }
	_check_eq(TerrainDef.dust_along(Vector2i(0, 0), Vector2i(0, -2), hill), 0,
			"hill gives no dust penalty")


func _test_terrain_fire_preview() -> void:
	var scout := ShipState.create(ShipLibrary.ship(&"helium_scout"), 0, Vector2i(0, 0), 0)
	scout.apply_allocation({ "guns": [0], "engine": 0, "damage_control": 0 })
	# Turret at range 2 dead ahead bears (360° mount).
	# Hill at the intermediate hex (0,-1) should report LOS blocked.
	var hill_terrain := { Vector2i(0, -1): TerrainDef.Type.HILL }
	var pv_blocked := scout.fire_preview(0, Vector2i(0, -2), hill_terrain)
	_check(not pv_blocked["bears"], "fire_preview: hill in path → does not bear")
	_check_eq(pv_blocked["reason"], "LOS blocked",
			"fire_preview reason is 'LOS blocked' with hill in path")
	# Dust at the intermediate hex: shot bears but to-hit is raised by 1.
	var dust_terrain := { Vector2i(0, -1): TerrainDef.Type.DUST_STORM }
	var pv_dust := scout.fire_preview(0, Vector2i(0, -2), dust_terrain)
	_check(pv_dust["bears"], "fire_preview: dust does not block the shot")
	_check_eq(pv_dust["dust_penalty"], 1, "fire_preview reports dust_penalty 1")
	_check_eq(pv_dust["to_hit"], 4, "dust raises the turret to-hit from 3 to 4")
	# One lookout crew cancels the dust penalty completely.
	scout.apply_allocation({ "guns": [0], "engine": 0, "damage_control": 0, "lookout": 1 })
	var pv_lookout := scout.fire_preview(0, Vector2i(0, -2), dust_terrain)
	_check_eq(pv_lookout["dust_penalty"], 0, "lookout cancels the dust penalty")
	_check_eq(pv_lookout["to_hit"], 3, "to-hit restored to 3 with lookout countering dust")
	# guns_bearing respects LOS: hill blocks the mount from appearing in bearing list.
	scout.apply_allocation({ "guns": [0], "engine": 0, "damage_control": 0 })
	var bearing_no_terrain := scout.guns_bearing(Vector2i(0, -2))
	var bearing_with_hill := scout.guns_bearing(Vector2i(0, -2), hill_terrain)
	_check(0 in bearing_no_terrain, "bow gun bears dead ahead without terrain")
	_check(not (0 in bearing_with_hill), "bow gun drops out of guns_bearing when hill blocks LOS")


# ---------------------------------------------------------------------------
# Listing: per-side buoyancy and maneuver penalty
# ---------------------------------------------------------------------------

func _test_listing() -> void:
	# Scout: 8 total buoyancy → port 4, stbd 4 at start.
	var scout := ShipState.create(ShipLibrary.ship(&"helium_scout"), 0, Vector2i(0, 0), 0)
	_check_eq(scout.port_buoyancy, 4, "scout initializes with 4 port tanks")
	_check_eq(scout.stbd_buoyancy, 4, "scout initializes with 4 starboard tanks")
	_check_eq(scout.list_severity(), 0, "balanced: list_severity is 0")
	_check_eq(scout.list_side(), "", "balanced: list_side is empty")

	# Imbalance of 1 is below the penalty threshold.
	scout.port_buoyancy -= 1
	scout.systems_remaining[ShipDef.SystemType.BUOYANCY] -= 1
	_check_eq(scout.list_severity(), 0, "imbalance of 1: no turn-mode penalty")
	_check_eq(scout.list_side(), "", "imbalance of 1: too small to list")

	# Imbalance of 2 imposes list_severity 1 and a list direction.
	scout.port_buoyancy -= 1
	scout.systems_remaining[ShipDef.SystemType.BUOYANCY] -= 1
	_check_eq(scout.list_severity(), 1, "imbalance of 2 gives list_severity 1")
	_check_eq(scout.list_side(), "port", "port tanks low: listing to port")
	var base_tm := scout.def.turn_mode(scout.speed)
	_check_eq(scout.turn_mode(), base_tm + 1, "listing adds 1 to turn mode")

	# struck_facing 4 (aft-port) and 5 (fwd-port) both hit port buoyancy.
	var rng := RandomNumberGenerator.new()
	rng.seed = 0
	var t4 := ShipState.create(ShipLibrary.ship(&"helium_scout"), 0, Vector2i(0, 0), 0)
	DamageResolver._hit_system(t4, ShipDef.SystemType.BUOYANCY, rng, 4)
	_check_eq(t4.port_buoyancy, 3, "struck_facing 4 (aft-port) decrements port buoyancy")
	_check_eq(t4.stbd_buoyancy, 4, "stbd buoyancy unaffected by port hit")

	var t5 := ShipState.create(ShipLibrary.ship(&"helium_scout"), 0, Vector2i(0, 0), 0)
	DamageResolver._hit_system(t5, ShipDef.SystemType.BUOYANCY, rng, 5)
	_check_eq(t5.port_buoyancy, 3, "struck_facing 5 (fwd-port) also decrements port buoyancy")

	# struck_facing 1 (fwd-stbd) and 2 (aft-stbd) both hit stbd buoyancy.
	var t1 := ShipState.create(ShipLibrary.ship(&"helium_scout"), 0, Vector2i(0, 0), 0)
	DamageResolver._hit_system(t1, ShipDef.SystemType.BUOYANCY, rng, 1)
	_check_eq(t1.stbd_buoyancy, 3, "struck_facing 1 (fwd-stbd) decrements stbd buoyancy")
	_check_eq(t1.port_buoyancy, 4, "port buoyancy unaffected by stbd hit")

	var t2 := ShipState.create(ShipLibrary.ship(&"helium_scout"), 0, Vector2i(0, 0), 0)
	DamageResolver._hit_system(t2, ShipDef.SystemType.BUOYANCY, rng, 2)
	_check_eq(t2.stbd_buoyancy, 3, "struck_facing 2 (aft-stbd) also decrements stbd buoyancy")

	# DC repair patches the lower side (port here) to reduce the list.
	var ok_seed := -1
	for cand in range(1, 500):
		var probe := RandomNumberGenerator.new()
		probe.seed = cand
		if probe.randi_range(1, 6) >= 5:
			ok_seed = cand
			break
	var engine := TurnEngine.new()
	engine.setup(1)
	var s := engine.ships[1]   # cruiser (has damage control; the scout no longer does)
	s.port_buoyancy = 2
	s.stbd_buoyancy = 4
	s.systems_remaining[ShipDef.SystemType.BUOYANCY] = 6
	_check_eq(s.list_side(), "port", "port lower: listing to port before repair")
	engine.rng.seed = ok_seed
	s.allocation = { "damage_control": 1 }
	engine.run_upkeep()
	_check_eq(s.port_buoyancy, 3, "DC repair patches the lower (port) side")
	_check_eq(s.stbd_buoyancy, 4, "stbd buoyancy unchanged when port side is patched")


# ---------------------------------------------------------------------------
# AI: the doctrine-driven utility evaluator
# ---------------------------------------------------------------------------

func _test_ai_evaluator() -> void:
	var engine := TurnEngine.new()
	engine.setup(1)
	var scout: ShipState = engine.ships[0]
	var cruiser: ShipState = engine.ships[1]
	scout.apply_allocation({ "guns": [0, 1], "engine": 0, "damage_control": 0 })   # turret + tube
	cruiser.apply_allocation({ "guns": [0, 1, 2, 3], "engine": 0, "damage_control": 0 })
	var scout_ai := ShipAI.for_ship(scout.def)
	var cruiser_ai := ShipAI.for_ship(cruiser.def)

	# Scout doctrine prefers its range band (5-8) over sitting point-blank.
	cruiser.hex = Vector2i(8, 4)
	cruiser.facing = 0
	var in_band := scout_ai._eval_position(scout, Vector2i(8, 10), 0, cruiser)   # range 6
	var too_close := scout_ai._eval_position(scout, Vector2i(8, 5), 0, cruiser)   # range 1
	_check(in_band > too_close, "scout evaluator prefers its range band to point-blank")

	# Cruiser doctrine prefers presenting a broadside (two heavies bear) over
	# meeting the enemy bow-on (only the bow medium bears), same hex and range.
	var enemy_hex := Vector2i(8, 8)   # 4 hexes due south of the cruiser
	var broadside := cruiser_ai._eval_position(cruiser, Vector2i(8, 4), 4, scout_at(scout, enemy_hex))
	var bow_on := cruiser_ai._eval_position(cruiser, Vector2i(8, 4), 3, scout_at(scout, enemy_hex))
	_check(broadside > bow_on, "cruiser evaluator prefers presenting a broadside")


## Helper: position the scout at `h` and hand it back as the "enemy" argument.
func scout_at(scout: ShipState, h: Vector2i) -> ShipState:
	scout.hex = h
	scout.facing = 0
	return scout


func _test_ai_armor_awareness() -> void:
	var engine := TurnEngine.new()
	engine.setup(1)
	var scout: ShipState = engine.ships[0]
	var cruiser: ShipState = engine.ships[1]
	cruiser.apply_allocation({ "guns": [0, 1, 2, 3], "engine": 0, "damage_control": 0 })
	var cruiser_ai := ShipAI.for_ship(cruiser.def)
	var scout_ai := ShipAI.for_ship(scout.def)

	# OFFENSE: same firing position scores higher once the enemy facing it strikes
	# has been stripped — the AI presses a breach instead of chipping fresh plate.
	scout.hex = Vector2i(8, 8)
	scout.facing = 0
	var pos := Vector2i(8, 4)
	var face := 3
	var full := cruiser_ai._eval_position(cruiser, pos, face, scout)
	var hit := HexMath.struck_facing(scout.hex, scout.facing, pos)
	scout.armor_remaining[hit] = 0
	var breached := cruiser_ai._eval_position(cruiser, pos, face, scout)
	_check(breached > full, "AI values striking a stripped enemy facing over intact plate")
	scout.armor_remaining[hit] = scout.def.armor[hit]   # restore

	# DEFENSE: a position scores worse once the OWN facing it would present has
	# been holed — the AI won't turn a breach toward the enemy.
	var mh := Vector2i(8, 10)
	var mf := 0
	var before := scout_ai._eval_position(scout, mh, mf, cruiser)
	var shown := HexMath.struck_facing(mh, mf, cruiser.hex)
	scout.armor_remaining[shown] = 0
	var after := scout_ai._eval_position(scout, mh, mf, cruiser)
	_check(after < before, "AI avoids presenting an already-holed facing to the enemy")

	# TORPEDO DISCIPLINE vs armour: loose on hard plating, hold once the facing is
	# breached and a deck gun can exploit it for free.
	var sc := ShipState.create(ShipLibrary.ship(&"helium_scout"), 0, Vector2i(5, 5), 0)
	var ehex := sc.hex
	for _k in 4:
		ehex = HexMath.neighbor(ehex, 0)
	var en := ShipState.create(ShipLibrary.ship(&"zodanga_cruiser"), 1, ehex, 3)
	sc.apply_allocation({ "guns": [0, 1], "engine": 0, "damage_control": 0 })   # turret + tube
	var sai := ShipAI.for_ship(sc.def)
	var th := HexMath.struck_facing(en.hex, en.facing, sc.hex)
	var fire_hard := sai.choose_fire(sc, en)
	_check(1 in fire_hard, "torpedo looses against hard armour")
	en.armor_remaining[th] = 1   # breach the struck facing
	var fire_soft := sai.choose_fire(sc, en)
	_check(not (1 in fire_soft), "torpedo held once the facing is breached and a gun bears")
	_check(0 in fire_soft, "the deck gun still fires into the breach")


# ---------------------------------------------------------------------------
# AI lookahead: the seeded-engine Monte Carlo rollouts (Phase C)
# ---------------------------------------------------------------------------

## The clone primitive the rollouts are built on: a deep, independent copy that
## reproduces the RNG sequence (so a simulated turn rolls the same dice the real
## one would) and shares no state with the original.
func _test_engine_clone() -> void:
	var engine := TurnEngine.new()
	engine.setup(20260614)
	engine.turn_number = 5
	engine.ships[0].armor_remaining[0] = 1
	engine.ships[0].fires = 1
	for _i in 3:                       # advance mid-stream, not at the seed boundary
		engine.rng.randi()

	var c := SaveGame.clone(engine)
	_check(c != null, "clone returns a live engine")
	_check(c != engine, "clone is a distinct engine instance")
	_check_eq(c.turn_number, engine.turn_number, "clone copies turn_number")
	_check_eq(c.ships.size(), engine.ships.size(), "clone copies the whole fleet")
	_check(c.ships[0] != engine.ships[0], "clone ships are independent instances")
	_check_eq(c.ships[0].armor_remaining[0], 1, "clone copies per-facing armor marks")

	# The clone continues the exact same RNG sequence — the basis for a rollout
	# rolling the same dice the live turn would.
	var expected: Array[int] = []
	for _i in 8:
		expected.append(engine.rng.randi())
	var got: Array[int] = []
	for _i in 8:
		got.append(c.rng.randi())
	_check_eq(got, expected, "clone reproduces the original's next RNG draws")

	# Independence: mutating the clone never reaches back into the live engine.
	c.ships[0].armor_remaining[0] = 0
	c.ships[0].fires = 9
	_check_eq(engine.ships[0].armor_remaining[0], 1, "mutating clone armor leaves the original")
	_check_eq(engine.ships[0].fires, 1, "mutating clone fires leaves the original")


## The rollout's scoring function: hurting the enemy raises our state value,
## taking damage lowers it, and an actual win lands a decisive bonus on top.
func _test_lookahead_value_function() -> void:
	var engine := TurnEngine.new()
	engine.setup(7)
	var ai := ShipAI.for_ship(engine.ships[0].def)
	var enemy := engine.ships[1]
	var base := ai._eval_state(engine, 0)

	enemy.armor_remaining[0] = maxi(enemy.armor_remaining[0] - 2, 0)
	enemy.systems_remaining[ShipDef.SystemType.ENGINE] -= 1
	var hurt_enemy := ai._eval_state(engine, 0)
	_check(hurt_enemy > base, "wounding the enemy raises our state value")

	engine.ships[0].systems_remaining[ShipDef.SystemType.ENGINE] -= 1
	engine.ships[0].fires = 1
	var hurt_self := ai._eval_state(engine, 0)
	_check(hurt_self < hurt_enemy, "taking damage ourselves lowers the value")

	# A decisive result dwarfs any amount of chipped plate: the same board scores
	# far higher once it's a win (enemy out, our side still flying).
	enemy.is_destroyed = true
	var alive := ai._eval_state(engine, 0)
	engine.phase = TurnEngine.Phase.GAME_OVER
	var won := ai._eval_state(engine, 0)
	_check(won - alive > 500.0, "a won battle scores a decisive bonus")


## The plot chooser: it returns a speed reachable this turn, is deterministic at
## rollouts == 1, leaves the live engine untouched, and returns the argmax over
## the candidate rollout values.
func _test_lookahead_plot_choice() -> void:
	var engine := TurnEngine.new()
	engine.setup(31337)
	var me := engine.ships[0]
	var foe := engine.ships[1]
	# Realistic allocations so usable speed (and the foe's rollout plot) are live.
	ShipAI.for_ship(me.def).allocate(engine, me)
	ShipAI.for_ship(foe.def).allocate(engine, foe)
	var brain := ShipAI.for_ship_with_lookahead(me.def, 1, 1)

	var cap := me.usable_max_speed()
	var dv := me.max_speed_change()
	var lo: int = clampi(me.speed - dv, 0, cap)
	var hi: int = clampi(me.speed + dv, 0, cap)
	var speed_before := me.speed

	var chosen := brain._plot_by_lookahead(engine, me)
	_check(chosen >= lo and chosen <= hi, "lookahead picks a speed reachable this turn")
	_check_eq(me.speed, speed_before, "lookahead is pure — it never mutates the live engine")
	_check_eq(brain._plot_by_lookahead(engine, me), chosen, "rollouts=1 lookahead is deterministic")

	# It must return the argmax candidate. Recompute the per-speed rollout values
	# the way the chooser does (single seeded trial, salt 0) and confirm the pick.
	var my_index := engine.ships.find(me)
	var best := me.speed
	var best_v := -INF
	for cand in range(lo, hi + 1):
		var v := brain._rollout_value(engine, my_index, cand, 0)
		if v > best_v:
			best_v = v
			best = cand
	_check_eq(chosen, best, "lookahead returns the best-scoring candidate speed")


## Integration: a rollout captain (side 0) against the plain 1-ply brain drives
## real battles on the seeded engine to a decisive end without breaking any
## invariant — the lookahead machinery plugs into the production loop cleanly.
func _test_lookahead_battle() -> void:
	var decided := 0
	var clean_all := true
	for seed_i in [1, 2, 3]:
		var engine := TurnEngine.new()
		engine.setup(seed_i * 7919 + 1)
		var brains := [
			ShipAI.for_ship_with_lookahead(engine.ships[0].def, 2, 1),
			ShipAI.for_ship(engine.ships[1].def),
		]
		var r := _play_out_brains(engine, brains)
		if not bool(r["clean"]):
			clean_all = false
		if int(r["winner"]) >= 0:
			decided += 1
	_check(clean_all, "lookahead battles keep every box count >= 0")
	_check(decided >= 2, "at least 2 of 3 lookahead battles reach a decisive result (got %d)" % decided)


## The menu's difficulty ranks map onto the two wired levers: Padwar sandbags
## with move-noise, Dwar is the clean 1-ply default, Odwar runs the rollouts.
func _test_difficulty_presets() -> void:
	var def := ShipLibrary.ship(&"zodanga_cruiser")

	var padwar := ShipAI.for_difficulty(def, ShipAI.Difficulty.PADWAR)
	_check(padwar.noise > 0.0, "Padwar plays with positional noise (easy)")
	_check_eq(padwar.rollouts, 0, "Padwar runs no lookahead")

	var dwar := ShipAI.for_difficulty(def, ShipAI.Difficulty.DWAR)
	_check_eq(dwar.noise, 0.0, "Dwar plays the clean 1-ply doctrine")
	_check_eq(dwar.rollouts, 0, "Dwar runs no lookahead")

	var odwar := ShipAI.for_difficulty(def, ShipAI.Difficulty.ODWAR)
	_check(odwar.rollouts > 0, "Odwar runs the seeded-engine rollouts (hard)")
	_check_eq(odwar.noise, 0.0, "Odwar plays its doctrine straight, no sandbagging")

	# An unknown level falls back to the balanced default rather than crashing.
	var fallback := ShipAI.for_difficulty(def, 999)
	_check_eq(fallback.rollouts, 0, "unknown difficulty falls back to the 1-ply default")
	_check(ShipAI.difficulty_name(ShipAI.Difficulty.ODWAR) != "", "every rank has a display name")


func _test_fleet_setup() -> void:
	# 1. The legacy / seed-only path still boots the classic scout-vs-cruiser duel
	#    unchanged, so existing callers (tests, demos) keep working.
	var legacy := TurnEngine.new()
	legacy.setup(1)
	_check_eq(legacy.ships.size(), 2, "legacy setup still fields two ships")
	_check_eq(String(legacy.ships[0].def.id), "helium_scout", "legacy side 0 is the scout")
	_check_eq(String(legacy.ships[1].def.id), "zodanga_cruiser", "legacy side 1 is the cruiser")
	_check_eq(legacy.ships[0].hex, Vector2i(20, 10), "legacy scout keeps its centred start")

	# 2. An explicit fleet of placements: a 2-vs-1 with a mix of classes. Every
	#    ship deploys on the board, none stack, and sides/facings are honoured.
	var engine := TurnEngine.new()
	engine.setup_fleet([
		{ "ship_id": &"helium_scout", "side": 0, "hex": Vector2i(18, 12), "facing": 1 },
		{ "ship_id": &"one_man_flyer", "side": 0, "hex": Vector2i(18, 14), "facing": 1 },
		{ "ship_id": &"zodanga_cruiser", "side": 1, "hex": Vector2i(30, 8), "facing": 4 },
	], 4242)
	_check_eq(engine.ships.size(), 3, "fleet setup fields all three ships")
	_check_eq(engine.ships[0].side, 0, "placement side 0 honoured")
	_check_eq(engine.ships[2].side, 1, "placement side 1 honoured")
	_check_eq(engine.ships[1].facing, 1, "placement facing honoured")
	var all_on_board := true
	for s in engine.ships:
		if not engine.map_contains(s.hex):
			all_on_board = false
	_check(all_on_board, "every placed ship is on the board")
	_check(_no_ship_stacks(engine), "no two placed ships share a hex")

	# 3. Two ships requesting the SAME hex must not stack — the deploy nudge
	#    spills the second onto the nearest free legal hex.
	var clash := TurnEngine.new()
	clash.setup_fleet([
		{ "ship_id": &"helium_scout", "side": 0, "hex": Vector2i(24, 6), "facing": 0 },
		{ "ship_id": &"helium_scout", "side": 1, "hex": Vector2i(24, 6), "facing": 3 },
	], 7)
	_check_eq(clash.ships[0].hex, Vector2i(24, 6), "first ship takes the requested hex")
	_check(clash.ships[1].hex != clash.ships[0].hex, "clashing second ship is nudged off the stack")
	_check(clash.map_contains(clash.ships[1].hex), "the nudged hex is still on the board")
	_check_eq(HexMath.distance(clash.ships[1].hex, Vector2i(24, 6)), 1,
			"the nudge lands on the nearest ring (distance 1)")

	# 4. An off-board placement request is pulled back onto the field.
	var off := TurnEngine.new()
	off.setup_fleet([
		{ "ship_id": &"helium_scout", "side": 0, "hex": Vector2i(-5, -5), "facing": 0 },
	], 9)
	_check(off.map_contains(off.ships[0].hex), "off-board request is nudged onto the field")

	# 5. The roster convenience lays a 3-v-2 on opposing deployment lines: right
	#    counts and sides, all on-board, no stacks.
	var rosters := TurnEngine.new()
	rosters.setup_rosters(
		[&"helium_scout", &"one_man_flyer", &"helium_scout"],
		[&"zodanga_cruiser", &"helium_battleship"], 555)
	_check_eq(rosters.ships.size(), 5, "rosters field every ship from both lines")
	var side0 := 0
	var side1 := 0
	for s in rosters.ships:
		if s.side == 0: side0 += 1
		else: side1 += 1
	_check_eq(side0, 3, "side 0 line has three ships")
	_check_eq(side1, 2, "side 1 line has two ships")
	var rosters_on_board := true
	for s in rosters.ships:
		if not rosters.map_contains(s.hex):
			rosters_on_board = false
	_check(rosters_on_board, "every roster-deployed ship is on the board")
	_check(_no_ship_stacks(rosters), "no two roster-deployed ships share a hex")


## The data files are the single source of truth: the bundled res://data/*.json
## loads through the real ShipCatalog, every def survives a to_dict→from_dict
## round-trip, and the facade resolves through the active catalog. (Two defs are
## equal iff their to_dict() snapshots match — to_dict captures every field —
## compared via JSON.stringify, a stable compare since key order is fixed.)
func _test_catalog_migration() -> void:
	# Core only — point at a dir with no mods so we exercise the bundled data alone.
	var cat := ShipCatalog.new("res://__no_such_mod_dir__/")

	# The shipped catalog loads with the expected hulls and guns present.
	for gid in [&"light_gun", &"medium_gun", &"heavy_gun", &"aerial_torpedo"]:
		_check(cat.has_gun(gid), "shipped guns.json provides %s" % gid)
	for sid in [&"helium_scout", &"zodanga_cruiser", &"one_man_flyer", &"helium_battleship"]:
		_check(cat.has_ship(sid), "shipped ships.json provides %s" % sid)

	# Every def round-trips through serialization with no loss (enum + nested arrays).
	var guns_ok := true
	for gid in cat.gun_ids():
		var g := cat.gun(gid)
		if JSON.stringify(GunDef.from_dict(g.to_dict()).to_dict()) != JSON.stringify(g.to_dict()):
			guns_ok = false
	_check(guns_ok, "every shipped gun survives a to_dict→from_dict round-trip")
	var ships_ok := true
	for sid in cat.ship_ids():
		var s := cat.ship(sid)
		if JSON.stringify(ShipDef.from_dict(s.to_dict()).to_dict()) != JSON.stringify(s.to_dict()):
			ships_ok = false
	_check(ships_ok, "every shipped ship survives a to_dict→from_dict round-trip")

	# The facade reads the same catalog data (delegation works for the ~30 callers).
	_check_eq(ShipLibrary.ship(&"helium_scout").display_name, "Helium Scout Flyer",
			"ShipLibrary facade resolves a ship through the active catalog")


## Diff 2 (realism rebalance): every hull, with engine crew reserved for a cruising
## speed, can still man its full surviving battery within its (now realistic) CREW
## pool. Encodes the fix for the original "crew too small" complaint so it can't
## silently regress — while the engine cost keeps speed competing for the pool.
## The hand-authored ship specs: crews, speeds, acceleration, weapon loadouts, and
## the per-tube torpedo magazines. Locks the design so a future data edit (or a
## serialization regression like the dropped per-mount ammo) can't silently break it.
func _test_ship_loadouts() -> void:
	var s := ShipState.create(ShipLibrary.ship(&"helium_scout"), 0, Vector2i(0, 0), 0)
	_check_eq(s.crew_pool(), 6, "scout crew is 6")
	_check_eq(s.effective_max_speed(), 12, "scout top speed 12")
	_check_eq(s.max_speed_change(), 4, "scout acceleration 4")
	_check_eq(s.damage_control_capacity(), 0, "scout has no damage control")
	_check_eq(s.def.gun_mounts.size(), 2, "scout has two mounts (turret + tube)")
	_check_eq((s.def.gun_mounts[0]["arcs"] as Array).size(), 6, "scout turret covers all 6 arcs (360°)")
	_check_eq(int(s.gun_states[1]["ammo"]), 3, "scout torpedo tube holds 3")

	var o := ShipState.create(ShipLibrary.ship(&"one_man_flyer"), 0, Vector2i(0, 0), 0)
	_check_eq(o.crew_pool(), 1, "one-man crew is 1")
	_check_eq(o.effective_max_speed(), 16, "one-man top speed 16")
	_check_eq(o.max_speed_change(), 6, "one-man acceleration 6")
	_check_eq(o.damage_control_capacity(), 0, "one-man has no damage control")
	_check_eq(int(o.gun_states[1]["ammo"]), 1, "one-man torpedo is single-shot")
	# Fighter, not a gunboat: the lone pilot fires the nose gun AND the torpedo in
	# the same turn (the nose gun takes no dedicated crew).
	_check(o.apply_allocation({ "guns": [0, 1], "engine": 0, "damage_control": 0 }),
			"one-man can man both its weapons at once")
	_check(o.gun_states[0]["manned"] and o.gun_states[1]["manned"],
			"both the nose gun and the torpedo are manned together")

	_check_eq(ShipLibrary.ship(&"zodanga_cruiser").base_max_speed, 6, "cruiser top speed 6")
	_check_eq(ShipState.create(ShipLibrary.ship(&"zodanga_cruiser"), 0, Vector2i.ZERO, 0).max_speed_change(),
			2, "cruiser acceleration 2")
	_check_eq(ShipLibrary.ship(&"helium_battleship").base_max_speed, 4, "battleship top speed 4")
	_check_eq(ShipState.create(ShipLibrary.ship(&"helium_battleship"), 0, Vector2i.ZERO, 0).max_speed_change(),
			2, "battleship acceleration 2")


## The one-man fighter is its pilot: the single crew box is the whole crew, so one
## crew casualty empties the pool and the ship is finished (out of action, and the
## victory check wrecks it). A bigger hull shrugs off the same hit.
func _test_one_man_pilot_loss() -> void:
	var engine := TurnEngine.new()
	engine.setup_fleet([
		{ "ship_id": &"one_man_flyer", "side": 0, "hex": Vector2i(10, 10), "facing": 0 },
		{ "ship_id": &"helium_battleship", "side": 1, "hex": Vector2i(34, 10), "facing": 3 },
	], 1)
	var om := engine.ships[0]
	_check_eq(om.crew_pool(), 1, "one-man starts with its single crew box")
	# Strike the crew (no crit roll, so it's a clean box loss) — pool hits zero.
	DamageResolver._hit_system(om, ShipDef.SystemType.CREW, engine.rng, 0, false)
	_check_eq(om.crew_pool(), 0, "a single crew casualty empties the one-man's pool")
	_check(engine.is_out_of_action(om), "a crewless one-man is out of action")
	# The victory pass marks the crew-wiped fighter destroyed and ends the fight.
	engine._check_victory()
	_check(om.is_destroyed, "losing the pilot destroys the one-man flyer")
	_check_eq(engine.phase, TurnEngine.Phase.GAME_OVER,
			"the battleship wins once the lone fighter's pilot is lost")


func _test_rebalance_crew_budget() -> void:
	for sid in ShipLibrary.ship_ids():
		var def := ShipLibrary.ship(sid)
		var s := ShipState.create(def, 0, Vector2i(0, 0), 0)
		var gun_crew := 0
		for m in def.gun_mounts:
			gun_crew += ShipLibrary.gun(m["gun_id"]).crew_required
		if def.engine_crew_per_speed > 0:
			# Crew-gated engine (capital ships): the full battery is workable at a
			# cruising speed, but running flat-out costs more than the pool can
			# spare alongside the guns — speed competes for the crew.
			var cruise: int = maxi(1, def.base_max_speed / 2)
			_check(s.engine_crew_for_speed(cruise) + gun_crew <= s.crew_pool(),
					"%s can man its whole battery at cruise within its crew pool" % sid)
			_check(s.engine_crew_for_speed(def.base_max_speed) + gun_crew > s.crew_pool(),
					"%s cannot run flat-out AND man every gun (speed still competes)" % sid)
		else:
			# Pilot-flown small ships: the engine takes no crew and reaches its rated
			# top speed regardless, leaving the tiny crew for guns/torpedoes.
			_check_eq(s.engine_crew_for_speed(def.base_max_speed), 0,
					"%s has a free (crewless) engine" % sid)
			s.apply_allocation({ "guns": [], "engine": 0, "damage_control": 0 })
			_check_eq(s.usable_max_speed(), def.base_max_speed,
					"%s reaches full speed with no engine crew" % sid)


const TEST_MOD_ROOT := "user://test_mods"

## Write a JSON object to `path`, creating parent dirs. For building temp mods.
func _write_json(path: String, data: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()

## Recursively delete a directory (no built-in for this in Godot).
func _purge_dir(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var d := DirAccess.open(path)
	d.list_dir_begin()
	var entry := d.get_next()
	while entry != "":
		var full := path.path_join(entry)
		if d.current_is_dir():
			_purge_dir(full)
		else:
			DirAccess.remove_absolute(full)
		entry = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(path)


## Step 4: a malformed entry is skipped with the rest of the layer intact —
## never crashes the load, never poisons the catalog. (These deliberately trip
## validation, so ERROR lines in the output below are EXPECTED.)
func _test_catalog_validation() -> void:
	_purge_dir(TEST_MOD_ROOT)
	var good_gun := { "id": "mod_gun", "display_name": "Mod Gun", "size": "LIGHT",
		"reload_turns": 0, "crew_required": 1,
		"range_brackets": [{ "max_range": 2, "to_hit": 2, "damage": 2 }] }
	var bad_guns := [
		{ "id": "g_nosize", "display_name": "x", "reload_turns": 0, "crew_required": 1,
			"range_brackets": [{ "max_range": 2, "to_hit": 2, "damage": 2 }] },        # missing size
		{ "id": "g_badsize", "display_name": "x", "size": "PLASMA", "reload_turns": 0,
			"crew_required": 1, "range_brackets": [{ "max_range": 2, "to_hit": 2, "damage": 2 }] },
		{ "id": "g_noranges", "display_name": "x", "size": "LIGHT", "reload_turns": 0,
			"crew_required": 1, "range_brackets": [] },                                 # empty
		{ "id": "g_order", "display_name": "x", "size": "LIGHT", "reload_turns": 0, "crew_required": 1,
			"range_brackets": [{ "max_range": 4, "to_hit": 2, "damage": 2 },
				{ "max_range": 2, "to_hit": 2, "damage": 1 }] },                        # not increasing
	]
	_write_json(TEST_MOD_ROOT + "/zz_bad/guns.json", { "guns": [good_gun] + bad_guns })

	# A base ship (clone the battleship) plus corrupted variants.
	var base_ship := ShipLibrary.ship(&"helium_battleship").to_dict()
	var bad_armor := base_ship.duplicate(true); bad_armor["id"] = "s_armor"; bad_armor["armor"] = [1, 2, 3]
	var bad_sys := base_ship.duplicate(true); bad_sys["id"] = "s_sys"; bad_sys["systems"]["WARP"] = 3
	var bad_arc := base_ship.duplicate(true); bad_arc["id"] = "s_arc"
	bad_arc["gun_mounts"] = [{ "gun_id": "heavy_gun", "arcs": [9], "label": "x" }]
	_write_json(TEST_MOD_ROOT + "/zz_bad/ships.json", { "ships": [bad_armor, bad_sys, bad_arc] })

	var cat := ShipCatalog.new(TEST_MOD_ROOT + "/")
	_check(cat.has_gun(&"mod_gun"), "a valid mod gun loads")
	_check(not cat.has_gun(&"g_nosize"), "gun missing 'size' is rejected")
	_check(not cat.has_gun(&"g_badsize"), "gun with unknown size is rejected")
	_check(not cat.has_gun(&"g_noranges"), "gun with empty range_brackets is rejected")
	_check(not cat.has_gun(&"g_order"), "gun with non-increasing ranges is rejected")
	_check(not cat.has_ship(&"s_armor"), "ship with armor length != 6 is rejected")
	_check(not cat.has_ship(&"s_sys"), "ship with unknown system is rejected")
	_check(not cat.has_ship(&"s_arc"), "ship with arc outside 0..5 is rejected")
	# Core survives a bad mod entirely.
	_check(cat.has_ship(&"helium_scout") and cat.has_gun(&"heavy_gun"),
			"core ships/guns intact despite a malformed mod")
	_purge_dir(TEST_MOD_ROOT)


## Step 5: mod overlay — add a new hull, override a core hull by id (keeping its
## slot), drop a hull whose mount dangles, and load deterministically.
func _test_catalog_mods() -> void:
	_purge_dir(TEST_MOD_ROOT)
	var core_ship_ids := ShipLibrary.ship_ids()
	var core_ship_count := core_ship_ids.size()

	# ADD: a new hull cloned from the scout under a fresh id.
	var newship := ShipLibrary.ship(&"helium_scout").to_dict()
	newship["id"] = "test_corsair"
	newship["display_name"] = "Test Corsair"
	_write_json(TEST_MOD_ROOT + "/a_add/ships.json", { "ships": [newship] })

	# OVERRIDE: a full battleship def with CREW retuned up.
	var over := ShipLibrary.ship(&"helium_battleship").to_dict()
	over["systems"]["CREW"] = 999
	_write_json(TEST_MOD_ROOT + "/b_override/ships.json", { "ships": [over] })

	var cat := ShipCatalog.new(TEST_MOD_ROOT + "/")
	# Add lands after core, is fieldable, and gets a derived cost.
	_check(cat.has_ship(&"test_corsair"), "mod-added ship is present")
	_check_eq(cat.ship_ids().size(), core_ship_count + 1, "mod adds exactly one ship")
	_check_eq(cat.ship_ids()[cat.ship_ids().size() - 1], &"test_corsair",
			"mod-added ship sorts after the core hulls")
	_check(cat.ship(&"test_corsair").point_cost() >= 1, "mod-added ship gets a derived point_cost")
	# Override reflects the new value and keeps the battleship's original slot.
	_check_eq(cat.ship(&"helium_battleship").system_count(ShipDef.SystemType.CREW), 999,
			"mod override retunes the battleship's CREW")
	var core_bs_index := core_ship_ids.find(&"helium_battleship")
	_check_eq(cat.ship_ids().find(&"helium_battleship"), core_bs_index,
			"overridden hull keeps its original ordering slot")

	# DANGLING MOUNT: a hull mounting a gun no layer provides is dropped.
	var dangler := ShipLibrary.ship(&"helium_scout").to_dict()
	dangler["id"] = "test_ghost"
	dangler["gun_mounts"] = [{ "gun_id": "no_such_gun", "arcs": [0], "label": "Phantom" }]
	_write_json(TEST_MOD_ROOT + "/c_dangle/ships.json", { "ships": [dangler] })
	var cat2 := ShipCatalog.new(TEST_MOD_ROOT + "/")
	_check(not cat2.has_ship(&"test_ghost"), "hull with a dangling gun mount is dropped")

	# DETERMINISM: same dir, same order, twice.
	var a := ShipCatalog.new(TEST_MOD_ROOT + "/").ship_ids()
	var b := ShipCatalog.new(TEST_MOD_ROOT + "/").ship_ids()
	var same := a.size() == b.size()
	for i in a.size():
		if a[i] != b[i]:
			same = false
	_check(same, "two loads of the same mod set yield identical ship order")
	_purge_dir(TEST_MOD_ROOT)


## Step 5 (save hardening): a save naming a ship the active catalog no longer
## provides (a removed mod) declines cleanly — no half-built engine — and reports
## why. Restores the default catalog afterward so later tests see core data.
func _test_save_missing_dependency() -> void:
	var engine := TurnEngine.new()
	engine.setup_fleet([
		{ "ship_id": &"helium_scout", "side": 0, "hex": Vector2i(18, 12), "facing": 1 },
		{ "ship_id": &"zodanga_cruiser", "side": 1, "hex": Vector2i(30, 8), "facing": 4 },
	], 17)
	var text := SaveGame.serialize(engine)

	# Swap in a catalog with NO mods... that still has both core ships, so a normal
	# reload works and load_error clears.
	SaveGame.load_error = "stale"
	var ok := SaveGame.deserialize(text)
	_check(ok != null, "a save reloads while its ships exist")
	_check_eq(SaveGame.load_error, "", "load_error clears on a successful load")

	# Now inject a catalog missing the cruiser: the save must decline with a reason.
	# Build a fresh core catalog and erase one ship from it.
	var partial := ShipCatalog.new("user://__none__/")
	partial._ships.erase(&"zodanga_cruiser")
	ShipLibrary.use_catalog(partial)

	var declined := SaveGame.deserialize(text)
	_check(declined == null, "a save naming an absent ship class declines (no partial engine)")
	_check(SaveGame.load_error.find("zodanga_cruiser") != -1,
			"load_error names the missing ship class")

	ShipLibrary.reset_default()
	# Sanity: the facade is healthy again for the remaining tests.
	_check_eq(ShipLibrary.ship(&"zodanga_cruiser").id, &"zodanga_cruiser",
			"default catalog restored after the missing-dependency test")


func _test_deployment_rules() -> void:
	# A 1-v-1 with the player (side 0) west and the enemy parked deep in the east.
	var e := TurnEngine.new()
	e.setup_fleet([
		{ "ship_id": &"helium_scout", "side": 0, "hex": Vector2i(6, 12), "facing": 1 },
		{ "ship_id": &"zodanga_cruiser", "side": 1, "hex": Vector2i(40, 12), "facing": 4 },
	], 99)
	var player := e.ships[0]

	# A clean western hex, well clear of the enemy, is legal.
	_check(e.is_legal_deploy_hex(Vector2i(8, 12), 0),
			"clean hex inside the western band, far from the enemy, is legal")

	# Off-board is rejected.
	_check(not e.is_legal_deploy_hex(Vector2i(-3, 12), 0),
			"off-board deploy hex is rejected")

	# Outside the band (eastern half) is rejected even with no enemy nearby.
	_check(not e.is_legal_deploy_hex(Vector2i(TurnEngine.DEPLOY_ZONE_COLS, 12), 0),
			"hex past the deploy band is rejected for side 0")

	# Occupied by another (non-moving) ship is rejected; the same hex is fine when
	# that very ship is the one being moved.
	var p2 := ShipState.create(ShipLibrary.ship(&"one_man_flyer"), 0, Vector2i(8, 14), 1)
	e.ships.append(p2)
	_check(not e.is_legal_deploy_hex(Vector2i(8, 14), 0),
			"hex occupied by another ship is rejected")
	_check(e.is_legal_deploy_hex(Vector2i(8, 14), 0, p2),
			"the moving ship does not collide with its own current hex")
	e.ships.erase(p2)

	# Within the minimum separation of an enemy is rejected; one hex beyond is ok.
	# Place the enemy just past the band so both test hexes fall inside the band
	# and only the separation rule decides them.
	var wide := TurnEngine.new()
	wide.setup_fleet([
		{ "ship_id": &"helium_scout", "side": 0, "hex": Vector2i(2, 12), "facing": 1 },
		{ "ship_id": &"zodanga_cruiser", "side": 1,
			"hex": Vector2i(TurnEngine.DEPLOY_ZONE_COLS + 2, 12), "facing": 4 },
	], 7)
	var foe := wide.ships[1]
	var inside := foe.hex - Vector2i(TurnEngine.DEPLOY_MIN_SEPARATION - 1, 0)
	var beyond := foe.hex - Vector2i(TurnEngine.DEPLOY_MIN_SEPARATION, 0)
	if wide._in_deploy_band(inside, 0):
		_check(not wide.is_legal_deploy_hex(inside, 0),
				"hex within DEPLOY_MIN_SEPARATION of an enemy is rejected")
	if wide._in_deploy_band(beyond, 0):
		_check(wide.is_legal_deploy_hex(beyond, 0),
				"hex exactly DEPLOY_MIN_SEPARATION from an enemy is legal")

	# legal_deploy_hexes returns only legal hexes, all inside the band.
	var hexes := e.legal_deploy_hexes(0, player)
	_check(hexes.size() > 0, "legal_deploy_hexes finds room for the player")
	var all_legal := true
	for h in hexes:
		if not e.is_legal_deploy_hex(h, 0, player) or h.x >= TurnEngine.DEPLOY_ZONE_COLS:
			all_legal = false
	_check(all_legal, "every hex from legal_deploy_hexes is legal and in-band")

	# place_ship moves a ship to a legal hex and refuses an illegal one.
	_check(e.place_ship(player, Vector2i(10, 10), 3),
			"place_ship accepts a legal hex")
	_check_eq(player.hex, Vector2i(10, 10), "place_ship moved the ship")
	_check_eq(player.facing, 3, "place_ship set the new facing")
	var before := player.hex
	_check(not e.place_ship(player, Vector2i(45, 10), 0),
			"place_ship refuses an out-of-band hex")
	_check_eq(player.hex, before, "a refused place_ship leaves the ship put")

	# The shipped default roster layout must itself be fully legal — no ship
	# starts off its own side or inside the enemy's striking distance.
	var def := TurnEngine.new()
	def.setup_rosters(
		[&"helium_scout", &"one_man_flyer"],
		[&"zodanga_cruiser", &"helium_battleship"], 321)
	var default_legal := true
	for s in def.ships:
		if not def.is_legal_deploy_hex(s.hex, s.side, s):
			default_legal = false
	_check(default_legal, "default roster layout is a legal deployment for both sides")


func _test_side_victory() -> void:
	# A 2-v-2 fleet: victory is now per-side, not the instant one ship falls.
	var engine := TurnEngine.new()
	engine.setup_fleet([
		{ "ship_id": &"helium_scout", "side": 0, "hex": Vector2i(18, 12), "facing": 1 },
		{ "ship_id": &"one_man_flyer", "side": 0, "hex": Vector2i(18, 14), "facing": 1 },
		{ "ship_id": &"zodanga_cruiser", "side": 1, "hex": Vector2i(30, 8), "facing": 4 },
		{ "ship_id": &"helium_battleship", "side": 1, "hex": Vector2i(30, 10), "facing": 4 },
	], 13)
	var result := { "winner": -2, "fired": false }
	engine.game_over.connect(func(side: int, _r: String) -> void:
		result["winner"] = side
		result["fired"] = true)

	_check_eq(engine.living_ships(0).size(), 2, "side 0 starts with two live ships")
	_check(engine.side_alive(1), "side 1 starts alive")

	# Lose ONE ship on side 0 — the side still flies, so no game over.
	engine.ships[0].is_destroyed = true
	engine._check_victory()
	_check_eq(engine.living_ships(0).size(), 1, "side 0 down to one live ship")
	_check(engine.side_alive(0), "a side with one of two ships left has NOT lost")
	_check(not result["fired"], "game does not end while a side still has a flyer")
	_check_eq(engine.phase, TurnEngine.Phase.ALLOCATION, "phase unchanged mid-battle")

	# Lose the second ship on side 0 — the whole side is out; side 1 wins.
	engine.ships[1].grounded = true
	engine._check_victory()
	_check(result["fired"], "game ends only on full-side wipeout")
	_check_eq(int(result["winner"]), 1, "the side with a live ship is the winner")
	_check_eq(engine.phase, TurnEngine.Phase.GAME_OVER, "engine enters GAME_OVER")

	# A re-check after game over must not re-fire the signal.
	result["fired"] = false
	engine._check_victory()
	_check(not result["fired"], "victory is not re-declared once the game is over")

	# Mutual wipeout in the same resolution → a draw (side -1).
	var draw := TurnEngine.new()
	draw.setup_fleet([
		{ "ship_id": &"helium_scout", "side": 0, "hex": Vector2i(18, 12), "facing": 1 },
		{ "ship_id": &"zodanga_cruiser", "side": 1, "hex": Vector2i(30, 8), "facing": 4 },
	], 21)
	var draw_res := { "winner": -2 }
	draw.game_over.connect(func(side: int, _r: String) -> void: draw_res["winner"] = side)
	draw.ships[0].is_destroyed = true
	draw.ships[1].is_destroyed = true
	draw._check_victory()
	_check_eq(int(draw_res["winner"]), -1, "both sides emptied at once is a draw (side -1)")

	# is_out_of_action folds in the crew-wipe condition, and _check_victory marks
	# a crew-wiped ship destroyed before tallying sides.
	var crew := TurnEngine.new()
	crew.setup(99)
	crew.ships[0].systems_remaining[ShipDef.SystemType.CREW] = 0
	_check(crew.is_out_of_action(crew.ships[0]), "a crew-wiped ship is out of action")
	var crew_res := { "winner": -2 }
	crew.game_over.connect(func(side: int, _r: String) -> void: crew_res["winner"] = side)
	crew._check_victory()
	_check(crew.ships[0].is_destroyed, "crew-wiped ship is marked destroyed at the victory check")
	_check_eq(int(crew_res["winner"]), 1, "crew wipe loses the side the engagement")


func _test_fleet_cadence() -> void:
	# The shared impulse sequencer must interleave 4+ ships at mixed speeds: each
	# ship is offered exactly the number of impulses the chart says it moves on.
	var engine := TurnEngine.new()
	engine.setup_fleet([
		{ "ship_id": &"helium_scout", "side": 0, "hex": Vector2i(16, 14), "facing": 1 },
		{ "ship_id": &"one_man_flyer", "side": 0, "hex": Vector2i(16, 16), "facing": 1 },
		{ "ship_id": &"zodanga_cruiser", "side": 1, "hex": Vector2i(30, 6), "facing": 4 },
		{ "ship_id": &"helium_battleship", "side": 1, "hex": Vector2i(30, 8), "facing": 4 },
	], 31337)
	var speeds := [8, 4, 2, 6]
	for i in 4:
		engine.ships[i].speed = speeds[i]
	# Expected offer count per ship, straight from the impulse chart.
	var expected: Array[int] = []
	for i in 4:
		var c := 0
		for imp in range(1, TurnEngine.IMPULSES_PER_TURN + 1):
			if TurnEngine.moves_on_impulse(speeds[i], imp):
				c += 1
		expected.append(c)

	var impulses_seen := { "n": 0 }
	var movers_per_impulse: Array[int] = []
	engine.impulse_advanced.connect(func(_imp: int, movers: Array) -> void:
		impulses_seen["n"] = int(impulses_seen["n"]) + 1
		movers_per_impulse.append(movers.size()))

	engine.begin_movement()
	var offered := [0, 0, 0, 0]
	var guard := 0
	while guard < 200:
		guard += 1
		var s: ShipState = engine.next_mover()
		if s == null:
			break
		offered[engine.ships.find(s)] += 1

	_check_eq(int(impulses_seen["n"]), TurnEngine.IMPULSES_PER_TURN,
			"all 8 impulses open with four ships in the sequence")
	var cadence_ok := true
	for i in 4:
		if offered[i] != expected[i]:
			cadence_ok = false
	_check(cadence_ok, "each of 4 mixed-speed ships is offered exactly its chart count")
	_check_eq(movers_per_impulse[0], 1, "only the speed-8 ship moves on impulse 1")
	_check_eq(movers_per_impulse[7], 4, "all four ships move on impulse 8")


func _test_fleet_ai_battle() -> void:
	# A seeded 2-v-2 driven entirely through the engine's shared sequencer with a
	# ShipAI per hull resolves decisively, no deadlock, no invariant violations.
	var decided := 0
	var clean_all := true
	for seed_i in [1, 2, 3, 4, 5]:
		var engine := TurnEngine.new()
		engine.setup_rosters(
			[&"helium_scout", &"one_man_flyer"],
			[&"zodanga_cruiser", &"helium_battleship"], seed_i * 6151 + 7)
		var r := _play_out_fleet(engine)
		if not bool(r["clean"]):
			clean_all = false
		if int(r["winner"]) != -2:   # -2 == hit the turn cap (indecisive)
			decided += 1
	_check(clean_all, "2v2 ShipAI battles keep every box count >= 0")
	_check(decided >= 4, "at least 4 of 5 2v2 ShipAI battles reach a decisive result (got %d)" % decided)


## Drive a fully set-up N-ship engine with a ShipAI per hull until it resolves or
## hits the turn cap, using the engine's own begin_movement/next_mover sequencer.
## Returns { "winner": int (-2 if capped), "clean": bool }.
func _play_out_fleet(engine: TurnEngine) -> Dictionary:
	var brains := {}
	for s in engine.ships:
		brains[s] = ShipAI.for_ship(s.def)
	var res := { "winner": -2, "clean": true }
	engine.game_over.connect(func(side: int, _r: String) -> void: res["winner"] = side)
	var cap := 100
	while engine.phase != TurnEngine.Phase.GAME_OVER and engine.turn_number <= cap:
		for s in engine.ships:
			if not engine.is_out_of_action(s):
				brains[s].allocate(engine, s)
		for s in engine.ships:
			if not engine.is_out_of_action(s):
				brains[s].plot(engine, s)
		engine.begin_movement()
		var guard := 0
		while guard < 400:
			guard += 1
			var s: ShipState = engine.next_mover()
			if s == null:
				break
			var moves := engine.legal_moves_for(s)
			if not moves.is_empty():
				engine.execute_move(s, brains[s].choose_move(engine, s, moves))
		for s in engine.ships:
			if engine.is_out_of_action(s):
				continue
			var enemy := _nearest_living_enemy(engine, s)
			if enemy == null:
				continue
			for mi in brains[s].choose_fire(s, enemy, engine.terrain):
				engine.declare_fire(s, mi, enemy)
		engine.resolve_fire_phase()
		for sh in engine.ships:
			for a in sh.armor_remaining:
				if a < 0:
					res["clean"] = false
			for t in sh.systems_remaining.keys():
				if int(sh.systems_remaining[t]) < 0:
					res["clean"] = false
			if sh.port_buoyancy < 0 or sh.stbd_buoyancy < 0:
				res["clean"] = false
		if engine.phase == TurnEngine.Phase.GAME_OVER:
			break
		engine.run_upkeep()
	return res


func _test_point_cost() -> void:
	# Determinism: a class prices identically every call.
	var scout := ShipLibrary.ship(&"helium_scout")
	_check_eq(scout.point_cost(), scout.point_cost(), "point_cost is deterministic")

	# Ordering: a heavier hull always costs more than a lighter one.
	var one_man := ShipLibrary.ship(&"one_man_flyer").point_cost()
	var sc := ShipLibrary.ship(&"helium_scout").point_cost()
	var cr := ShipLibrary.ship(&"zodanga_cruiser").point_cost()
	var bb := ShipLibrary.ship(&"helium_battleship").point_cost()
	_check(one_man < sc and sc < cr and cr < bb,
			"cost is monotone: one-man < scout < cruiser < battleship (%d<%d<%d<%d)" % [one_man, sc, cr, bb])

	# Adding a gun raises the cost; adding armour raises the cost.
	var base := ShipLibrary.ship(&"helium_scout").point_cost()
	var more_guns := ShipLibrary.ship(&"helium_scout").duplicate(true) as ShipDef
	var mounts := more_guns.gun_mounts.duplicate()
	mounts.append({ "gun_id": &"heavy_gun", "arcs": [0, 1, 5], "label": "Extra Battery" })
	more_guns.gun_mounts.assign(mounts)
	_check(more_guns.point_cost() > base, "adding a gun mount raises the cost")

	var more_armor := ShipLibrary.ship(&"helium_scout").duplicate(true) as ShipDef
	var arm := more_armor.armor.duplicate()
	arm[0] += 5
	more_armor.armor.assign(arm)
	_check(more_armor.point_cost() > base, "adding armour raises the cost")

	# Non-linearity: one strong hull costs MORE than two weak hulls whose stats
	# sum to it (convex exponents + the offence×defence cross term).
	var strong := _scaled_hull(2)
	var weak := _scaled_hull(1)
	_check(strong.point_cost() > 2 * weak.point_cost(),
			"one strong hull (%d) costs more than two half-hulls (2x%d) of the same raw stats" % [
			strong.point_cost(), weak.point_cost()])

	# An override pins the cost, bypassing the derivation.
	var pinned := ShipLibrary.ship(&"helium_scout").duplicate(true) as ShipDef
	pinned.point_cost_override = 999
	_check_eq(pinned.point_cost(), 999, "point_cost_override pins the cost")


## A synthetic hull scaled by `m`: every cost-driving stat is m× the base, so
## _scaled_hull(2) has exactly the summed raw stats of two _scaled_hull(1)s.
func _scaled_hull(m: int) -> ShipDef:
	var d := ShipDef.new()
	d.id = &"synth_hull"
	d.display_name = "Synthetic Hull"
	var av := 4 * m
	d.armor.assign([av, av, av, av, av, av])
	var mounts: Array[Dictionary] = []
	for _i in 3 * m:
		mounts.append({ "gun_id": &"heavy_gun", "arcs": [0, 1], "label": "Battery" })
	d.gun_mounts.assign(mounts)
	d.systems = {
		ShipDef.SystemType.BUOYANCY: 10 * m,
		ShipDef.SystemType.ENGINE: 4 * m,
		ShipDef.SystemType.PROPELLER: 2 * m,
		ShipDef.SystemType.RUDDER: 2 * m,
		ShipDef.SystemType.BRIDGE: 1 * m,
		ShipDef.SystemType.CREW: 10 * m,
		ShipDef.SystemType.MAGAZINE: 1 * m,
		ShipDef.SystemType.DAMAGE_CONTROL: 1 * m,
	}
	d.base_max_speed = 4 * m
	d.engine_crew_per_speed = 2
	d.turn_mode_by_speed.assign([2, 2, 2, 2])
	return d


func _test_fleet_builder() -> void:
	var classes := FleetBuilder.available_classes()
	_check(classes.size() >= 4, "catalog lists every ship class")
	_check(classes[0].has("id") and classes[0].has("display_name") and classes[0].has("point_cost"),
			"catalog entries carry id / display_name / point_cost")

	var scout_cost := ShipLibrary.ship(&"helium_scout").point_cost()
	var cruiser_cost := ShipLibrary.ship(&"zodanga_cruiser").point_cost()
	_check_eq(FleetBuilder.roster_cost([&"helium_scout", &"helium_scout"]), scout_cost * 2,
			"roster_cost sums the class costs")

	_check(FleetBuilder.is_valid([&"helium_scout"], scout_cost),
			"a roster exactly on budget is valid")
	_check(not FleetBuilder.is_valid([&"zodanga_cruiser"], cruiser_cost - 1),
			"an over-budget roster is rejected")
	_check(not FleetBuilder.is_valid([], 1000), "an empty roster is invalid")

	# Seeded generation: deterministic, within budget, non-empty.
	var rng1 := RandomNumberGenerator.new()
	rng1.seed = 12345
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = 12345
	var r1 := FleetBuilder.generate_roster(300, rng1)
	var r2 := FleetBuilder.generate_roster(300, rng2)
	_check_eq(r1, r2, "generate_roster is deterministic for a fixed seed")
	_check(not r1.is_empty(), "generated roster is non-empty")
	_check(FleetBuilder.roster_cost(r1) <= 300, "generated roster stays within budget (%d <= 300)" % FleetBuilder.roster_cost(r1))
	# A budget below the cheapest hull still yields a (single, fallback) ship.
	var rng3 := RandomNumberGenerator.new()
	rng3.seed = 7
	_check(not FleetBuilder.generate_roster(1, rng3).is_empty(),
			"a tiny budget still fields one fallback hull")


## Nearest living enemy of `s` across the whole fleet (mirrors ShipAI._enemy).
func _nearest_living_enemy(engine: TurnEngine, s: ShipState) -> ShipState:
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


## True when no two live ships occupy the same hex (the no-stack collision rule).
func _no_ship_stacks(engine: TurnEngine) -> bool:
	var seen: Array[Vector2i] = []
	for s in engine.ships:
		if s.hex in seen:
			return false
		seen.append(s.hex)
	return true


func _test_ai_battle() -> void:
	# ShipAI on both sides, on the bounded map, terminates decisively without
	# deadlock or invariant violations.
	var decided := 0
	for seed_i in [1, 2, 3, 4, 5]:
		var r := _run_ai_battle(seed_i * 7919 + 1)
		_check(r["clean"], "AI battle (seed key %d) kept every box count >= 0" % seed_i)
		if int(r["winner"]) >= 0:
			decided += 1
	_check(decided >= 4, "at least 4 of 5 ShipAI battles reach a decisive result (got %d)" % decided)


func _run_ai_battle(seed_val: int) -> Dictionary:
	var engine := TurnEngine.new()
	engine.setup(seed_val)
	return _play_out(engine)


## Set two named classes nose-to-nose on the open field and let two ShipAIs
## fight it out — for exercising matchups the default setup() doesn't cover.
func _run_ai_battle_classes(a_id: StringName, b_id: StringName, seed_val: int) -> Dictionary:
	var engine := TurnEngine.new()
	engine.setup(seed_val)   # seeds rng + places terrain
	engine.ships.assign([
		ShipState.create(ShipLibrary.ship(a_id), 0, Vector2i(18, 12), 1),
		ShipState.create(ShipLibrary.ship(b_id), 1, Vector2i(30, 6), 4),
	])
	return _play_out(engine)


## Drive a fully set-up two-ship engine with a ShipAI per side until it resolves
## or hits the turn cap. Returns { "winner": int, "clean": bool }.
func _play_out(engine: TurnEngine) -> Dictionary:
	var brains := [ShipAI.for_ship(engine.ships[0].def), ShipAI.for_ship(engine.ships[1].def)]
	return _play_out_brains(engine, brains)


## Same as _play_out, but with caller-supplied brains (one per side) — lets the
## lookahead suite pit a rollout captain against the plain 1-ply one.
func _play_out_brains(engine: TurnEngine, brains: Array) -> Dictionary:
	var res := { "winner": -1, "clean": true }
	engine.game_over.connect(func(side: int, _r: String) -> void: res["winner"] = side)
	var cap := 80
	while engine.phase != TurnEngine.Phase.GAME_OVER and engine.turn_number <= cap:
		for i in 2:
			brains[i].allocate(engine, engine.ships[i])
		for i in 2:
			brains[i].plot(engine, engine.ships[i])
		for imp in range(1, TurnEngine.IMPULSES_PER_TURN + 1):
			for i in 2:
				var s: ShipState = engine.ships[i]
				if not TurnEngine.moves_on_impulse(s.speed, imp) or s.is_destroyed or s.grounded:
					continue
				var moves := engine.legal_moves_for(s)   # engine-bounded
				if not moves.is_empty():
					engine.execute_move(s, brains[i].choose_move(engine, s, moves))
		for i in 2:
			var enemy: ShipState = engine.ships[1 - i]
			for mi in brains[i].choose_fire(engine.ships[i], enemy, engine.terrain):
				engine.declare_fire(engine.ships[i], mi, enemy)
		engine.resolve_fire_phase()
		for s in engine.ships:
			for a in s.armor_remaining:
				if a < 0:
					res["clean"] = false
			for t in s.systems_remaining.keys():
				if int(s.systems_remaining[t]) < 0:
					res["clean"] = false
			if s.port_buoyancy < 0 or s.stbd_buoyancy < 0:
				res["clean"] = false
		if engine.phase == TurnEngine.Phase.GAME_OVER:
			break
		engine.run_upkeep()
	return res


# ---------------------------------------------------------------------------
# Save / load: serialize the engine (ships + RNG + turn/phase + queues) and
# restore it exactly — the persistence layer is pure rules, headless-testable.
# ---------------------------------------------------------------------------

func _test_save_roundtrip() -> void:
	# Build an engine, then rough up the state so every serialized field carries
	# a non-default value: damage, criticals, allocation, a struck officer, a
	# spent torpedo, and a mid-MOVEMENT phase with an in-flight impulse.
	var engine := TurnEngine.new()
	engine.setup(20260613)
	engine.turn_number = 7
	var scout := engine.ships[0]
	var cruiser := engine.ships[1]
	scout.armor_remaining[0] = 1
	scout.systems_remaining[ShipDef.SystemType.ENGINE] = 2
	scout.fires = 2
	scout.steering_jammed = 1
	scout.pop_officer()
	scout.gun_states[1]["ammo"] = 1            # torpedo tube (mount 1) part-spent
	scout.gun_states[0]["reload"] = 2
	scout.port_buoyancy = 3
	scout.stbd_buoyancy = 5
	# Scout is a free-engine, no-DC flyer: man its turret + tube (engine/DC take no crew).
	scout.apply_allocation({ "guns": [0, 1], "engine": 0, "damage_control": 0, "lookout": 0 })
	cruiser.is_destroyed = false
	cruiser.speed = 4
	# The cruiser carries the non-zero engine allocation (its engine is crew-gated).
	cruiser.apply_allocation({ "guns": [0], "engine": 30, "damage_control": 1, "lookout": 0 })
	# Open movement so current_impulse and the movement queue are non-empty.
	engine.begin_movement()
	engine.next_mover()

	var text := SaveGame.serialize(engine)
	var loaded := SaveGame.deserialize(text)
	_check(loaded != null, "deserialize returns a live engine")

	_check_eq(loaded.turn_number, 7, "turn_number round-trips")
	_check_eq(loaded.phase, engine.phase, "phase round-trips")
	_check_eq(loaded.current_impulse, engine.current_impulse, "current_impulse round-trips")
	_check_eq(loaded.map_cols, engine.map_cols, "map_cols round-trips")
	_check_eq(loaded.terrain.size(), engine.terrain.size(), "terrain map round-trips")
	_check_eq(loaded.ships.size(), 2, "both ships restored")

	var ls := loaded.ships[0]
	_check_eq(String(ls.def.id), "helium_scout", "ship def rebuilt from library by id")
	_check_eq(ls.armor_remaining[0], 1, "damaged armor facing round-trips")
	_check_eq(ls.sys(ShipDef.SystemType.ENGINE), 2, "eroded system count round-trips")
	_check_eq(ls.fires, 2, "fire count round-trips")
	_check_eq(ls.steering_jammed, 1, "steering jam round-trips")
	_check_eq(ls.officers.size(), scout.officers.size(), "struck officer roster round-trips")
	_check_eq(int(ls.gun_states[1]["ammo"]), 1, "torpedo ammo round-trips")
	_check_eq(int(ls.gun_states[0]["reload"]), 2, "gun reload counter round-trips")
	_check_eq(ls.port_buoyancy, 3, "port buoyancy round-trips")
	_check_eq(ls.stbd_buoyancy, 5, "stbd buoyancy round-trips")
	_check_eq(int(loaded.ships[1].allocation.get("engine", -1)), 30,
			"engine allocation round-trips (cruiser)")
	_check_eq(ls.gun_states[0]["manned"], true, "manned flag (from allocation) round-trips")
	# Typed-array element types survive the round-trip (convention #1).
	_check(ls.armor_remaining.get_typed_builtin() == TYPE_INT, "armor_remaining stays Array[int]")
	# The movement queue restored to live ShipStates, not dangling indices.
	var mq_ok := true
	for m in loaded._movement_queue:
		if not (m in loaded.ships):
			mq_ok = false
	_check(mq_ok, "movement queue restored to the loaded engine's ships")


func _test_save_rng_determinism() -> void:
	# The whole point of saving rng_state: a restored engine continues the exact
	# same random sequence, so replays and resumed games are deterministic.
	var engine := TurnEngine.new()
	engine.setup(424242)
	# Burn a few rolls so we're mid-stream, not at the seed boundary.
	for _i in 5:
		engine.rng.randi()

	var text := SaveGame.serialize(engine)
	var expected: Array[int] = []
	for _i in 10:
		expected.append(engine.rng.randi())

	var loaded := SaveGame.deserialize(text)
	var got: Array[int] = []
	for _i in 10:
		got.append(loaded.rng.randi())
	_check_eq(got, expected, "restored RNG reproduces the original's next 10 rolls")

	# And the saved fire queue resolves identically on the restored engine.
	var e2 := TurnEngine.new()
	e2.setup(99887766)
	var a := e2.ships[0]
	var b := e2.ships[1]
	a.hex = Vector2i(10, 5)
	b.hex = Vector2i(12, 5)
	a.facing = 1
	a.apply_allocation({ "guns": [0], "engine": 1, "damage_control": 0 })
	a.gun_states[0]["reload"] = 0
	var bearing := a.guns_bearing(b.hex, e2.terrain)
	if not bearing.is_empty():
		e2.declare_fire(a, bearing[0], b)
		var save2 := SaveGame.serialize(e2)
		# Resolve on the original.
		e2.resolve_fire_phase()
		var orig_armor := (b.armor_remaining as Array).duplicate()
		# Resolve on a freshly loaded copy.
		var e3 := SaveGame.deserialize(save2)
		e3.resolve_fire_phase()
		_check_eq((e3.ships[1].armor_remaining as Array), orig_armor,
				"saved fire queue + RNG resolve to identical damage")
	else:
		_check(true, "saved fire queue + RNG resolve to identical damage (no bearing; skipped)")


func _test_save_file_and_rejects() -> void:
	var engine := TurnEngine.new()
	engine.setup(7777)
	engine.turn_number = 3
	var path := "user://test_save.flyersave"
	var err := SaveGame.save_to_file(engine, path)
	_check_eq(err, OK, "save_to_file writes without error")
	var loaded := SaveGame.load_from_file(path)
	_check(loaded != null and loaded.turn_number == 3, "load_from_file restores the engine")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	# Corrupt / unknown input is rejected, not crashed on.
	_check(SaveGame.deserialize("not a dictionary at all") == null, "garbage text rejected")
	_check(SaveGame.deserialize(var_to_str({ "version": 9999 })) == null, "unknown version rejected")
	_check(SaveGame.load_from_file("user://does_not_exist.flyersave") == null,
			"missing file load returns null")


# ---------------------------------------------------------------------------
# Smoke battle: a full game with greedy AI on both sides
# ---------------------------------------------------------------------------

func _test_full_battle() -> void:
	var engine := TurnEngine.new()
	engine.setup(20260611)

	var log: Array[String] = []
	var result := { "winner": -1 }
	engine.shot_resolved.connect(func(r: Dictionary) -> void:
		if r["hit"]:
			var line := "    T%d %s/%s hits %s on facing %d for %d (armor %d, internals %d)" % [
				engine.turn_number, r["firer"], r["gun"], r["target"],
				r["facing_struck"], r["damage"], r["armor_absorbed"],
				(r["internals"] as Array).size()]
			log.append(line)
			for hit in r["internals"]:
				log.append("        -> %s: %s" % [hit["system"], hit["effect"]])
	)
	engine.game_over.connect(func(side: int, reason: String) -> void:
		result["winner"] = side
		log.append("    GAME OVER: side %d wins (%s)" % [side, reason])
	)

	var max_turns := 60
	while engine.phase != TurnEngine.Phase.GAME_OVER and engine.turn_number <= max_turns:
		# ALLOCATION: greedy — reserve engine crew for the speed we want this
		# turn, then man every surviving gun the rest of the pool can afford.
		for s in engine.ships:
			var enemy0: ShipState = engine.ships[1 - s.side]
			var want: int = s.effective_max_speed() if HexMath.distance(s.hex, enemy0.hex) > 4 \
					else max(s.effective_max_speed() / 2, 1)
			var eng_crew: int = min(s.engine_crew_for_speed(want), s.crew_pool())
			var crew_left := s.crew_pool() - eng_crew
			var gun_picks: Array[int] = []
			for i in s.def.gun_mounts.size():
				if s.gun_states[i]["destroyed"]:
					continue
				var cost: int = ShipLibrary.gun(s.def.gun_mounts[i]["gun_id"]).crew_required
				if crew_left >= cost:
					gun_picks.append(i)
					crew_left -= cost
			s.apply_allocation({ "guns": gun_picks, "engine": eng_crew,
					"damage_control": crew_left })

		# PLOT: close to range 3, then slow down — bounded by the crew-gated
		# usable speed (engine crew was reserved above).
		for s in engine.ships:
			var enemy: ShipState = engine.ships[1 - s.side]
			var dist := HexMath.distance(s.hex, enemy.hex)
			var desired: int = s.effective_max_speed() if dist > 4 else \
					max(s.effective_max_speed() / 2, 1)
			var delta: int = clamp(desired - s.speed, -s.max_speed_change(), s.max_speed_change())
			s.speed = clamp(s.speed + delta, 0, s.usable_max_speed())

		# MOVEMENT: 8 impulses. Score = distance first, then prefer keeping the
		# nose on the enemy — without the bearing tiebreak, two ships that
		# joust past each other never turn around (min() ties favor straight)
		# and fly apart forever. Ask me how I know.
		for imp in range(1, TurnEngine.IMPULSES_PER_TURN + 1):
			for s in engine.ships:
				if not TurnEngine.moves_on_impulse(s.speed, imp):
					continue
				var moves := engine.legal_moves_for(s)
				if moves.is_empty():
					continue
				var enemy: ShipState = engine.ships[1 - s.side]
				var best: Dictionary = moves[0]
				var best_score := 999999
				for m in moves:
					var d := HexMath.distance(m["hex"], enemy.hex)
					var rb := HexMath.relative_bearing(m["hex"], m["facing"], enemy.hex)
					var off: int = 0 if rb == -1 else mini(rb, 6 - rb)
					var score := d * 10 + off
					if score < best_score:
						best_score = score
						best = m
				engine.execute_move(s, best)

		# FIRE: everything that bears, shoots.
		for s in engine.ships:
			var enemy: ShipState = engine.ships[1 - s.side]
			for mi in s.guns_bearing(enemy.hex):
				engine.declare_fire(s, mi, enemy)
		engine.resolve_fire_phase()

		# UPKEEP
		if engine.phase != TurnEngine.Phase.GAME_OVER:
			engine.run_upkeep()

	print("\n  Combat log (%d entries):" % log.size())
	for line in log:
		print(line)

	_check(int(result["winner"]) != -1, "battle reaches a decisive result within %d turns" % max_turns)
	_check(not log.is_empty(), "combat log captured hits via signals")
	# State invariants after a full game: nothing went negative.
	var invariants_ok := true
	for s in engine.ships:
		for a in s.armor_remaining:
			if a < 0:
				invariants_ok = false
		for t in s.systems_remaining.keys():
			if int(s.systems_remaining[t]) < 0:
				invariants_ok = false
	_check(invariants_ok, "no armor or system box count went negative during the battle")


# ---------------------------------------------------------------------------
# Critical hits: fires, steering jams, named officer casualties
# ---------------------------------------------------------------------------

## Smallest seed whose FIRST rng.randi_range(1,6) lands in [lo, hi]. Lets a test
## force a single crit roll deterministically when that roll is the first the
## injected rng makes.
func _seed_first_roll(lo: int, hi: int) -> int:
	for cand in range(1, 4000):
		var p := RandomNumberGenerator.new()
		p.seed = cand
		var r := p.randi_range(1, 6)
		if r >= lo and r <= hi:
			return cand
	return -1


## Total surviving "capability": system boxes plus live gun mounts. A burning
## fire eats one of these each turn (a box or a mount), so this strictly drops.
func _capability_sum(s: ShipState) -> int:
	var total := 0
	for t in s.systems_remaining.keys():
		total += int(s.systems_remaining[t])
	for g in s.gun_states:
		if not g["destroyed"]:
			total += 1
	return total


func _armor_total(def: ShipDef) -> int:
	var total := 0
	for a in def.armor:
		total += int(a)
	return total


func _test_steering_jam() -> void:
	var ship := ShipState.create(ShipLibrary.ship(&"helium_scout"), 0, Vector2i(0, 0), 0)
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed_first_roll(5, 6)   # rudder jam needs a 5+
	DamageResolver._hit_system(ship, ShipDef.SystemType.RUDDER, rng, 0)
	_check(ship.steering_jammed > 0, "a rudder crit (roll 5+) jams the steering")
	_check(not ship.can_turn(), "a jammed ship cannot turn")

	# Even with turn mode fully satisfied, only the straight move is offered.
	ship.straight_moved = 99
	var has_turn := false
	for m in TurnEngine.legal_moves(ship, []):
		if m["kind"] != "straight":
			has_turn = true
	_check(not has_turn, "a jammed ship's legal moves are straight-only")

	# A clean rudder hit (roll 4-) does not jam.
	var ship2 := ShipState.create(ShipLibrary.ship(&"helium_scout"), 0, Vector2i(0, 0), 0)
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = _seed_first_roll(1, 4)
	DamageResolver._hit_system(ship2, ShipDef.SystemType.RUDDER, rng2, 0)
	_check_eq(ship2.steering_jammed, 0, "a rudder hit rolling 4- leaves the steering free")

	# The jam works free over upkeeps: set to 2, it survives one upkeep (still
	# jammed for the next movement phase) and clears on the second.
	var engine := TurnEngine.new()
	engine.setup(1)
	var s := engine.ships[0]
	s.steering_jammed = 2
	engine.run_upkeep()
	_check_eq(s.steering_jammed, 1, "jam ticks down one at upkeep (still fouled next move)")
	engine.run_upkeep()
	_check_eq(s.steering_jammed, 0, "jam clears after a second upkeep")


func _test_fire_ignite_and_burn() -> void:
	# An engine crit on a 6 starts a fire.
	var ship := ShipState.create(ShipLibrary.ship(&"helium_scout"), 0, Vector2i(0, 0), 0)
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed_first_roll(6, 6)
	DamageResolver._hit_system(ship, ShipDef.SystemType.ENGINE, rng, 0)
	_check(ship.fires >= 1, "an engine crit (roll 6) lights a fire")

	# An unfought fire burns a box at upkeep and keeps burning.
	var engine := TurnEngine.new()
	engine.setup(1)
	var cruiser := engine.ships[1]   # big enough that one burn can't sink it
	cruiser.fires = 1
	var before := _capability_sum(cruiser)
	var burns := { "n": 0 }
	engine.fire_changed.connect(func(_sh: ShipState, _f: int, _note: String) -> void:
		burns["n"] += 1)
	engine.run_upkeep()
	_check(int(burns["n"]) >= 1, "an active fire produces a burn event at upkeep")
	_check(_capability_sum(cruiser) < before, "an unfought fire eats a box or mount")
	_check(cruiser.fires >= 1, "the fire keeps burning without damage control")


func _test_fire_doused() -> void:
	var engine := TurnEngine.new()
	engine.setup(1)
	# Scout (ships[0]) consumes no rng at upkeep (no fires, no DC), so the
	# cruiser's firefight roll is the first rng draw — seed it to succeed.
	var cruiser := engine.ships[1]
	cruiser.fires = 1
	cruiser.allocation = { "guns": [], "engine": 0, "damage_control": 1 }
	engine.rng.seed = _seed_first_roll(DamageResolver.FIRE_DOUSE_ROLL, 6)
	engine.run_upkeep()
	_check_eq(cruiser.fires, 0, "a damage-control crew (roll 4+) puts the fire out")


func _test_officer_casualties() -> void:
	# A bridge hit strikes down a named officer (deterministic — no roll needed).
	var ship := ShipState.create(ShipLibrary.ship(&"zodanga_cruiser"), 0, Vector2i(0, 0), 0)
	var n0 := ship.officers.size()
	_check(n0 > 0, "the cruiser starts with a named officer roster")
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var crew0 := ship.crew_pool()
	var rep := DamageResolver._hit_system(ship, ShipDef.SystemType.BRIDGE, rng, -1)
	_check_eq(ship.officers.size(), n0 - 1, "a bridge hit removes one officer from the roster")
	_check_eq(ship.crew_pool(), crew0 - 1, "a struck-down officer also docks the crew pool")
	_check("struck down" in str(rep["effect"]), "the bridge-hit effect names the fallen officer")

	# A crew crit on a 6 claims an officer; the effect names them.
	var ship2 := ShipState.create(ShipLibrary.ship(&"zodanga_cruiser"), 0, Vector2i(0, 0), 0)
	var n2 := ship2.officers.size()
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = _seed_first_roll(6, 6)
	var rep2 := DamageResolver._hit_system(ship2, ShipDef.SystemType.CREW, rng2, -1)
	_check_eq(ship2.officers.size(), n2 - 1, "a crew crit (roll 6) claims an officer")
	_check("among the crew" in str(rep2["effect"]), "the crew-crit effect names the fallen officer")

	# With the roster exhausted, further bridge hits fall back gracefully.
	var ship3 := ShipState.create(ShipLibrary.ship(&"helium_scout"), 0, Vector2i(0, 0), 0)
	for _i in ship3.officers.size() + 1:
		DamageResolver._hit_system(ship3, ShipDef.SystemType.BRIDGE, rng, -1)
	_check(ship3.officers.is_empty(), "an exhausted roster simply stays empty (no crash)")


func _test_damage_control_capacity() -> void:
	# A destroyed station can't be manned: damage-control crew is gated by the
	# surviving DAMAGE_CONTROL boxes, not just the crew pool.
	var s := ShipState.create(ShipLibrary.ship(&"zodanga_cruiser"), 0, Vector2i(0, 0), 0)
	var cap := s.damage_control_capacity()
	_check(cap >= 1, "intact cruiser has damage-control capacity")

	# With one DC station, asking for more parties than stations is capped down.
	_check(s.apply_allocation({ "guns": [], "engine": 0, "damage_control": cap + 1, "lookout": 0 }),
			"an over-DC allocation within the crew pool is accepted")
	_check_eq(int(s.allocation.get("damage_control", -1)), cap,
			"damage-control crew is capped at the surviving DC stations")

	# Shoot the DC system away — now no crew can work damage control at all.
	s.systems_remaining[ShipDef.SystemType.DAMAGE_CONTROL] = 0
	_check_eq(s.damage_control_capacity(), 0, "a destroyed DC system has zero capacity")
	_check(s.apply_allocation({ "guns": [], "engine": 0, "damage_control": 1, "lookout": 0 }),
			"allocating a DC hand on a dead station is still legal (just useless)")
	_check_eq(int(s.allocation.get("damage_control", -1)), 0,
			"no crew can be assigned to a fully destroyed damage-control system")

	# And the upkeep repair loop honours it: a holed tank is NOT patched when the
	# DC station is gone, even with a DC hand nominally allocated.
	var engine := TurnEngine.new()
	engine.setup(1)
	var sc := engine.ships[1]   # cruiser (DC-capable; the scout has no DC now)
	sc.systems_remaining[ShipDef.SystemType.DAMAGE_CONTROL] = 0
	var buoy_total := sc.def.system_count(ShipDef.SystemType.BUOYANCY)
	sc.systems_remaining[ShipDef.SystemType.BUOYANCY] = buoy_total - 1   # one tank holed
	sc.port_buoyancy = sc.port_buoyancy - 1
	sc.allocation = { "damage_control": 1 }   # set directly, bypassing the gate
	engine.run_upkeep()
	_check_eq(sc.sys(ShipDef.SystemType.BUOYANCY), buoy_total - 1,
			"a destroyed DC station patches nothing at upkeep")


# ---------------------------------------------------------------------------
# New ship classes: one-man flyer and battleship
# ---------------------------------------------------------------------------

func _test_new_ship_classes() -> void:
	for id in [&"one_man_flyer", &"helium_battleship"]:
		var def := ShipLibrary.ship(id)
		_check(def != null, "%s class is registered" % id)
		_check_eq(def.armor.size(), 6, "%s has six armor facings" % id)
		_check(def.system_count(ShipDef.SystemType.CREW) > 0, "%s has a crew pool" % id)
		_check(not def.gun_mounts.is_empty(), "%s mounts at least one gun" % id)
		var guns_ok := true
		for m in def.gun_mounts:
			if ShipLibrary.gun(m["gun_id"]) == null:
				guns_ok = false
		_check(guns_ok, "%s mounts all reference real guns" % id)
		var st := ShipState.create(def, 0, Vector2i(0, 0), 0)
		_check(st.effective_max_speed() > 0, "%s rates a positive top speed" % id)
		_check(not st.officers.is_empty(), "%s carries named officers" % id)

	# Class identities: the battleship is the heaviest hull, the one-man the fastest.
	var bb := ShipLibrary.ship(&"helium_battleship")
	var om := ShipLibrary.ship(&"one_man_flyer")
	_check(_armor_total(bb) > _armor_total(ShipLibrary.ship(&"zodanga_cruiser")),
			"battleship out-armours the cruiser")
	_check(om.base_max_speed > ShipLibrary.ship(&"helium_scout").base_max_speed,
			"one-man flyer is faster than the scout")


func _test_new_class_battles() -> void:
	# Battleship vs cruiser: two hulls that can hurt each other resolve decisively.
	var decided := 0
	for k in [1, 2, 3]:
		var r := _run_ai_battle_classes(&"helium_battleship", &"zodanga_cruiser", k * 7919 + 3)
		_check(r["clean"], "battleship/cruiser battle (key %d) kept every box >= 0" % k)
		if int(r["winner"]) >= 0:
			decided += 1
	_check(decided >= 2, "battleship vs cruiser resolves decisively (got %d/3)" % decided)

	# One-man vs scout: a light exotic matchup — assert it runs without invariant
	# violations (a fast kiter duel need not always reach a kill within the cap).
	for k in [1, 2]:
		var r2 := _run_ai_battle_classes(&"one_man_flyer", &"helium_scout", k * 104729 + 1)
		_check(r2["clean"], "one-man/scout battle (key %d) kept every box >= 0" % k)
