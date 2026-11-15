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
const RAID_STAGE: PackedScene = preload("res://cinematics/camp_raid.tscn")
const RAID_PLAYED := "raid_camp.raid_played"
## The camp's people and the raiders, by role in the stage: node name here.
const RAID_CAST := {
	&"lookout": "Lookout", &"guard_gate": "GuardGate", &"guard_fire": "GuardFire",
	&"camper_fire": "CamperFire", &"camper_tent": "CamperTent", &"hobgoblin": "Hobgoblin",
	&"rogue_a": "RogueA", &"rogue_b": "RogueB", &"rogue_c": "RogueC", &"rogue_d": "RogueD",
	&"archer_west": "ArcherWest", &"archer_east": "ArcherEast",
}
## Who fights once the raid has played: the goblins, the armed camp and the
## party. The campers hide.
const RAID_FIGHTERS: Array[StringName] = [
	&"lookout", &"guard_gate", &"guard_fire", &"hobgoblin",
	&"rogue_a", &"rogue_b", &"rogue_c", &"rogue_d", &"archer_west", &"archer_east",
]

@onready var _gate_shut: StaticBody3D = $Gate/Closed
@onready var _gate_smashed: Node3D = $Gate/Broken


func _ready() -> void:
	if FlagManager.has_flag(GATE_BROKEN):
		_show_broken()
	WorldManager.world_focused.connect(_on_world_focused)


## The raid plays the first time the party arrives, and the fight starts
## from where it left everyone: the lookout dead under the wall, the gate
## guard cut down, the guard at the fire wounded, the gate in pieces. Every
## precondition returns before the flag is set, so an arrival that cannot
## have the scene gets it on a later one; a cast member already dead means
## the camp the scene shows is gone, and it never plays.
func _on_world_focused(world: Node) -> void:
	if world != self or FlagManager.has_flag(RAID_PLAYED):
		return
	await get_tree().process_frame
	await get_tree().process_frame
	if GameMode.current_mode() != GameMode.Mode.EXPLORATION:
		return
	var units := _raid_units()
	if units.is_empty():
		return
	var leader: Unit = units[&"leader"]
	var cast := SceneCast.new()
	for role: StringName in units:
		cast.track_unit(role, units[role])
	FlagManager.set_flag(RAID_PLAYED)

	var party: Array[Unit] = [leader]
	var group := PartyManager.group_of(leader)
	if group:
		party = group.live_units()
	for member in party:
		member.stop_moving()
	var finished: bool = await CinematicDirector.play(RAID_STAGE, cast)
	if not finished:
		return  # Aborted: the director released everything, something else owns the screen.
	var camera := CinematicDirector.camera()
	if camera:
		camera.release()

	var roster: Array[Unit] = []
	var fighters: Array = party + RAID_FIGHTERS.map(func(role: StringName) -> Unit: return units[role])
	for unit in fighters:
		if is_instance_valid(unit) and unit.is_alive() and not unit.in_combat():
			roster.append(unit as Unit)
	CombatManager.start_combat(roster)


## The raid, while it has yet to play and the camp it shows is all still
## here - the same checks that decide to play it, bar the mode, which is
## still settling on the arrival that asks.
func arrival_scene() -> PackedScene:
	if FlagManager.has_flag(RAID_PLAYED) or _raid_units().is_empty():
		return null
	return RAID_STAGE


## Role -> unit for the raid, the party leader as &"leader"; empty if any of
## them cannot play it.
func _raid_units() -> Dictionary:
	var leader: Unit = PartyManager.leader
	if not is_instance_valid(leader) or not leader.is_alive() or leader.in_combat() \
			or not leader.is_inside_tree():
		return {}
	var units: Dictionary = {&"leader": leader}
	for role: StringName in RAID_CAST:
		var unit := get_node_or_null(RAID_CAST[role]) as Unit
		if unit == null or not unit.is_alive() or unit.in_combat():
			return {}
		units[role] = unit
	return units


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
