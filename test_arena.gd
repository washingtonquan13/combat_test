extends GameArea
## test_arena's own unique content — the one-time starting-party bootstrap
## and the goblinoid raid quest watcher. Everything else (world contract
## defaults, the debug combat harness) now lives on GameArea/
## debug_combat_harness.gd — see those files' own headers for why they
## moved out of here.

var _goblinoids_remaining: Array[Unit] = []


## Bootstrap content, not a permanent architectural constraint — the 3
## non-leader companions are hand-placed today because that's how every
## unit in this project has been authored so far, not because
## PartyManager.members requires it. A future debug add/remove menu can
## add to (or remove from) this same roster at runtime without needing a
## party member to have ever been placed in this scene at all — see
## _build_leader() below, which already proves that shape for real.
func _ready() -> void:
	_watch_goblinoid_raid_quest()

	# Bootstrap-only: on a genuinely fresh load (nothing captured from a
	# prior world), this scene builds the starting roster from its own
	# hand-placed content, same as before WorldManager existed. On a
	# RELOAD of this same scene, WorldManager is about to spawn_party() a
	# captured roster the instant this _ready() returns (spawn_party()
	# needs this scene already in the tree, so it can't run any earlier)
	# — is_restoring_party() is what lets this scene tell the difference.
	# The 4 hand-placed party nodes below are a ONE-TIME bootstrap, not
	# permanent scene content: on a reload they'd otherwise sit in the
	# tree as unregistered duplicates of whatever spawn_party() is about
	# to create from the captured data, so they're freed instead.
	if WorldManager.is_restoring_party():
		$TieflingWizard.queue_free()
		$HumanBarbarian.queue_free()
		$DwarfFighter.queue_free()
		$ElfRanger.queue_free()
	else:
		var leader: Unit = _build_leader()
		PartyManager.add_member(leader)
		PartyManager.add_member($HumanBarbarian)
		PartyManager.add_member($DwarfFighter)
		PartyManager.add_member($ElfRanger)
		PartyManager.set_leader(leader)


## Returns the real leader Unit for this session — deliberately NOT the
## same thing as "reuse whatever's already hand-placed in the scene."
## If a character was actually created (see PartyManager.pending_leader,
## written by character_creation.gd on Confirm), this spawns a genuinely
## FRESH unit via PartyManager.spawn_member() (the same instantiate-and-
## cascade path a full world reload uses — see PartyManager's own capture/
## spawn header) and frees the hand-placed TieflingWizard node outright —
## she was only ever a bootstrap placeholder standing in for "the
## leader," never a specific story character, so keeping her around
## unused once a real one exists would just be a second, silent unit
## nobody asked for.
##
## Falls back to the hand-placed TieflingWizard, completely untouched,
## if chargen was never run (loading straight into this scene for a
## headless test, e.g.) — that fallback has to keep working exactly as
## it did before this existed.
func _build_leader() -> Unit:
	var placeholder: Unit = $TieflingWizard

	if not PartyManager.pending_leader:
		return placeholder

	var leader: Unit = PartyManager.spawn_member(PartyManager.pending_leader, self, placeholder)
	placeholder.queue_free()
	PartyManager.pending_leader = null
	return leader


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
