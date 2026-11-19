class_name Rest
extends RefCounted
## Resting, owned by the rest system (see docs/systems/rest.md). Two
## kinds, and nothing about the party's state gates either: whoever is
## alive is rested, the Downed included.
##
## At an inn (the plate on Morrow's square, rest_spot.gd): free, restores
## everything, never ambushed. The party stays where it is.
##
## Anywhere else, with R (rest_key.gd): the party makes camp. The screen
## goes black and the camp area loads (camp.gd), where the rest is taken:
## everything back if the party had a SUPPLIES to spend, half without.
## Where the world being left has a say in whether the camp is found
## (duck-typed rest_ambush(); the overworld's rolls the district's
## danger, see overworld.gd), the ambush walks into the camp after the
## rest, or before it with Camp.ambush_interrupts. R again breaks camp,
## and the party is back where it made it.
##
## Both repopulate the overworld's cleared encounters
## (OverworldEncounters.clear_all). There is no clock.

const SUPPLIES: ItemDefinition = preload("res://data/items/camp_supplies.tres")
## The camp's area id.
const CAMP_AREA := &"camp"
## The camp being made or stood in: {"from": area id, "supplied": bool,
## "ambush": {"group", "district"} or {}, "rested": bool}. A flag, so a
## save made at camp, or Retry on an ambush there, comes back to it.
const CAMP_FLAG := "rest/camp"
## What a rest without supplies gives back, of each pool's maximum.
const UNSUPPLIED_FRACTION := 0.5

## Where each member stood when camp was made (Unit -> Transform3D), to
## put them back on breaking it. Not saved: a load at camp breaks it to
## the area's ordinary arrival point.
static var _stood: Dictionary = {}


## Why a rest can't be taken now, or "" when it can.
static func blocked_reason() -> String:
	if CombatManager.any_combat_running():
		return "You can't rest with enemies near."
	var mode := GameMode.current_mode()
	if mode != GameMode.Mode.EXPLORATION and mode != GameMode.Mode.OVERWORLD:
		return "You can't rest now."
	return ""


## R: make camp, or break the one the party is in.
static func rest_key() -> void:
	if WorldManager.current_world() is Camp:
		break_camp()
	else:
		make_camp()


## Free and whole, where the party stands. True when taken.
static func inn_rest() -> bool:
	var reason := blocked_reason()
	if reason != "":
		SystemLog.print(reason)
		return false
	restore(1.0)
	OverworldEncounters.clear_all()
	SystemLog.print("The party sleeps at the inn, and wakes whole.")
	return true


## Spends the supplies, rolls the ambush and writes CAMP_FLAG; the
## journey itself is make_camp's. Returns the flag's value, or {} when
## refused. Split out so the bookkeeping can be checked without a trip.
static func plan_camp() -> Dictionary:
	var reason := blocked_reason()
	if reason != "":
		SystemLog.print(reason)
		return {}
	var world: Node = WorldManager.current_world()
	var area := WorldManager.current_area()
	var supplied := has_supplies()
	if supplied:
		PartyManager.inventory.consume(SUPPLIES)
	var ambush: Dictionary = {}
	if is_instance_valid(world) and world.has_method("rest_ambush"):
		ambush = world.rest_ambush()
	var plan := {
		"from": String(area.id) if area else "",
		"supplied": supplied,
		"ambush": ambush,
		"rested": false,
	}
	FlagManager.set_flag(CAMP_FLAG, plan)
	_stood.clear()
	for unit in PartyManager.members:
		if is_instance_valid(unit) and unit.is_inside_tree():
			_stood[unit] = unit.global_transform
	return plan


static func make_camp() -> void:
	if plan_camp().is_empty():
		return
	SystemLog.print("The party makes camp." if has_supplies_spent() else
		"The party makes camp with no %s." % SUPPLIES.item_name)
	WorldManager.travel_area(CAMP_AREA)


## Back to where camp was made, standing where they stood.
static func break_camp() -> void:
	if CombatManager.any_combat_running():
		SystemLog.print("You can't break camp with enemies near.")
		return
	var plan := camp()
	FlagManager.clear_flag(CAMP_FLAG)
	var from := StringName(plan.get("from", ""))
	if from == &"" or AreaDatabase.find(from) == null:
		from = &"overworld"
	var stood := _stood.duplicate()
	_stood.clear()
	WorldManager.behind_black(func() -> void:
		UIStack.close_all()
		WorldManager.load_area(from)
		for unit: Unit in stood:
			if is_instance_valid(unit) and unit.is_inside_tree():
				unit.global_transform = stood[unit])


## The camp under way, or {} with none.
static func camp() -> Dictionary:
	var value: Variant = FlagManager.get_flag(CAMP_FLAG, {})
	return value if value is Dictionary else {}


static func has_supplies_spent() -> bool:
	return bool(camp().get("supplied", false))


## The night's rest at camp, once: what the supplies bought, then the
## cleared encounters back. camp.gd calls it.
static func rest_at_camp() -> void:
	var plan := camp()
	if plan.is_empty() or plan.get("rested", false):
		return
	plan.rested = true
	FlagManager.set_flag(CAMP_FLAG, plan)
	var supplied := bool(plan.get("supplied", false))
	restore(1.0 if supplied else UNSUPPLIED_FRACTION)
	OverworldEncounters.clear_all()
	SystemLog.print("The party rests through the night, and wakes whole." if supplied else
		"The party rests, hungry, and wakes half-mended.")


## Gives every living member back `fraction` of each pool's maximum, up
## to full; the Downed are picked up by it (heal() does that once HP
## rises). A whole rest fills the benched demons too.
static func restore(fraction: float) -> void:
	for unit in PartyManager.members:
		if not is_instance_valid(unit) or not unit.is_alive():
			continue
		# Whole is to the top, from however far below 0 the Downed are.
		var top := floori(unit.get_stat(StatIds.HP))
		var missing := top - unit.get_pool(StatIds.HP)
		if missing > 0:
			unit.heal(missing if fraction >= 1.0 else mini(missing, ceili(top * fraction)))
		top = floori(unit.get_stat(StatIds.FP))
		missing = top - unit.get_pool(StatIds.FP)
		if missing > 0:
			unit.restore_pool(StatIds.FP, missing if fraction >= 1.0 else mini(missing, ceili(top * fraction)))
	if fraction >= 1.0:
		for demon in DemonRoster.all_owned():
			if not demon.is_dead and not DemonRoster.is_fielded(demon):
				demon.fill_pools()


static func has_supplies() -> bool:
	return PartyManager.inventory != null and PartyManager.inventory.has(SUPPLIES)


static func supplies_count() -> int:
	var total := 0
	if PartyManager.inventory:
		for item: ItemInstance in PartyManager.inventory.items():
			if item.definition == SUPPLIES:
				total += item.count
	return total
