class_name SceneSoundStep
extends SceneStep
## Plays a sound somewhere in a scene.
##
## MIRRORS PlaySoundStep deliberately rather than reusing it. That one is a
## VfxStep with a different signature, so reaching it from here means
## authoring a whole VfxEffect wrapper to play one sound — indirection a
## scene author would pay for on every line of dialogue-free spectacle.
## Fifteen lines duplicated is the cheaper mistake, and if a third caller
## ever wants the same thing, that is when the spawn-and-free logic earns
## being extracted.
##
## Cleanup IS handled, unlike a particle scene: AudioStreamPlayer3D has a
## reliable finished signal whatever clip is assigned.

@export var stream: AudioStream
## Where it comes from. A mark wins over a role when both are given.
@export var at_role: StringName = &""
@export var at_mark: StringName = &""


func apply(cast: SceneCast) -> void:
	if stream == null:
		return
	var context: Node = WorldManager.spawn_parent()
	if context == null or not context.is_inside_tree():
		return
	var player := AudioStreamPlayer3D.new()
	context.add_child(player)
	player.stream = stream
	player.global_position = cast.point(at_mark, at_role)
	player.play()
	player.finished.connect(player.queue_free)


func describe() -> String:
	return "sound at '%s' at %.2fs" % [
		at_mark if at_mark != &"" else at_role, offset]
