extends SceneTree
## Throwaway balance probe: run many ShipAI-vs-ShipAI battles on the bounded
## map and report win split + timeouts. Not part of the suite.
##   Godot --headless --path . -s res://tests/ai_scan.gd -- 200

const COLS := 16
const ROWS := 12
const MAX_TURNS := 80

func _row_off(q: int) -> int:
	return -(q >> 1)

func _in_bounds(h: Vector2i) -> bool:
	if h.x < 0 or h.x >= COLS:
		return false
	var off := _row_off(h.x)
	return h.y >= off and h.y < off + ROWS

func _bounded_moves(engine: TurnEngine, s: ShipState) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for m in engine.legal_moves_for(s):
		if _in_bounds(m["hex"]):
			out.append(m)
	return out


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var n: int = int(args[0]) if args.size() > 0 else 200
	var trace := args.size() > 1 and args[1] == "v"
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
					var moves := _bounded_moves(engine, s)
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
