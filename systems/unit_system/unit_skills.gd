class_name UnitSkills
extends RefCounted
## Owns this unit's trained-skills container — see get_skills()/
## add_skill() below. Skills live as real SkillInstance children of a
## Skills node in the unit's scene, never a slot for every skill that
## exists in the game, only the ones actually trained.
##
## Takes over the $Skills reference at construction rather than via its
## own @onready — Godot resolves a node's children before the node's
## own _ready() runs, so this is safe to read the instant this
## component is constructed, same guarantee Unit's own @onready relied
## on before this moved.
##
## First component to own a scene-tree child directly — UnitEquipment
## deliberately leaves reparenting to EquipSlot instead. Private:
## nothing outside Unit should reach into this directly — the original
## design's bug was exactly that, external code finding the container by
## a hardcoded get_node("Skills") string path.

var _owner: Unit
var _container: Node


func _init(owner: Unit) -> void:
	_owner = owner
	_container = owner.get_node("Skills")


## Every SkillInstance this unit has actually trained.
func get_skills() -> Array[SkillInstance]:
	var result: Array[SkillInstance] = []
	for child in _container.get_children():
		if child is SkillInstance:
			result.append(child)
	return result


## Learns a new skill (or moves an already-existing SkillInstance under
## this unit, e.g. when reassigning one at runtime) — reparent rather
## than add_child so passing an instance that already belongs to another
## unit does the right thing instead of erroring.
func add_skill(skill_instance: SkillInstance) -> void:
	skill_instance.reparent(_container)
