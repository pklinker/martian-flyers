class_name BattleConfig
## Hand-off between the fleet-builder screen and the map: the two chosen rosters
## (lists of ship-class ids) for the next engagement. Pure navigation glue — no
## rules, no rendering. `pending` is true when the builder has set up a battle;
## the map reads it on new-game and falls back to its default 2v2 otherwise.

static var player_roster: Array[StringName] = []
static var ai_roster: Array[StringName] = []
static var budget: int = 0
static var pending: bool = false


static func set_battle(player: Array, ai: Array, points: int) -> void:
	player_roster.assign(player)
	ai_roster.assign(ai)
	budget = points
	pending = true


static func clear() -> void:
	player_roster = []
	ai_roster = []
	budget = 0
	pending = false
