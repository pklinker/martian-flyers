class_name BattleConfig
## Hand-off between the fleet-builder screen and the map: the two chosen rosters
## (lists of ship-class ids) for the next engagement. Pure navigation glue — no
## rules, no rendering. `pending` is true when the builder has set up a battle;
## the map reads it on new-game and falls back to its default 2v2 otherwise.

static var player_roster: Array[StringName] = []
static var ai_roster: Array[StringName] = []
static var budget: int = 0
static var pending: bool = false

## Chosen enemy difficulty rank (a ShipAI.Difficulty value), set on the main
## menu and honoured by every battle the map boots — Quick Engagement, a built
## fleet, or a resumed save. Deliberately NOT touched by clear()/set_battle() so
## one menu choice carries across all paths. Defaults to the balanced DWAR.
static var difficulty: int = ShipAI.Difficulty.DWAR

## Suspend/resume: leaving a battle for the menu auto-saves it here; the menu's
## "Resume Battle" button sets `resume` and the map reloads it on boot.
const RESUME_PATH := "user://resume.flyersave"
static var resume: bool = false

static func has_resume() -> bool:
	return FileAccess.file_exists(RESUME_PATH)

static func clear_resume() -> void:
	if FileAccess.file_exists(RESUME_PATH):
		DirAccess.remove_absolute(RESUME_PATH)


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
