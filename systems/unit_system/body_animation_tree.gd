class_name BodyAnimationTree
extends AnimationTree
## What shows a body's clips: an AnimationTree beside the body's
## AnimationPlayer, reading the player's clips and doing what the player
## used to do.
##
## The player keeps the clips and stops showing them (it is made inactive,
## so a stray play() on it cannot fight the tree). Everything that used to
## ask the player what it was showing asks this instead, under the same
## names: play(), seek(), current_animation, assigned_animation,
## current_animation_position, current_animation_length, is_playing() and
## animation_finished.
##
## It sits next to the player, not elsewhere, so it is processed at the
## point in the frame the player was, and a clip started by a script shows
## on the same frame it did before. A copy of the body (StandIn) takes it
## out again: the copy's player plays on its own.
##
## The tree copies the player's own mixer settings. Its defaults differ
## where it matters (a tree is deterministic and forces discrete tracks to
## be continuous), and either would change how clips blend.

const NODE_NAME: StringName = &"BodyAnimationTree"

## The clip that started last and is still playing, or "" when nothing
## plays: AnimationPlayer.current_animation.
var current_animation: StringName:
	get:
		return _playback.assigned if _playback.playing else &""
## The clip last started, playing or not: AnimationPlayer.assigned_animation.
var assigned_animation: StringName:
	get:
		return _playback.assigned
## How far into the current clip, in seconds.
var current_animation_position: float:
	get:
		return _playback.current.pos if _playback.current else 0.0
## The current clip's length, in seconds.
var current_animation_length: float:
	get:
		return _playback.current.animation.length if _playback.current else 0.0

var _player: AnimationPlayer = null
var _playback: ClipPlayback = ClipPlayback.new()
var _physics: bool = false


## Puts a tree beside `player` and makes it what shows the body's clips.
## The player is left holding them and stops playing. Returns the tree
## already there when there is one.
static func attach(player: AnimationPlayer) -> BodyAnimationTree:
	var parent: Node = player.get_parent()
	var there := parent.get_node_or_null(NodePath(NODE_NAME)) as BodyAnimationTree
	if there:
		return there
	var tree := BodyAnimationTree.new()
	tree.name = NODE_NAME
	tree._player = player
	tree.anim_player = NodePath("../" + String(player.name))
	tree.deterministic = player.deterministic
	tree.callback_mode_discrete = player.callback_mode_discrete
	tree.callback_mode_method = player.callback_mode_method
	tree.root_motion_track = player.root_motion_track
	tree.audio_max_polyphony = player.audio_max_polyphony
	tree._physics = player.callback_mode_process == AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS
	tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	tree.tree_root = tree._playback
	tree._playback.finished.connect(tree._on_finished)
	player.pause()
	player.active = false
	player.add_sibling(tree)
	return tree


## The tree showing a body's clips, or null for a body that has none.
static func of(body: Node) -> BodyAnimationTree:
	if body == null:
		return null
	for found in body.find_children(String(NODE_NAME), "AnimationTree", true, false):
		if found is BodyAnimationTree:
			return found
	return null


## The tree's clip names are the player's, so so are its questions.
func is_playing() -> bool:
	return _playback.playing


## AnimationPlayer.play(): crossfades from what is showing over
## `custom_blend` seconds (-1 is the player's default and blend times),
## at `custom_speed`.
func play(clip: StringName, custom_blend: float = -1.0, custom_speed: float = 1.0) -> void:
	var animation: Animation = get_animation(clip)
	if animation == null:
		push_error("BodyAnimationTree: animation not found: %s." % clip)
		return
	if custom_blend < 0.0 and _playback.current and _player:
		var table: float = _blend_time(_playback.assigned, clip)
		if table > 0.0:
			custom_blend = table
	_sync_player_settings()
	_playback.play(clip, animation, custom_blend, custom_speed)
	animation_started.emit(clip)


## AnimationPlayer.seek(): with `update`, shows the pose now rather than at
## the next advance.
func seek(seconds: float, update: bool = false) -> void:
	if _playback.current == null:
		return
	if _playback.just_started():
		_advance(0.0)
	_playback.seek(seconds)
	if update:
		_advance(0.0)
		_playback.clear_seek()


## AnimationPlayer.pause(): stops where it is and leaves the pose.
func pause() -> void:
	_playback.pause()


func _process(delta: float) -> void:
	if not _physics and _playback.playing:
		_advance(delta)


func _physics_process(delta: float) -> void:
	if _physics and _playback.playing:
		_advance(delta)


func _advance(delta: float) -> void:
	if not is_inside_tree():
		return
	_sync_player_settings()
	advance(delta)
	_playback.post_process()


## Speed and the default crossfade stay the player's, so whatever sets them
## on the player still has its say.
func _sync_player_settings() -> void:
	if is_instance_valid(_player):
		_playback.speed_scale = _player.speed_scale
		_playback.default_blend_time = _player.playback_default_blend_time


## A blend time the player's own table gives for this pair, the way it
## looks one up: from-to, any-to, from-any.
func _blend_time(from: StringName, to: StringName) -> float:
	for pair: Array in [[from, to], [&"*", to], [from, &"*"]]:
		var seconds: float = _player.get_blend_time(pair[0], pair[1])
		if seconds > 0.0:
			return seconds
	return 0.0


func _on_finished(clip: StringName) -> void:
	animation_finished.emit(clip)
