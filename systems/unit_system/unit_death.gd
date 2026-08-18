class_name UnitDeath
extends RefCounted
## Owns this unit's death-cleanup moment — strips a dead unit out of
## every system that would otherwise keep treating it as a live
## participant, then frees the node. Not "lifecycle" more broadly:
## nothing here handles spawning/initialization, only this one cleanup
## path, reached either through actual damage (UnitCombat.take_damage())
## or through expire() below (no damage involved — a summon's tracking
## status running out, e.g.).


var _owner: Unit


func _init(owner: Unit) -> void:
	_owner = owner


## Removes this unit from combat and frees it without going through
## damage — used when a summon's tracking status expires (see
## DespawnOnExpireBehavior). Reuses the exact same cleanup as a real
## death (handle_death() + the died signal) since every system that
## needs to know "this unit is gone" — CombatManager's turn_order
## pruning, initiative UI, the animator/VFX death reactions — already
## listens to died; a summon leaving combat this way is exactly that,
## just not caused by damage, so it gets its own log line instead of
## "has died". current_hp is zeroed (not left as whatever it was) so
## is_alive() agrees with everything else — CombatManager._advance_turn(),
## notably, which decides whether to keep giving this unit turns purely
## off is_alive(), same as an ordinary death; without this, a summon
## expiring on its OWN turn would still get turn_started emitted for it
## a moment before its queue_free() actually takes effect.
func expire() -> void:
	SystemLog.print("%s fades away." % LogFormat.unit_name(_owner))
	_owner.current_hp = 0
	# _owner.handle_death(), not a same-class handle_death() call — routes
	# through Unit's own wrapper (see unit.gd) so this path picks up
	# _selection.teardown() too, not just this file's own cleanup. Both
	# calls land on this exact same UnitDeath instance either way; this
	# only changes which entry point gets there.
	_owner.handle_death()
	_owner.died.emit(_owner)


## Strips a dead unit out of every system that would otherwise keep
## treating it as a live participant, then frees the node (after
## death_cleanup_delay, if set). remove_from_group happens first and
## immediately — anything that queries the "units" group (CombatAI's
## targeting, drag-select) stops seeing this unit the instant it dies,
## regardless of how long the actual node sticks around for a death
## animation.
func handle_death() -> void:
	_owner.remove_from_group("units")
	_owner.input_ray_pickable = false

	if _owner.is_selected:
		SelectionManager.deselect(_owner)
	_owner.set_box_hover(false)

	# Stop moving entirely — a corpse shouldn't keep trying to walk
	# anywhere. It's also already excluded from PathAvoidance's obstacle
	# gathering by the remove_from_group("units") call above, so other
	# units won't detour around it either (matches corpse_blocks_movement
	# below, which controls whether it still blocks via physical
	# collision). force_stop_movement(), not stop_moving() — this is an
	# immediate, raw halt with no movement_finished signal and no budget
	# spend; a dying unit isn't "completing" a move, it's being silenced.
	_owner.force_stop_movement()
	_owner.set_physics_process(false)

	if _owner.corpse_blocks_movement:
		# remove_from_group("units") above means NavigationGrid.
		# update_occupancy will never see this unit via the normal "units"
		# group loop again — a separate group is what lets a corpse that's
		# meant to keep blocking movement still get marked occupied on the
		# grid (see that function), instead of silently becoming
		# pathable-through the instant it dies even though it still
		# physically collides.
		_owner.add_to_group("blocking_corpses")
	else:
		_owner.collision_layer = 0
		_owner.collision_mask = 0

	# Summoned dependents don't outlive their summoner — expire(), not a
	# raw queue_free(), so each one still goes through this exact same
	# cleanup path (occupancy update, corpse handling, its own died
	# signal) and can itself cascade to whatever IT summoned in turn.
	# Scans "units" rather than a maintained back-reference list — same
	# idiom every other "find related units" query in this project
	# already uses (combat_ai.gd's nearest-hostile search, the AoE
	# effects), and get_nodes_in_group returns a fresh snapshot array, so
	# a dependent's own expire() call removing ITSELF from "units"
	# mid-loop can't disturb this iteration.
	for node in _owner.get_tree().get_nodes_in_group("units"):
		var dependent := node as Unit
		if dependent and dependent.summoned_by == _owner:
			dependent.expire()

	if _owner.death_cleanup_delay > 0.0:
		_owner.get_tree().create_timer(_owner.death_cleanup_delay).timeout.connect(_owner.queue_free)
	else:
		_owner.queue_free()
