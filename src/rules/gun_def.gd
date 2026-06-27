class_name GunDef
extends Resource
## Static definition of a deck gun TYPE (light/medium/heavy radium gun).
## Immutable template data — runtime state (reload counters, destroyed flags)
## lives in ShipState.GunMountState.

enum Size { LIGHT, MEDIUM, HEAVY }

@export var id: StringName = &"light_gun"
@export var display_name: String = "Light Radium Gun"
@export var size: Size = Size.LIGHT

## Turns between shots. 0 = fires every turn; 2 = fire, then wait 2 full turns.
@export var reload_turns: int = 0

## Crew boxes that must be allocated to this mount for it to fire.
@export var crew_required: int = 1

## --- Torpedo fields (ignored by ordinary deck guns) ---------------------
## A torpedo tube is a deck-gun mount with three twists: finite ammo, armour-
## piercing warheads, and (usually) a long reload. Everything else — arcs,
## range brackets, crew, the firing/resolution path — is shared with guns.
@export var is_torpedo: bool = false

## Starting torpedoes carried per tube. The runtime count lives in
## ShipState.gun_states[i]["ammo"]; ordinary guns leave this 0 (infinite).
@export var ammo: int = 0

## Armour points bypassed on the struck facing before absorption — how a slow
## warhead reaches a cruiser's internals through plating that shrugs off shells.
@export var armor_piercing: int = 0

## Range brackets, ordered nearest-first. Each entry:
##   { "max_range": int, "to_hit": int, "damage": int }
## `to_hit` is the minimum roll needed on 1d6. A target beyond the last
## bracket's max_range is out of range.
@export var range_brackets: Array[Dictionary] = []

func bracket_for_range(range_hexes: int) -> Dictionary:
	for b in range_brackets:
		if range_hexes <= int(b["max_range"]):
			return b
	return {}  # out of range


# ---------------------------------------------------------------------------
# (De)serialization — the single source of truth for guns ↔ JSON. The catalog
# loader and the data exporter both go through here, so the on-disk shape is
# defined in exactly one place. Enum `size` is written as its NAME (LIGHT /
# MEDIUM / HEAVY) so the file stays readable and survives any enum reordering.
# ---------------------------------------------------------------------------

func to_dict() -> Dictionary:
	return {
		"id": String(id),
		"display_name": display_name,
		"size": Size.keys()[Size.values().find(size)],
		"reload_turns": reload_turns,
		"crew_required": crew_required,
		"is_torpedo": is_torpedo,
		"ammo": ammo,
		"armor_piercing": armor_piercing,
		"range_brackets": range_brackets.duplicate(true),
	}

static func from_dict(d: Dictionary) -> GunDef:
	var g := GunDef.new()
	g.id = StringName(d["id"])
	g.display_name = String(d["display_name"])
	g.size = int(Size[String(d["size"])])
	g.reload_turns = int(d["reload_turns"])
	g.crew_required = int(d["crew_required"])
	g.is_torpedo = bool(d.get("is_torpedo", false))
	g.ammo = int(d.get("ammo", 0))
	g.armor_piercing = int(d.get("armor_piercing", 0))
	var rb: Array[Dictionary] = []
	for b in d["range_brackets"]:
		rb.append({
			"max_range": int(b["max_range"]),
			"to_hit": int(b["to_hit"]),
			"damage": int(b["damage"]),
		})
	g.range_brackets.assign(rb)
	return g

func max_range() -> int:
	if range_brackets.is_empty():
		return 0
	return int(range_brackets[-1]["max_range"])
