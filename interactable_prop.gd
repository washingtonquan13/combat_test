class_name InteractableProp
extends StaticBody3D
## Minimal non-Unit interactable — proves get_interactions() works for
## something that isn't a Unit before any real content (a chest, a door)
## gets built on top of it. No inventory/loot wiring yet, deliberately —
## see interactions below, which just carries Examine for now.
##
## Scene setup: a StaticBody3D with a CollisionShape3D (any shape) and
## your own mesh — same physics layer as everything else in this project
## (Unit and GroundClickTarget both run on Godot's plain default
## layer/mask; there's no separate "interactable" layer to opt into, see
## indicator_base.gd's _get_hovered_interactable()).

## Right-click verbs this prop can ever offer — same authored/reusable
## .tres list convention as Unit.interactions.
@export var interactions: Array[InteractionOption] = []


## Identical in shape to Unit.get_interactions() — deliberately duplicated
## rather than shared, see interaction_option.gd's own header for why two
## call sites isn't worth abstracting yet.
func get_interactions(actor: Unit) -> Array[InteractionOption]:
	var result: Array[InteractionOption] = []
	for option in interactions:
		if option.is_available(actor, self):
			result.append(option)
	return result
