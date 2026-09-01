extends GameArea
## test_arena's own unique content — the one-time starting-party bootstrap
## and the goblinoid raid quest watcher. Everything else (world contract
## defaults, the debug combat harness) now lives on GameArea/
## debug_combat_harness.gd — see those files' own headers for why they
## moved out of here.

var _goblinoids_remaining: Array[Unit] = []


## The four the game starts with, and where they stand relative to
## PartySpawnPoint. The offsets reproduce exactly the positions the
## hand-placed nodes used to occupy.
const COMPANIONS: Array[String] = [
	"res://data/units/companions/tiefling_wizard.tres",
	"res://data/units/companions/human_barbarian.tres",
	"res://data/units/companions/dwarf_fighter.tres",
	"res://data/units/companions/elf_ranger.tres",
]
const COMPANION_OFFSETS: Array[Vector3] = [
	Vector3(0.0, 0.0, 0.0),
	Vector3(-9.0, 0.0, 0.0),
	Vector3(-6.0, 0.0, 0.0),
	Vector3(-3.0, 0.0, 0.0),
]


func _ready() -> void:
	_watch_goblinoid_raid_quest()

	# Built unconditionally. This used to be guarded on
	# WorldManager.is_restoring_party(), because the starting party WAS this
	# scene — four hand-placed nodes that every reload had to delete before
	# spawn_party() could rebuild the captured roster over the top. They are
	# data now, so there is nothing to lay out twice and nothing to free.
	#
	# A reload never reaches here at all: PartyManager still holds the
	# roster, so this area is re-entered rather than rebuilt.
	if not PartyManager.members.is_empty() or not PartyManager.roster.is_empty():
		return

	var leader: Unit = _build_leader()
	PartyManager.add_member(leader)
	for i in range(1, COMPANIONS.size()):
		PartyManager.add_member(_spawn_companion(i))
	PartyManager.set_leader(leader)


## The real leader for this session: the character chargen produced if
## there is one, and the authored wizard otherwise.
##
## The fallback is not a placeholder standing in for a story character any
## more — it is a companion definition like the other three, spawned the
## same way. That fallback has to keep working: a headless test loading
## straight into this scene never runs chargen.
func _build_leader() -> Unit:
	if PartyManager.pending_leader:
		var made: Unit = PartyManager.spawn_member(
			PartyManager.pending_leader, self, $PartySpawnPoint)
		PartyManager.pending_leader = null
		return made
	return _spawn_companion(0)


## One companion, built from its definition.
##
## persistent_id is stamped from the definition's own id rather than left
## to be minted at first capture. An authored party member that arrives
## without one is exactly the case PartyManager.capture() calls out, and
## leaving it to chance is how two units ended up answering to the same id.
func _spawn_companion(index: int) -> Unit:
	var definition: UnitDefinition = load(COMPANIONS[index])
	var unit: Unit = definition.unit_scene.instantiate()
	# BEFORE add_child: Unit._enter_tree is what adopts the body a
	# definition names.
	unit.definition = definition
	unit.persistent_id = StringName("companion_%s" % definition.id)
	add_child(unit)
	unit.position = ($PartySpawnPoint as Node3D).position + COMPANION_OFFSETS[index]
	return unit


## Connected unconditionally at scene start, NOT through the debug combat
## harness — that only wires up when combat starts via the K-key test
## harness, so it'd silently never fire for combat triggered the real way
## (clicking the hostile unit directly). The Scared Townperson's second
## dialogue phase (see her dialogue_options / resolved_hub.tres) depends
## on this flag actually getting set in a normal playthrough, not just
## the debug path.
## get_node_or_null(), not $GoblinRogue/$Hobgoblin directly — a
## goblinoid with a persistent_id can legitimately be ABSENT from this
## scene by the time _ready() runs: WorldManager's AreaState
## reconciliation pass (see world_manager.gd) frees a defeated one
## before the world ever enters the tree, on every re-entry after the
## quest was already resolved once. A raid already fully resolved in a
## prior visit needs no watcher at all — townsperson_raids_resolved was
## already set the moment the last one died.
func _watch_goblinoid_raid_quest() -> void:
	var candidates: Array[Unit] = [
		get_node_or_null("GoblinRogue") as Unit,
		get_node_or_null("Hobgoblin") as Unit,
	]
	_goblinoids_remaining = candidates.filter(func(u): return is_instance_valid(u))
	for goblinoid in _goblinoids_remaining:
		goblinoid.died.connect(_on_goblinoid_died)


func _on_goblinoid_died(unit: Unit) -> void:
	_goblinoids_remaining.erase(unit)
	if _goblinoids_remaining.is_empty():
		FlagManager.set_flag("townsperson_raids_resolved")
