class_name Rest
extends RefCounted
## Resting, owned by the rest system (see docs/systems/rest.md). Two
## kinds:
##
## A short rest, taken anywhere out of combat with R (rest_key.gd): free,
## restores SHORT_FRACTION of every standing member's HP and FP, and
## leaves the Downed where they lie. Where the focused world has a say in
## whether you are left alone (duck-typed roll_rest_ambush(); the
## overworld's rolls the district's danger, see overworld.gd), an ambush
## means no rest at all.
##
## A full rest, at a safe spot (the inn on Morrow's square, rest_spot.gd):
## costs one SUPPLIES, restores everything, picks up the Downed, refills
## every demon in the roster, and is never ambushed.
##
## Both repopulate the overworld's cleared encounters
## (OverworldEncounters.clear_all). There is no clock.

const SUPPLIES: ItemDefinition = preload("res://data/items/camp_supplies.tres")
## How much of each pool a short rest gives back, of its maximum.
const SHORT_FRACTION := 0.5


## Why a rest can't be taken now, or "" when it can.
static func blocked_reason() -> String:
	if CombatManager.any_combat_running():
		return "You can't rest with enemies near."
	var mode := GameMode.current_mode()
	if mode != GameMode.Mode.EXPLORATION and mode != GameMode.Mode.OVERWORLD:
		return "You can't rest now."
	if _standing().is_empty() and _downed().is_empty():
		return "There is nobody to rest."
	return ""


## True when the rest was taken; false when it was refused or ambushed.
static func short_rest() -> bool:
	var reason := blocked_reason()
	if reason != "":
		SystemLog.print(reason)
		return false
	var world: Node = WorldManager.current_world()
	if is_instance_valid(world) and world.has_method("roll_rest_ambush") and world.roll_rest_ambush():
		SystemLog.print("The party settles down to rest, and is set upon.")
		return false
	for unit in _standing():
		for id in [StatIds.HP, StatIds.FP]:
			var top := floori(unit.get_stat(id))
			var missing := top - unit.get_pool(id)
			if missing > 0:
				unit.restore_pool(id, mini(missing, ceili(top * SHORT_FRACTION)))
	OverworldEncounters.clear_all()
	SystemLog.print("The party takes a short rest.")
	return true


static func has_supplies() -> bool:
	return PartyManager.inventory != null and PartyManager.inventory.has(SUPPLIES)


static func supplies_count() -> int:
	var total := 0
	if PartyManager.inventory:
		for item: ItemInstance in PartyManager.inventory.items():
			if item.definition == SUPPLIES:
				total += item.count
	return total


## True when the rest was taken; false with no supplies or when refused.
static func full_rest() -> bool:
	var reason := blocked_reason()
	if reason != "":
		SystemLog.print(reason)
		return false
	if not has_supplies():
		SystemLog.print("The party has no %s to rest with." % SUPPLIES.item_name)
		return false
	PartyManager.inventory.consume(SUPPLIES)
	for unit in _standing() + _downed():
		# heal() picks a Downed unit up once its HP rises.
		unit.heal(floori(unit.get_stat(StatIds.HP)) - unit.get_pool(StatIds.HP))
		unit.set_pool(StatIds.FP, floori(unit.get_stat(StatIds.FP)))
	for demon in DemonRoster.all_owned():
		if not demon.is_dead and not DemonRoster.is_fielded(demon):
			demon.fill_pools()
	OverworldEncounters.clear_all()
	SystemLog.print("The party rests through the night, and wakes whole.")
	return true


static func _standing() -> Array[Unit]:
	var out: Array[Unit] = []
	for unit in PartyManager.members:
		if is_instance_valid(unit) and unit.is_alive() and not unit.is_downed():
			out.append(unit)
	return out


static func _downed() -> Array[Unit]:
	var out: Array[Unit] = []
	for unit in PartyManager.members:
		if is_instance_valid(unit) and unit.is_alive() and unit.is_downed():
			out.append(unit)
	return out
