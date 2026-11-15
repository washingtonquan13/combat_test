class_name RaidCamp
extends GameArea
## The palisade camp the goblins raid. Built by tools/camp/bake_raid_camp.gd;
## the scene is that script's output.
##
## The one thing here that changes is the north gate. Shut, it is two leaves
## with collision; broken, the leaves lie smashed inside and nothing stops a
## body. Which one is there is a flag, so a gate broken in a scene stays
## broken in the fight after it, in a save, and on every later visit.

const GATE_BROKEN := "raid_camp.gate_broken"

@onready var _gate_shut: StaticBody3D = $Gate/Closed
@onready var _gate_smashed: Node3D = $Gate/Broken


func _ready() -> void:
	if FlagManager.has_flag(GATE_BROKEN):
		_show_broken()


func gate_is_broken() -> bool:
	return FlagManager.has_flag(GATE_BROKEN)


## Smashes the gate in: remembered from now on, and the ground the leaves
## stood on is walkable at once.
func break_gate() -> void:
	if gate_is_broken() and _gate_shut == null:
		return
	FlagManager.set_flag(GATE_BROKEN)
	var was := _gate_box()
	_show_broken()
	NavigationGrid.invalidate_region(self, was)


func _show_broken() -> void:
	_gate_smashed.visible = true
	if _gate_shut:
		# Freed, not disabled: the nav grid scans disabled shapes too.
		_gate_shut.get_parent().remove_child(_gate_shut)
		_gate_shut.queue_free()
		_gate_shut = null


func _gate_box() -> AABB:
	if _gate_shut == null:
		return AABB()
	var box := AABB(_gate_shut.global_position, Vector3.ZERO)
	for child in _gate_shut.get_children():
		if child is CollisionShape3D and child.shape is BoxShape3D:
			var size: Vector3 = (child.shape as BoxShape3D).size
			box = box.merge(AABB(child.global_position - size * 0.5, size))
	return box.grow(0.5)
