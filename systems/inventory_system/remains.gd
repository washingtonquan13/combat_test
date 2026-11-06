class_name Remains
extends InteractableProp
## What a killed monster leaves when it drops anything: a lootable spot
## where it fell, opened like a chest (its StashComponent), gone once
## it's emptied. The unit itself can't hold the loot — UnitDeath frees it.
##
## Spawned at runtime, so not persistent: like any spawned thing it isn't
## in an area's save (spawned_units_dont_persist).

const SCENE_PATH := "res://systems/inventory_system/remains.tscn"


## Rolls unit's drops (UnitDefinition.level/max_drops/drop_chance) and,
## if any came up, leaves them where it fell. Party members and owned
## demons drop nothing.
static func drop_for(unit: Unit) -> Remains:
	var definition: UnitDefinition = unit.definition
	if not definition or unit.owned_demon or PartyManager.is_member(unit):
		return null
	var rng := RandomNumberGenerator.new()
	var drops: Array[ItemInstance] = []
	for i in definition.max_drops:
		if rng.randf() < definition.drop_chance:
			var item := LootRoller.roll(definition.level, rng)
			if item:
				drops.append(item)
	if drops.is_empty():
		return null
	var remains: Remains = load(SCENE_PATH).instantiate()
	unit.get_parent().add_child(remains)
	remains.global_position = unit.global_position
	var stash := StashComponent.find_on(remains)
	stash.display_name = "Remains of %s" % unit.get_display_name()
	for item in drops:
		stash.put(item)
	return remains


func _ready() -> void:
	StashManager.stash_closed.connect(_on_stash_closed)


func _on_stash_closed() -> void:
	if StashComponent.find_on(self).inventory.get_container().items().is_empty():
		queue_free()
