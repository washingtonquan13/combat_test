@tool
extends EditorScript
## File > Run (with this script open in the Script editor): creates
## res://cinematics/new_cinematic.tscn — or new_cinematic_2.tscn and so on
## if that is taken — and opens it.
##
## WHY A SCRIPT AND NOT A TEMPLATE .tscn TO DUPLICATE. A stage is found by
## child NAMES (Timeline, Roles, Shots, Marks, Beats — see
## cinematic_stage.gd), and a copied template carries whatever someone last
## left in it. Building it here keeps the skeleton exactly the convention
## and nothing more. It asks nothing: rename the file and the root after.
##
## What you get: Roles/leader, one Shots/wide framing the leader, empty
## Marks/ and Beats/, and a Timeline with an empty 3-second "scene"
## animation (the name CinematicDirector.play() performs by default).

const FOLDER: String = "res://cinematics"
const BASE_NAME: String = "new_cinematic"
const LENGTH_SECONDS: float = 3.0

## The stage being built; every node's owner. See _add().
var _root: CinematicStage = null


func _run() -> void:
	var path: String = _free_path()
	var stage: CinematicStage = _build()
	var packed := PackedScene.new()
	var packed_ok: Error = packed.pack(stage)
	stage.free()
	_root = null
	if packed_ok != OK:
		push_error("new_cinematic: could not pack the stage (error %d)." % packed_ok)
		return
	var saved: Error = ResourceSaver.save(packed, path)
	if saved != OK:
		push_error("new_cinematic: could not save %s (error %d)." % [path, saved])
		return
	EditorInterface.get_resource_filesystem().update_file(path)
	EditorInterface.open_scene_from_path(path)
	print("new_cinematic: created %s" % path)


func _free_path() -> String:
	var path: String = "%s/%s.tscn" % [FOLDER, BASE_NAME]
	var suffix: int = 2
	while ResourceLoader.exists(path) or FileAccess.file_exists(path):
		path = "%s/%s_%d.tscn" % [FOLDER, BASE_NAME, suffix]
		suffix += 1
	return path


func _build() -> CinematicStage:
	var stage := CinematicStage.new()
	stage.name = "NewCinematic"
	_root = stage

	var roles := _add(stage, Node3D.new(), CinematicStage.ROLES_NAME)
	var leader := StageRole.new()
	_add(roles, leader, &"leader")

	_add(stage, Node3D.new(), CinematicStage.MARKS_NAME)

	var shots := _add(stage, Node3D.new(), CinematicStage.SHOTS_NAME)
	var wide := FramingRig.new()
	wide.subject_role = &"leader"
	wide.distance = 6.0
	wide.azimuth_degrees = 20.0
	wide.elevation_degrees = 20.0
	wide.fov_degrees = 50.0
	_add(shots, wide, &"wide")

	_add(stage, Node.new(), CinematicStage.BEATS_NAME)

	var performance := Animation.new()
	performance.length = LENGTH_SECONDS
	performance.step = 0.1
	var library := AnimationLibrary.new()
	library.add_animation(CinematicStage.DEFAULT_ANIMATION, performance)
	var timeline := AnimationPlayer.new()
	# Immediate, matching fusion.tscn and demo_conversation.tscn.
	timeline.callback_mode_method = AnimationMixer.ANIMATION_CALLBACK_MODE_METHOD_IMMEDIATE
	timeline.add_animation_library(&"", library)
	_add(stage, timeline, CinematicStage.TIMELINE_NAME)
	return stage


## Owned by the ROOT, not the parent: pack() only saves nodes whose owner
## is the node being packed.
func _add(parent: Node, child: Node, child_name: StringName) -> Node:
	child.name = child_name
	parent.add_child(child)
	child.owner = _root
	return child
