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

	_suite("AI")
	_test_ai_evaluator()
	_test_ai_battle()

	_suite("Smoke battle")
	_test_full_battle()

	print("\n========================================")
	print("  %d passed, %d failed" % [_passed, _failed])
	print("========================================")
	quit(1 if _failed > 0 else 0)


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
	var scout := ShipState.create(ShipLibrary.ship(&"helium_scout"), 0, Vector2i(0, 0), 0)
	scout.apply_allocation({ "guns": [0, 1, 2, 3], "engine": 0, "damage_control": 0 })
	# Target dead ahead at range 2: bow gun (arcs 5,0,1) and chase gun (0,1,5)
	# bear; the side guns (1,2) and (4,5) do not.
	var bearing_guns := scout.guns_bearing(Vector2i(0, -2))
	_check_eq(bearing_guns, [0, 3], "dead-ahead target: bow + chase guns bear")
	# Target dead ahead but at range 9: light bow gun (max 8) drops out,
	# chase gun (medium, max 12) still bears.
	bearing_guns = scout.guns_bearing(Vector2i(0, -9))
	_check_eq(bearing_guns, [3], "range 9 dead ahead: only chase gun bears")
	# Unmanned guns never bear.
	scout.apply_allocation({ "guns": [], "engine": 0, "damage_control": 0 })
	_check_eq(scout.guns_bearing(Vector2i(0, -2)).size(), 0, "unmanned guns cannot fire")

func _test_guns_bearing_from() -> void:
	var scout := ShipState.create(ShipLibrary.ship(&"helium_scout"), 0, Vector2i(8, 8), 0)
	scout.apply_allocation({ "guns": [0, 1, 2, 3], "engine": 0, "damage_control": 0 })
	# From the real position/facing the query matches guns_bearing.
	_check_eq(scout.guns_bearing(Vector2i(8, 5)), [0, 3],
			"guns_bearing_from at own pose matches guns_bearing (bow + chase)")
	# Same target, but evaluated as if the ship were facing SE (2): the north
	# target falls into the port gun's arc instead of the bow's.
	_check_eq(scout.guns_bearing_from(Vector2i(8, 8), 2, Vector2i(8, 5)), [2],
			"hypothetical facing changes which mounts bear (port gun only)")

func _test_fire_preview() -> void:
	var scout := ShipState.create(ShipLibrary.ship(&"helium_scout"), 0, Vector2i(0, 0), 0)
	scout.apply_allocation({ "guns": [0, 1, 2, 3], "engine": 0, "damage_control": 0 })
	# Bow gun (light) at range 2 dead ahead: near bracket, 2+ to hit for 2 dmg.
	var p := scout.fire_preview(0, Vector2i(0, -2))
	_check(p["bears"], "bow gun bears dead ahead at range 2")
	_check_eq(p["range"], 2, "preview reports the range")
	_check_eq(p["to_hit"], 2, "near bracket to-hit is 2+")
	_check_eq(p["damage"], 2, "near bracket damage is 2")
	# Starboard gun (arcs 1,2) cannot bear on a dead-ahead target.
	_check_eq(scout.fire_preview(1, Vector2i(0, -2))["reason"], "out of arc",
			"off-arc gun reports out of arc")
	# Bow light gun past its max range (8): out of range.
	_check_eq(scout.fire_preview(0, Vector2i(0, -9))["reason"], "out of range",
			"light gun beyond range 8 reports out of range")
	# Unmanned guns report unmanned, not a false bearing.
	scout.apply_allocation({ "guns": [], "engine": 0, "damage_control": 0 })
	_check_eq(scout.fire_preview(0, Vector2i(0, -2))["reason"], "unmanned",
			"unmanned gun reports unmanned")

func _test_engine_crew_speed_gate() -> void:
	var scout := ShipState.create(ShipLibrary.ship(&"helium_scout"), 0, Vector2i(0, 0), 0)
	# The engine-box ceiling is unchanged by crew (rated top speed).
	_check_eq(scout.effective_max_speed(), 8, "scout engine-box ceiling is 8")
	# No engine crew powering the radium engine: the ship can't make way.
	scout.apply_allocation({ "guns": [], "engine": 0, "damage_control": 0 })
	_check_eq(scout.usable_max_speed(), 0, "no engine crew: no way on")
	# Two engine crew at rate 2 drive speed 4.
	scout.apply_allocation({ "guns": [], "engine": 2, "damage_control": 0 })
	_check_eq(scout.usable_max_speed(), 4, "2 engine crew drive speed 4")
	# Crew beyond what the boxes allow can't exceed the engine-box ceiling.
	scout.apply_allocation({ "guns": [], "engine": 6, "damage_control": 0 })
	_check_eq(scout.usable_max_speed(), 8, "engine crew can't push past the box ceiling")
	# Crew needed for a target speed rounds up.
	_check_eq(scout.engine_crew_for_speed(8), 4, "speed 8 needs 4 engine crew")
	_check_eq(scout.engine_crew_for_speed(3), 2, "speed 3 needs 2 engine crew (ceil)")
	# Damaged engine boxes lower the ceiling even with crew to spare.
	scout.systems_remaining[ShipDef.SystemType.ENGINE] = 2  # of 4 -> ceil(8*0.5)=4
	scout.apply_allocation({ "guns": [], "engine": 6, "damage_control": 0 })
	_check_eq(scout.usable_max_speed(), 4, "half engine boxes cap usable speed at 4 regardless of crew")

