class_name StartingParty
extends RefCounted
## The one-time starting-party bootstrap: the leader chargen produced (or
## the authored wizard) plus three companions, built from data at an
## area's PartySpawnPoint. Shared by every area a game can begin in, so
## the starting area can change without copying this.
##
## Does nothing once PartyManager holds anyone: a reload or a re-entry
## restores the captured roster instead.

const COMPANIONS: Array[String] = [
	"res://data/units/companions/tiefling_wizard.tres",
	"res://data/units/companions/human_barbarian.tres",
	"res://data/units/companions/dwarf_fighter.tres",
	"res://data/units/companions/elf_ranger.tres",
]
## Where each stands relative to the spawn point.
const COMPANION_OFFSETS: Array[Vector3] = [
	Vector3(0.0, 0.0, 0.0),
	Vector3(-9.0, 0.0, 0.0),
	Vector3(-6.0, 0.0, 0.0),
	Vector3(-3.0, 0.0, 0.0),
]


static func bootstrap(area: Node3D, spawn_point: Node3D) -> void:
	if not PartyManager.members.is_empty() or not PartyManager.roster.is_empty():
		return
	var leader: Unit = _build_leader(area, spawn_point)
	PartyManager.add_member(leader)
	for i in range(1, COMPANIONS.size()):
		PartyManager.add_member(_spawn_companion(area, spawn_point, i))
	PartyManager.set_leader(leader)


## The character chargen produced if there is one, and the authored wizard
## otherwise (a headless test loading straight into an area never runs
## chargen).
static func _build_leader(area: Node3D, spawn_point: Node3D) -> Unit:
	if PartyManager.pending_leader:
		var made: Unit = PartyManager.spawn_member(PartyManager.pending_leader, area, spawn_point)
		PartyManager.pending_leader = null
		return made
	return _spawn_companion(area, spawn_point, 0)


## persistent_id is stamped from the definition's id rather than minted at
## first capture, so two units can never answer to the same id.
static func _spawn_companion(area: Node3D, spawn_point: Node3D, index: int) -> Unit:
	var definition: UnitDefinition = load(COMPANIONS[index])
	var unit: Unit = definition.unit_scene.instantiate()
	# BEFORE add_child: Unit._enter_tree adopts the body a definition names.
	unit.definition = definition
	unit.persistent_id = StringName("companion_%s" % definition.id)
	area.add_child(unit)
	unit.position = spawn_point.position + COMPANION_OFFSETS[index]
	return unit
