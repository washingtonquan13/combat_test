class_name CinematicScene
extends Resource
## A staged moment: what the camera and the actors do, independent of who
## asked for it.
##
## NAMED CinematicScene, NOT Scene, deliberately. In Godot "scene" already
## means a .tscn, and a Resource called Scene that is not a PackedScene
## would read as one at every call site.
##
## Either a TIMELINE or a single immediate cut — see the two kinds below.
## A conversation is the second: one phase, no duration, one camera step at
## offset zero, which is how dialogue gets staging without a bypass around
## this file. Everything else is the first.

## TWO KINDS OF SCENE, and the difference is a question of authoring
## surface rather than of capability.
##
##   TIMED      `stage` is set. The scene is an authored .tscn whose
##              AnimationPlayer holds the whole performance on one
##              scrubbable timeline — value tracks on a FramingRig for the
##              camera, method tracks on the CinematicStage for everything
##              a step used to do. An author sees the shot while making it.
##   IMMEDIATE  only `phases`. Steps at offsets inside spans of time,
##              driven by the director's own clock. In practice this is now
##              exactly one shape: a single phase of zero duration carrying
##              one camera cut, which is what every line of dialogue
##              stages. It never awaits, so a conversation costs nothing.
##
## A stage WINS when both are present. There is exactly one performance,
## and the timeline is it; phases alongside a stage are the pre-migration
## record, not a second track that also runs.

@export var id: StringName = &""
@export var phases: Array[ScenePhase] = []

@export_group("Timeline")
## The authored stage — a .tscn whose root is a CinematicStage. Null means
## this scene is driven by its phases instead.
@export var stage: PackedScene
## Which animation on the stage's "Timeline" AnimationPlayer is the
## performance. Named rather than assumed so one stage can hold variants
## of a moment (a short version, a first-time-only version) without a
## second .tscn.
@export var animation: StringName = &"scene"


## Whether this scene's performance comes from a timeline rather than from
## the director's own clock.
func is_timed() -> bool:
	return stage != null


## Steps that can never fire, across the whole scene. Empty is correct.
func unreachable_steps() -> Array[SceneStep]:
	var lost: Array[SceneStep] = []
	for phase in phases:
		if phase:
			lost.append_array(phase.unreachable_steps())
	return lost


func describe() -> String:
	if is_timed():
		return "%s timed [%s:%s]" % [
			id, stage.resource_path.get_file().get_basename(), animation]
	var parts: PackedStringArray = []
	for phase in phases:
		if phase == null:
			continue
		var beats: PackedStringArray = []
		for step in phase.steps:
			if step:
				beats.append(step.describe())
		parts.append("[%.2fs: %s]" % [phase.duration_seconds, ", ".join(beats)])
	return "%s immediate %s" % [id, " -> ".join(parts)]
