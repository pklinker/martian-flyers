extends SceneTree
## T1 spike (MAP_MODDING.md §0.4): prove a .glb in user:// — with NO editor
## .import sidecar — can be loaded at runtime via GLTFDocument, and that the
## result satisfies ModelBaker's PackedScene contract.
##
## Run from the project root:
##   godot --headless --path . -s res://tests/spike_runtime_glb.gd
##
## Exit code 0 = spike passed (mod glb path is viable), 1 = failed.
##
## What is proved, in order:
##   1. NEGATIVE CONTROL — ResourceLoader cannot load a user:// glb (this is
##      the outside-voice finding: load() resolves the editor-baked .scn under
##      res://.godot/, which a mod pack does not have).
##   2. GLTFDocument.append_from_file loads the same bytes into a Node3D.
##   3. The generated scene carries real geometry (MeshInstance3D, non-empty AABB).
##   4. PackedScene.pack() wraps the generated scene and instantiate() works —
##      so ModelBaker keeps its Array[PackedScene] variants with no type change.

const SRC_GLB := "hill_1.glb"           # shipped source glb to copy from
const SRC_DIR := "assets/terrain"       # raw file on disk in the project dir
const MOD_DIR := "user://mods/spike_pack/assets/terrain"

var _passed := 0
var _failed := 0


func _init() -> void:
	var mod_glb := MOD_DIR.path_join(SRC_GLB)
	_stage_mod_pack(mod_glb)

	print("\n-- 1. negative control: ResourceLoader on user:// glb --")
	_check(not ResourceLoader.exists(mod_glb),
			"ResourceLoader.exists() is false for a user:// glb (no .import)")
	var via_load: Resource = null
	if ResourceLoader.exists(mod_glb):
		via_load = load(mod_glb)
	_check(via_load == null, "load() yields nothing for a user:// glb")

	print("\n-- 2. GLTFDocument runtime import --")
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(ProjectSettings.globalize_path(mod_glb), state)
	_check(err == OK, "append_from_file succeeds (err=%d)" % err)
	var root: Node = doc.generate_scene(state) if err == OK else null
	_check(root != null, "generate_scene returns a node")
	_check(root is Node3D, "generated root is a Node3D (mountable by the baker)")

	print("\n-- 3. geometry sanity --")
	var mesh_node := _find_mesh(root)
	_check(mesh_node != null, "scene contains a MeshInstance3D")
	if mesh_node != null:
		var aabb := mesh_node.get_aabb()
		_check(aabb.size.length() > 0.01,
				"mesh AABB is non-degenerate (size %.2f,%.2f,%.2f)"
				% [aabb.size.x, aabb.size.y, aabb.size.z])
		_check(mesh_node.mesh.get_surface_count() > 0, "mesh has surfaces")

	print("\n-- 4. ModelBaker PackedScene contract --")
	if root != null:
		_own_recursive(root, root)   # pack() only keeps owned nodes
		var packed := PackedScene.new()
		var pack_err := packed.pack(root)
		_check(pack_err == OK, "PackedScene.pack() accepts the generated scene")
		var inst := packed.instantiate()
		_check(inst is Node3D and _find_mesh(inst) != null,
				"packed scene re-instantiates with its mesh intact")
		inst.free()
		root.free()

	_cleanup()
	print("\nspike_runtime_glb: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


## Copy the shipped glb's raw bytes into a simulated mod pack. This mirrors a
## modder install exactly: raw glb bytes on disk, no editor import artifacts.
func _stage_mod_pack(dest: String) -> void:
	DirAccess.make_dir_recursive_absolute(MOD_DIR)
	var src_abs := ProjectSettings.globalize_path("res://" + SRC_DIR + "/" + SRC_GLB)
	var bytes := FileAccess.get_file_as_bytes(src_abs)
	assert(bytes.size() > 0, "source glb missing: " + src_abs)
	var f := FileAccess.open(dest, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	print("staged %d-byte glb at %s (no .import sidecar)" % [bytes.size(), dest])


func _find_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		return node
	for c in node.get_children():
		var hit := _find_mesh(c)
		if hit != null:
			return hit
	return null


func _own_recursive(node: Node, owner_node: Node) -> void:
	for c in node.get_children():
		c.owner = owner_node
		_own_recursive(c, owner_node)


func _cleanup() -> void:
	DirAccess.remove_absolute(MOD_DIR.path_join(SRC_GLB))


func _check(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("  PASS  " + label)
	else:
		_failed += 1
		printerr("  FAIL  " + label)
