extends Node
## Builds throwaway cutscenes for the cinematic suites: a CinematicStage
## packed in memory, the same shape an author's .tscn has.
##
## A Node rather than RefCounted because the runner instantiates every
## script under tests/ and free()s whatever is not a test case, and free()
## on a RefCounted is an error. It is only ever used through its static.

## A stage whose "scene" animation lasts `seconds`, with one method track
## per beat keying fire() at the time given. `beats` is [[BeatNode, time]]:
## each beat is added under Beats/ by its own name.
static func make(seconds: float, beats: Array = []) -> PackedScene:
	var stage := CinematicStage.new()
	stage.name = &"FixtureStage"

	var player := AnimationPlayer.new()
	player.name = CinematicStage.TIMELINE_NAME
	player.callback_mode_method = AnimationPlayer.ANIMATION_CALLBACK_MODE_METHOD_IMMEDIATE
	stage.add_child(player)
	for holder_name in [CinematicStage.ROLES_NAME, CinematicStage.SHOTS_NAME,
			CinematicStage.BEATS_NAME]:
		var holder := Node3D.new()
		holder.name = holder_name
		stage.add_child(holder)

	var anim := Animation.new()
	anim.length = seconds
	var beat_holder: Node = stage.get_node(NodePath(CinematicStage.BEATS_NAME))
	for pair in beats:
		var beat: BeatNode = pair[0]
		beat_holder.add_child(beat)
		var track: int = anim.add_track(Animation.TYPE_METHOD)
		anim.track_set_path(track, NodePath("%s/%s" % [CinematicStage.BEATS_NAME, beat.name]))
		anim.track_insert_key(track, float(pair[1]), {"method": &"fire", "args": []})

	var library := AnimationLibrary.new()
	library.add_animation(CinematicStage.DEFAULT_ANIMATION, anim)
	player.add_animation_library(&"", library)

	for child in stage.find_children("*", "", true, false):
		child.owner = stage
	var packed := PackedScene.new()
	packed.pack(stage)
	stage.free()
	return packed
