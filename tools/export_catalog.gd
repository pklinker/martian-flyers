extends SceneTree
## Maintained tool: re-emit the active ship/gun catalog to res://data/*.json in
## canonical form (sorted keys, tab indent). The data files are the source of
## truth; run this to normalise formatting after a hand edit, or to round-trip
## the catalog through ShipDef/GunDef.to_dict() and confirm it survives:
##   Godot --headless --path . -s res://tools/export_catalog.gd
##
## Because both this tool and the loader go through to_dict()/from_dict(), the
## on-disk shape is defined in exactly one place.

const DATA_DIR := "res://data"

func _initialize() -> void:
	var err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DATA_DIR))
	if err != OK and err != ERR_ALREADY_EXISTS:
		push_error("could not create %s (err %d)" % [DATA_DIR, err])

	var guns: Array = []
	for gid in ShipLibrary.gun_ids():
		guns.append(ShipLibrary.gun(gid).to_dict())
	_write(DATA_DIR + "/guns.json", { "guns": guns })

	var ships: Array = []
	for sid in ShipLibrary.ship_ids():
		ships.append(ShipLibrary.ship(sid).to_dict())
	_write(DATA_DIR + "/ships.json", { "ships": ships })

	print("Exported %d guns, %d ships to %s" % [guns.size(), ships.size(), DATA_DIR])
	quit(0)


func _write(path: String, data: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("could not open %s for write" % path)
		return
	f.store_string(JSON.stringify(data, "\t") + "\n")
	f.close()
	print("  wrote %s" % path)