func _test_reload_and_crew_allocation() -> void:
	var scout := ShipState.create(ShipLibrary.ship(&"helium_scout"), 0, Vector2i(0, 0), 0)
	# Scout crew pool is 6; manning all four guns costs 1+1+1+2 = 5. Legal.
	_check(scout.apply_allocation({ "guns": [0, 1, 2, 3], "engine": 1, "damage_control": 0 }),
			"allocation exactly at crew pool is accepted")
	_check(not scout.apply_allocation({ "guns": [0, 1, 2, 3], "engine": 1, "damage_control": 1 }),
			"over-allocation is rejected")
	# Reload: fire the chase gun (reload 1), confirm it goes on cooldown and ticks back.
	scout.apply_allocation({ "guns": [3], "engine": 0, "damage_control": 0 })
	var target := ShipState.create(ShipLibrary.ship(&"zodanga_cruiser"), 1, Vector2i(0, -3), 3)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	DamageResolver.resolve_shot(scout, 3, target, rng)
	_check_eq(int(scout.gun_states[3]["reload"]), 1, "medium gun on 1-turn cooldown after firing")
	_check(not scout.gun_ready(3), "gun not ready while reloading")
	scout.tick_reloads()
	_check(scout.gun_ready(3), "gun ready again after reload ticks down")


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
	const TUBE := 4
	var scout := ShipState.create(ShipLibrary.ship(&"helium_scout"), 0, Vector2i(0, 0), 0)
	var enemy := ShipState.create(ShipLibrary.ship(&"zodanga_cruiser"), 1, Vector2i(0, -3), 3)
	_check_eq(str(scout.def.gun_mounts[TUBE]["label"]), "Torpedo Tube", "tube is mount index 4")
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
	_check_eq(str(scout.fire_preview(TUBE, enemy.hex)["reason"]), "no torpedoes",
			"empty tube preview explains why it can't fire")
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
	var s := engine.ships[0]   # the scout, falls at 1
	s.systems_remaining[ShipDef.SystemType.BUOYANCY] = s.def.grounding_threshold  # on the line
	s.allocation = { "damage_control": 1 }
	_check(not s.is_buoyant(), "scout starts the upkeep at/below its falling line")
	# Keep the enemy alive and clear so this is the only victory trigger in play.
	engine.run_upkeep()
	_check(not s.grounded, "damage control lifts the scout back above the line before grounding")
	_check(s.is_buoyant(), "patched tank restores buoyancy")
	_check_eq(engine.phase, TurnEngine.Phase.ALLOCATION,
			"clawed-back flyer does not trigger game over")


# ---------------------------------------------------------------------------
# Capability erosion
# ---------------------------------------------------------------------------

func _test_derived_capabilities() -> void:
	var cruiser := ShipState.create(ShipLibrary.ship(&"zodanga_cruiser"), 0, Vector2i(0, 0), 0)
	_check_eq(cruiser.effective_max_speed(), 5, "undamaged cruiser max speed")
	cruiser.systems_remaining[ShipDef.SystemType.ENGINE] = 3  # of 6
	_check_eq(cruiser.effective_max_speed(), 3, "half engines: ceil(5 * 0.5) = 3")
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
	# Bow light gun at range 2 dead ahead: near bracket, 2+ to hit.
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
	_check_eq(pv_dust["to_hit"], 3, "dust raises to-hit from 2 to 3")
	# One lookout crew cancels the dust penalty completely.
	scout.apply_allocation({ "guns": [0], "engine": 0, "damage_control": 0, "lookout": 1 })
	var pv_lookout := scout.fire_preview(0, Vector2i(0, -2), dust_terrain)
	_check_eq(pv_lookout["dust_penalty"], 0, "lookout cancels the dust penalty")
	_check_eq(pv_lookout["to_hit"], 2, "to-hit restored to 2 with lookout countering dust")
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
	var s := engine.ships[0]   # scout
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
	scout.apply_allocation({ "guns": [0, 1, 2, 3], "engine": 0, "damage_control": 0 })
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
	var brains := [ShipAI.for_ship(engine.ships[0].def), ShipAI.for_ship(engine.ships[1].def)]
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
