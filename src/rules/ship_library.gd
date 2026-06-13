class_name ShipLibrary
## Concrete data for v1: three gun sizes and the two starting ship classes.
## Built in code for now; trivially migrated to .tres resources later if you
## want designers (or future-you) editing stats outside the codebase.

static var _guns: Dictionary = {}
static var _ships: Dictionary = {}

static func gun(id: StringName) -> GunDef:
	_ensure_built()
	return _guns[id]

static func ship(id: StringName) -> ShipDef:
	_ensure_built()
	return _ships[id]

static func _ensure_built() -> void:
	if not _guns.is_empty():
		return

	# --- Guns -------------------------------------------------------------
	var light := GunDef.new()
	light.id = &"light_gun"
	light.display_name = "Light Radium Gun"
	light.size = GunDef.Size.LIGHT
	light.reload_turns = 0
	light.crew_required = 1
	light.range_brackets.assign([
		{ "max_range": 2, "to_hit": 2, "damage": 2 },
		{ "max_range": 5, "to_hit": 4, "damage": 1 },
		{ "max_range": 8, "to_hit": 6, "damage": 1 },
	])
	_guns[light.id] = light

	var medium := GunDef.new()
	medium.id = &"medium_gun"
	medium.display_name = "Medium Radium Gun"
	medium.size = GunDef.Size.MEDIUM
	medium.reload_turns = 1
	medium.crew_required = 2
	medium.range_brackets.assign([
		{ "max_range": 3, "to_hit": 3, "damage": 4 },
		{ "max_range": 7, "to_hit": 4, "damage": 3 },
		{ "max_range": 12, "to_hit": 5, "damage": 2 },
	])
	_guns[medium.id] = medium

	var heavy := GunDef.new()
	heavy.id = &"heavy_gun"
	heavy.display_name = "Heavy Radium Gun"
	heavy.size = GunDef.Size.HEAVY
	heavy.reload_turns = 2
	heavy.crew_required = 3
	heavy.range_brackets.assign([
		{ "max_range": 4, "to_hit": 3, "damage": 7 },
		{ "max_range": 10, "to_hit": 4, "damage": 5 },
		{ "max_range": 18, "to_hit": 5, "damage": 3 },
	])
	_guns[heavy.id] = heavy

	# Aerial radium torpedo: the light flyer's answer to armour. Finite salvo,
	# armour-piercing, slow to reload — loosed from range to punch internals a
	# kiting gun never could, then the scout runs while the tube cycles.
	var torpedo := GunDef.new()
	torpedo.id = &"aerial_torpedo"
	torpedo.display_name = "Aerial Radium Torpedo"
	torpedo.size = GunDef.Size.HEAVY
	torpedo.is_torpedo = true
	torpedo.ammo = 3
	torpedo.armor_piercing = 3
	torpedo.reload_turns = 3
	torpedo.crew_required = 2
	torpedo.range_brackets.assign([
		{ "max_range": 4, "to_hit": 3, "damage": 6 },
		{ "max_range": 8, "to_hit": 4, "damage": 6 },
		{ "max_range": 11, "to_hit": 5, "damage": 5 },
	])
	_guns[torpedo.id] = torpedo

	# --- Helium Scout Flyer ------------------------------------------------
	# Fast and agile. Wins by holding the range band where its light guns
	# still bite and the cruiser's heavies are reloading — but its small crew
	# can't both run the engine hard AND man every gun, so kiting means firing
	# light.
	var scout := ShipDef.new()
	scout.id = &"helium_scout"
	scout.display_name = "Helium Scout Flyer"
	scout.faction = "Helium"
	scout.armor.assign([3, 2, 1, 1, 1, 2])          # bow-heavy, thin aft
	scout.systems = {
		ShipDef.SystemType.BUOYANCY: 8,
		ShipDef.SystemType.ENGINE: 4,
		ShipDef.SystemType.PROPELLER: 3,
		ShipDef.SystemType.RUDDER: 2,
		ShipDef.SystemType.BRIDGE: 1,
		ShipDef.SystemType.CREW: 6,
		ShipDef.SystemType.MAGAZINE: 1,
		ShipDef.SystemType.DAMAGE_CONTROL: 1,
	}
	scout.gun_mounts.assign([
		{ "gun_id": &"light_gun", "arcs": [5, 0, 1], "label": "Bow Gun" },
		{ "gun_id": &"light_gun", "arcs": [1, 2], "label": "Starboard Gun" },
		{ "gun_id": &"light_gun", "arcs": [4, 5], "label": "Port Gun" },
		{ "gun_id": &"medium_gun", "arcs": [0, 1, 5], "label": "Chase Gun" },
		{ "gun_id": &"aerial_torpedo", "arcs": [5, 0, 1], "label": "Torpedo Tube" },
	])
	scout.base_max_speed = 8
	scout.speed_per_engine_crew = 2          # full speed 8 costs 4 of its 6 crew
	scout.grounding_threshold = 1
	scout.turn_mode_by_speed.assign([1, 1, 1, 1, 2, 2, 2, 3, 3])
	_ships[scout.id] = scout

	# --- Zodangan Patrol Cruiser --------------------------------------------
	# Broadside brawler. Slow to turn, but armored and crewed to absorb
	# punishment while its heavies cycle.
	var cruiser := ShipDef.new()
	cruiser.id = &"zodanga_cruiser"
	cruiser.display_name = "Zodangan Patrol Cruiser"
	cruiser.faction = "Zodanga"
	cruiser.armor.assign([5, 4, 4, 3, 4, 4])
	cruiser.systems = {
		ShipDef.SystemType.BUOYANCY: 14,
		ShipDef.SystemType.ENGINE: 6,
		ShipDef.SystemType.PROPELLER: 4,
		ShipDef.SystemType.RUDDER: 3,
		ShipDef.SystemType.BRIDGE: 2,
		ShipDef.SystemType.CREW: 12,
		ShipDef.SystemType.MAGAZINE: 2,
		ShipDef.SystemType.DAMAGE_CONTROL: 2,
	}
	cruiser.gun_mounts.assign([
		{ "gun_id": &"medium_gun", "arcs": [5, 0, 1], "label": "Bow Gun" },
		{ "gun_id": &"heavy_gun", "arcs": [1, 2], "label": "Starboard Battery" },
		{ "gun_id": &"heavy_gun", "arcs": [4, 5], "label": "Port Battery" },
		{ "gun_id": &"medium_gun", "arcs": [2, 3, 4], "label": "Stern Gun" },
	])
	cruiser.base_max_speed = 5
	cruiser.speed_per_engine_crew = 2        # brawls cheaply: cruise speed 4 costs 2 of 12
	cruiser.grounding_threshold = 3
	cruiser.turn_mode_by_speed.assign([1, 1, 2, 2, 3, 4])
	_ships[cruiser.id] = cruiser
