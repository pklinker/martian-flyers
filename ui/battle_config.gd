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

## Chosen map (a MapLibrary id), set on the main menu and honoured by every
## battle the map boots — Quick Engagement or a built fleet. Like `difficulty`,
## it is NOT touched by clear()/set_battle() so one menu choice carries across
## all launch paths. A resumed/loaded save uses the map baked into the save, not
## this. Defaults to the bundled dead_sea_bottom.
static var map_id: StringName = TurnEngine.DEFAULT_MAP_ID

## Suspend/resume: leaving a battle for the menu auto-saves it here; the menu's
## "Resume Battle" button sets `resume` and the map reloads it on boot.
const RESUME_PATH := "user://resume.flyersave"
static var resume: bool = false

static func has_resume() -> bool:
	return FileAccess.file_exists(RESUME_PATH)

static func clear_resume() -> void:
	if FileAccess.file_exists(RESUME_PATH):
		DirAccess.remove_absolute(RESUME_PATH)

## Manual quicksave slot. The title screen's Save copies the suspended battle
## here; its Load sets `load_save` and the map restores this file on boot.
const SAVE_PATH := "user://quicksave.flyersave"
static var load_save: bool = false

static func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)

## Copy the suspended battle into the quicksave slot. Returns OK, or an error if
## there is no suspended battle to capture.
static func save_suspended() -> int:
	if not has_resume():
		return ERR_DOES_NOT_EXIST
	var data := FileAccess.get_file_as_bytes(RESUME_PATH)
	if data.is_empty():
		return ERR_FILE_CANT_READ
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(data)
	f.close()
	return OK


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
