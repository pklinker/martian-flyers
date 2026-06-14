class_name FleetBuilder
## Points-buy fleet composition (Phase F2). A pure, headless helper: it lists the
## buyable ship classes with their derived `ShipDef.point_cost()`, validates a
## roster against a budget, and generates a points-matched AI roster from a seeded
## RNG. No rendering, no input — the fleet-builder UI and the AI driver both call
## these. All cost logic lives on `ShipDef`; this only sums and selects.

## The catalog: every buyable class as { id, display_name, point_cost }, in the
## library's definition order (deterministic).
static func available_classes() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in ShipLibrary.ship_ids():
		var d := ShipLibrary.ship(id)
		out.append({ "id": id, "display_name": d.display_name, "point_cost": d.point_cost() })
	return out

## Total points a roster (list of ship-class ids) spends.
static func roster_cost(roster: Array) -> int:
	var total := 0
	for id in roster:
		total += ShipLibrary.ship(id).point_cost()
	return total

## A roster is legal when it is non-empty and within budget.
static func is_valid(roster: Array, budget: int) -> bool:
	return not roster.is_empty() and roster_cost(roster) <= budget

## The cheapest class in the catalog (its cost is the minimum spendable unit).
static func cheapest_cost() -> int:
	var best := 1 << 30
	for id in ShipLibrary.ship_ids():
		best = mini(best, ShipLibrary.ship(id).point_cost())
	return best

## Generate a points-matched roster from the catalog with a seeded RNG: greedily-
## randomly buy affordable classes until the budget can't fit another (or the
## ship cap is hit). Deterministic for a given rng state, within budget, and
## non-empty (falls back to the single cheapest hull if the budget is tiny).
static func generate_roster(budget: int, rng: RandomNumberGenerator, max_ships: int = 8) -> Array[StringName]:
	var ids := ShipLibrary.ship_ids()
	var roster: Array[StringName] = []
	var remaining := budget
	var floor_cost := cheapest_cost()
	while roster.size() < max_ships and remaining >= floor_cost:
		var affordable: Array[StringName] = []
		for id in ids:
			if ShipLibrary.ship(id).point_cost() <= remaining:
				affordable.append(id)
		if affordable.is_empty():
			break
		var pick: StringName = affordable[rng.randi_range(0, affordable.size() - 1)]
		roster.append(pick)
		remaining -= ShipLibrary.ship(pick).point_cost()
	if roster.is_empty():
		roster.append(_cheapest_id(ids))
	return roster

static func _cheapest_id(ids: Array[StringName]) -> StringName:
	var best_id: StringName = ids[0]
	var best := 1 << 30
	for id in ids:
		var c := ShipLibrary.ship(id).point_cost()
		if c < best:
			best = c
			best_id = id
	return best_id
