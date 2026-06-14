extends SceneTree
## Throwaway balance probe: run many ShipAI-vs-ShipAI battles on the engine's
## bounded map and report win split + timeouts. Not part of the suite.
##   Godot --headless --path . -s res://tests/ai_scan.gd -- 200      # 1v1 scan
##   Godot --headless --path . -s res://tests/ai_scan.gd -- 1 v      # trace one 1v1
##   Godot --headless --path . -s res://tests/ai_scan.gd -- 200 f    # 2v2 fleet scan
##
## The playfield is whatever TurnEngine defines (currently the large 48x48 open
## field with centred starts) — this tool defers to engine.legal_moves_for so it
## tracks the real movement rule rather than re-deriving its own bounds.

const MAX_TURNS := 80


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var n: int = int(args[0]) if args.size() > 0 else 200
	var trace := args.size() > 1 and args[1] == "v"
	if args.size() > 1 and args[1] == "f":
		_fleet_scan(n)
		return
	var scout_wins := 0
	var cruiser_wins := 0
	var timeouts := 0
	var turn_total := 0

	for seed_i in range(1, n + 1):
		var engine := TurnEngine.new()
		engine.setup(seed_i * 7919 + 1)
		var brains := [ShipAI.for_ship(engine.ships[0].def),
				ShipAI.for_ship(engine.ships[1].def)]
		var result := { "winner": -1 }
		engine.game_over.connect(func(side: int, _r: String) -> void: result["winner"] = side)

		while engine.phase != TurnEngine.Phase.GAME_OVER and engine.turn_number <= MAX_TURNS:
			for i in 2:
				brains[i].allocate(engine, engine.ships[i])
			for i in 2:
				brains[i].plot(engine, engine.ships[i])
			for imp in range(1, TurnEngine.IMPULSES_PER_TURN + 1):
				for i in 2:
					var s: ShipState = engine.ships[i]
					if not TurnEngine.moves_on_impulse(s.speed, imp) \
							or s.is_destroyed or s.grounded:
						continue
					var moves := engine.legal_moves_for(s)
					if not moves.is_empty():
						engine.execute_move(s, brains[i].choose_move(engine, s, moves))
			for i in 2:
				var enemy: ShipState = engine.ships[1 - i]
				for mi in brains[i].choose_fire(engine.ships[i], enemy):
					engine.declare_fire(engine.ships[i], mi, enemy)
			engine.resolve_fire_phase()
			if trace:
				var sc: ShipState = engine.ships[0]
				var cr: ShipState = engine.ships[1]
				print("T%-2d rng %d | scout spd %d buoy %d guns_bearing %d | cruiser spd %d buoy %d guns_bearing %d" % [
					engine.turn_number, HexMath.distance(sc.hex, cr.hex),
					sc.speed, sc.sys(ShipDef.SystemType.BUOYANCY), sc.guns_bearing(cr.hex).size(),
					cr.speed, cr.sys(ShipDef.SystemType.BUOYANCY), cr.guns_bearing(sc.hex).size()])
			if engine.phase == TurnEngine.Phase.GAME_OVER:
				break
			engine.run_upkeep()

		if trace:
			print("  -> winner: %d after %d turns" % [result["winner"], engine.turn_number])
			quit(0)
			return

		turn_total += engine.turn_number
		if result["winner"] == 0:
			scout_wins += 1
		elif result["winner"] == 1:
			cruiser_wins += 1
		else:
			timeouts += 1

	print("battles: %d   scout: %d (%.0f%%)   cruiser: %d (%.0f%%)   timeouts: %d   avg turns: %.1f" % [
		n, scout_wins, 100.0 * scout_wins / n, cruiser_wins, 100.0 * cruiser_wins / n,
		timeouts, float(turn_total) / n])
	quit(0)


## NvM scan: a 2-v-2 (Scout + One-Man Flyer vs Cruiser + Battleship) per seed,
## reporting the side-based win split. Same engine, just fleets and side victory.
func _fleet_scan(n: int) -> void:
	var blue := 0
	var red := 0
	var draws := 0
	var timeouts := 0
	var turn_total := 0
	for seed_i in range(1, n + 1):
		var engine := TurnEngine.new()
		engine.setup_rosters(
			[&"helium_scout", &"one_man_flyer"],
			[&"zodanga_cruiser", &"helium_battleship"], seed_i * 7919 + 1)
		var winner := _drive_fleet(engine)
		turn_total += engine.turn_number
		match winner:
			0: blue += 1
			1: red += 1
			-1: draws += 1
			_: timeouts += 1
	print("fleet battles: %d   blue: %d (%.0f%%)   red: %d (%.0f%%)   draws: %d   timeouts: %d   avg turns: %.1f" % [
		n, blue, 100.0 * blue / n, red, 100.0 * red / n, draws, timeouts, float(turn_total) / n])
	quit(0)


## Drive one fleet battle through the engine's shared sequencer with a ShipAI per
## hull. Returns the winning side (0/1), -1 for a draw, or -2 if it hit the cap.
func _drive_fleet(engine: TurnEngine) -> int:
	var brains := {}
	for s in engine.ships:
		brains[s] = ShipAI.for_ship(s.def)
	# Convention #2: a lambda can't write back to a captured local, so the winner
	# is stashed in a Dictionary the signal handler mutates.
	var result := { "winner": -2 }
	engine.game_over.connect(func(side: int, _r: String) -> void: result["winner"] = side)
	while engine.phase != TurnEngine.Phase.GAME_OVER and engine.turn_number <= MAX_TURNS:
		for s in engine.ships:
			if not engine.is_out_of_action(s):
				brains[s].allocate(engine, s)
		for s in engine.ships:
			if not engine.is_out_of_action(s):
				brains[s].plot(engine, s)
		engine.begin_movement()
		while true:
			var s := engine.next_mover()
			if s == null:
				break
			var moves := engine.legal_moves_for(s)
			if not moves.is_empty():
				engine.execute_move(s, brains[s].choose_move(engine, s, moves))
		for s in engine.ships:
			if engine.is_out_of_action(s):
				continue
			var enemy := _fleet_enemy(engine, s)
			if enemy == null:
				continue
			for mi in brains[s].choose_fire(s, enemy):
				engine.declare_fire(s, mi, enemy)
		engine.resolve_fire_phase()
		if engine.phase == TurnEngine.Phase.GAME_OVER:
			break
		engine.run_upkeep()
	return int(result["winner"])


func _fleet_enemy(engine: TurnEngine, s: ShipState) -> ShipState:
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
