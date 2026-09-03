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
	# through Unit's own public wrapper (see unit.gd), which is the entry
	# point every other death path uses too, so anything that wrapper ever
	# grows applies here as well. Both calls land on this exact same
	# UnitDeath instance either way; this only changes which entry point
	# gets there.
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
	# Recorded first, before any of the teardown below — this is a real
	# death (handle_death(), not expire(): a despawning summon never
	# carries a persistent_id, since only hand-placed content does — see
	# Unit.persistent_id's own header). Empty is the default for the
	# overwhelming majority of units (party members, summons), so this is
	# a no-op for them; current_area() is null outside a loaded area
	# (nothing calls WorldManager.load_world() with no AreaDefinition
	# today, but stays guarded regardless — see _current_area's header).
	if _owner.persistent_id != &"" and WorldManager.current_area():
		AreaState.mark_removed(WorldManager.current_area().id, _owner.persistent_id)

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
	# UnitQuery.dependents_of returns a fresh snapshot array, decoupled
	# from the live "units" group the instant it's built, so a
	# dependent's own expire() call removing ITSELF from "units" mid-loop
	# can't disturb this iteration.
	for dependent in UnitQuery.dependents_of(_owner.get_tree(), _owner):
		dependent.expire()

	if _owner.death_cleanup_delay > 0.0:
		_owner.get_tree().create_timer(_owner.death_cleanup_delay).timeout.connect(_owner.queue_free)
	else:
		_owner.queue_free()
