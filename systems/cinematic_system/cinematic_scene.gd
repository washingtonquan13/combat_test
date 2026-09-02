class_name CinematicScene
extends Resource
## A staged moment: what the camera and the actors do, independent of who
## asked for it.
##
## NAMED CinematicScene, NOT Scene, deliberately. In Godot "scene" already
## means a .tscn, and a Resource called Scene that is not a PackedScene
## would read as one at every call site.
##
## Ordered phases, each with its own span of time and steps at offsets
## inside it (see ScenePhase for why the phase is the atom rather than the
## step). A conversation is the degenerate case: one phase, no duration,
## one camera step at offset zero — which is how dialogue gets staging
## without a bypass around this file.

@export var id: StringName = &""
@export var phases: Array[ScenePhase] = []


## Steps that can never fire, across the whole scene. Empty is correct.
func unreachable_steps() -> Array[SceneStep]:
	var lost: Array[SceneStep] = []
	for phase in phases:
		if phase:
			lost.append_array(phase.unreachable_steps())
	return lost


func describe() -> String:
	var parts: PackedStringArray = []
	for phase in phases:
		if phase == null:
			continue
		var beats: PackedStringArray = []
		for step in phase.steps:
			if step:
				beats.append(step.describe())
		parts.append("[%.2fs: %s]" % [phase.duration_seconds, ", ".join(beats)])
	return "%s %s" % [id, " -> ".join(parts)]
