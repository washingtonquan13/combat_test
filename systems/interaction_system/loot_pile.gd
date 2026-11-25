class_name LootPile
extends Node3D
## What a broken container leaves: its StashComponent, now on the floor
## where it stood, lootable the way a corpse is (Corpse's pick area on
## Corpse.PICK_LAYER, found by GroundClickTarget._pick_under_mouse). Gone
## once emptied. Spawned, so not saved (spawned_units_dont_persist): a
## pile left in an area is not there after a reload.

const LOOT: InteractionOption = preload("res://data/interactions/loot.tres")
const PICK_SIZE: Vector3 = Vector3(0.7, 0.35, 0.7)

var interactions: Array[InteractionOption] = [LOOT]

var _pick: Area3D


## Moves stash here and names it for what it came out of.
func take(stash: StashComponent, from_name: String) -> void:
	stash.display_name = "%s (broken)" % from_name
	stash.reparent(self, false)
	var area := Area3D.new()
	area.name = "Pick"
	area.collision_layer = Corpse.PICK_LAYER
	area.collision_mask = 0
	area.monitoring = false
	area.monitorable = false
	area.input_ray_pickable = false
	var shape := CollisionShape3D.new()
	var cube := BoxShape3D.new()
	cube.size = PICK_SIZE
	shape.shape = cube
	shape.position = Vector3(0, PICK_SIZE.y * 0.5, 0)
	area.add_child(shape)
	add_child(area)
	_pick = area
	StashManager.stash_closed.connect(_on_stash_closed)


## Same shape as InteractableProp.get_interactions.
func get_interactions(actor: Unit) -> Array[InteractionOption]:
	var result: Array[InteractionOption] = []
	for option in interactions:
		if option.is_available(actor, self):
			result.append(option)
	return result


func _on_stash_closed() -> void:
	var stash := StashComponent.find_on(self)
	if stash and not stash.inventory.get_container().items().is_empty():
		return
	StashManager.stash_closed.disconnect(_on_stash_closed)
	queue_free()
