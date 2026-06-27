# Martian Flyers — Mods

The ship and gun catalog is data. You can add new hulls and guns, or retune the
stock ones, by dropping JSON files in the game's mods folder — no rebuild, no
editor.

## Where mods go

Copy a **pack folder** (like `heavier-crews/` in this directory) into the game's
user-data mods folder:

| Platform | Path |
|----------|------|
| macOS    | `~/Library/Application Support/Godot/app_userdata/Martian Flyers/mods/` |
| Linux    | `~/.local/share/godot/app_userdata/Martian Flyers/mods/` |
| Windows  | `%APPDATA%\Godot\app_userdata\Martian Flyers\mods\` |

So `heavier-crews` ends up at `…/Martian Flyers/mods/heavier-crews/`. The game
scans every subfolder of `mods/` on launch, in alphabetical order.

A pack may contain `guns.json`, `ships.json`, or both.

## How merging works

Everything is keyed by **`id`**:

- A **new** id (one the game doesn't ship) is **added** to the catalog.
- An **existing** id **overrides** the stock definition — the *whole* entry, so
  include every field, not just the one you changed. An override keeps the hull's
  original slot in the fleet-builder list.

Packs load after the core game and after each other (alphabetical), so a later
pack wins on a shared id.

## The example: `heavier-crews/`

A worked **override**. It redefines `helium_battleship` with `CREW` raised from
the stock 240 to 360 — an over-crewed flagship that can run hard *and* keep more
of its batteries manned. Its points cost re-derives automatically from the new
stats. Copy the folder into your `mods/` dir and start a battle to see it.

## Schema

Mirror the bundled data in the game's `res://data/guns.json` and
`res://data/ships.json` — those are the source of truth for every field.

**Gun:** `id`, `display_name`, `size` (`LIGHT` | `MEDIUM` | `HEAVY`),
`reload_turns`, `crew_required`, `range_brackets` (non-empty, each
`{ max_range, to_hit, damage }`, `max_range` strictly increasing). Optional:
`is_torpedo`, `ammo`, `armor_piercing`.

**Ship:** `id`, `display_name`, `armor` (exactly 6 facings), `systems` (keyed by
name: `BUOYANCY`, `ENGINE`, `PROPELLER`, `RUDDER`, `BRIDGE`, `CREW`, `MAGAZINE`,
`DAMAGE_CONTROL`), `gun_mounts` (each `{ gun_id, arcs (0..5), label }`),
`base_max_speed`, `speed_per_engine_crew`, `grounding_threshold`,
`turn_mode_by_speed` (non-empty). Optional: `faction`, `officers`,
`point_cost_override` (-1 derives).

A `gun_id` on a mount may reference a gun from the core game or from any pack — a
ship and its guns can live in different packs.

## When something's wrong

The game validates every entry. A malformed gun or ship is **skipped** with an
error in the log (a ship that mounts an unknown gun is dropped); the rest of the
pack and all core data still load. A save that needs a ship or gun you've since
removed declines to load with a message naming what's missing, rather than
crashing mid-battle.
