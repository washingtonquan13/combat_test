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
##
## LAYERS. A humanoid body shows two clips at once and a hit on top:
##   BODY   the whole body, as above. Always showing something.
##   UPPER  the body from the Spine up (spine, arms, head), over the legs of
##          the BODY clip: a bow drawn over a run. play_upper() fades it in,
##          stop_upper() out, and a clip that does not loop fades out by
##          itself when it ends (upper_finished). It carries the clip's
##          method track too, so a release key in it still fires.
##   FLINCH a hit clip's recoil added to whatever shows (BodyFlinch), so a
##          blow lands without stopping the walk or the cast.
## A change of BODY clip is no crossfade: the new clip shows alone at once
## and the old pose's offset from it dies away on top (BodyInertia), over
## the blend time the play asked for. UPPER still fades in and out by its
## weight.
## The root is then a blend: BODY into a Blend2 whose filter is the upper
## body, with UPPER on its other input. At weight 0 the blend passes BODY
## through untouched, so a body nobody layers shows exactly what it showed
## with one clip. A body without that bone (a dragon, a spider) gets no
## blend at all: its root is the BODY playback alone, and play_upper() says
## no.

const NODE_NAME: StringName = &"BodyAnimationTree"
## The bone the upper body starts at, in Godot's humanoid profile.
const UPPER_BODY_BONE: StringName = &"Spine"
## What a clip is asked to play on. FLINCH is the BodyFlinch beside it.
enum Layer { BODY, UPPER, FLINCH }

## An UPPER clip that does not loop reached its end; the layer is fading out.
signal upper_finished(clip: StringName)

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

## The clip the upper body is showing, or "" when the layer is down or
## going down.
var upper_animation: StringName:
	get:
		return _upper.assigned if _upper and _upper_target > 0.0 else &""

var _player: AnimationPlayer = null
var _playback: ClipPlayback = ClipPlayback.new()
var _physics: bool = false
var _upper: ClipPlayback = null
## Bone names from the upper body bone up; empty for a body with no layer.
var _upper_bones: Dictionary = {}
var _upper_weight: float = 0.0
var _upper_target: float = 0.0
## Weight per second the layer moves toward its target at; 0 is at once.
var _upper_rate: float = 0.0
## The fade out a non-looping UPPER clip takes when it ends.
var _upper_out: float = 0.0
var _flinch: BodyFlinch = null
var _inertia: BodyInertia = null


## Puts a tree beside `player` and makes it what shows the body's clips.
## The player is left holding them and stops playing. Returns the tree
## already there when there is one. A body whose skeleton has
## `upper_body_bone` gets an UPPER layer from that bone up.
static func attach(player: AnimationPlayer, upper_body_bone: StringName = UPPER_BODY_BONE) -> BodyAnimationTree:
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
	var skeleton: Skeleton3D = _skeleton_under(parent)
	tree._upper_bones = _bones_from(skeleton, upper_body_bone)
	tree.tree_root = tree._layered() if not tree._upper_bones.is_empty() else tree._playback
	tree._playback.finished.connect(tree._on_finished)
	if skeleton:
		tree._flinch = BodyFlinch.attach(skeleton)
		tree._inertia = BodyInertia.attach(skeleton)
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


## Whether this body has an upper body to layer on.
func has_upper() -> bool:
	return _upper != null


## Plays `clip` on the upper body, over the legs of whatever BODY shows,
## fading the layer in over `blend` seconds (from an upper clip already up,
## crossfading). False when the body has no upper layer or no such clip.
func play_upper(clip: StringName, blend: float = 0.0) -> bool:
	if _upper == null:
		return false
	var animation: Animation = get_animation(clip)
	if animation == null:
		push_error("BodyAnimationTree: animation not found: %s." % clip)
		return false
	_mask(animation)
	blend = maxf(blend, 0.0)
	# Rising from nothing there is nothing to crossfade from: the layer's
	# own weight is the fade.
	var rising: bool = is_zero_approx(_upper_weight)
	if rising:
		_upper.stop()
	_upper.speed_scale = _playback.speed_scale
	_upper.play(clip, animation, 0.0 if rising else blend, 1.0)
	_upper_out = blend
	_fade_upper(1.0, blend)
	return true


## Lowers the upper body back onto the BODY clip over `blend` seconds.
func stop_upper(blend: float = 0.0) -> void:
	if _upper == null or (_upper_target == 0.0 and _upper_weight == 0.0):
		return
	_fade_upper(0.0, maxf(blend, 0.0))


## Adds the recoil of `clip` to whatever the body shows (see BodyFlinch).
## A body with an upper layer recoils there only, so the legs keep going.
func flinch(clip: StringName) -> bool:
	var animation: Animation = get_animation(clip)
	if _flinch == null or animation == null:
		return false
	_flinch.flinch(animation, _upper_bones)
	return _flinch.is_flinching()


func is_flinching() -> bool:
	return _flinch != null and _flinch.is_flinching()


## The BodyInertia carrying this body from clip to clip, null without a
## skeleton. Off, BODY clips crossfade as the player's did.
func inertia() -> BodyInertia:
	return _inertia


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
	var blend: float = custom_blend if custom_blend >= 0.0 else _playback.default_blend_time
	var current: ClipPlayback.Track = _playback.current
	if (_inertia and _inertia.enabled and blend > 0.0 and current
			and not (_playback.assigned == clip and _playback.playing)):
		_inertia.capture(blend, current.animation, current.pos,
			_playback.speed_scale * current.speed_scale if _playback.playing else 0.0)
		custom_blend = 0.0
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


## The playing clip's own speed, changed as it plays (a loop sped or slowed
## to fit the ground it must cover: UnitLocomotion).
func set_clip_speed(scale: float) -> void:
	if _playback.current:
		_playback.current.speed_scale = scale


## AnimationPlayer.pause(): stops where it is and leaves the pose.
func pause() -> void:
	_playback.pause()


func _process(delta: float) -> void:
	if not _physics and _changing():
		_advance(delta)


func _physics_process(delta: float) -> void:
	if _physics and _changing():
		_advance(delta)


## Whether anything shown still changes. With nothing layered this is the
## player's own rule: it processes while its clip plays.
func _changing() -> bool:
	return _playback.playing or (_upper != null
		and (_upper.playing or _upper_weight != _upper_target))


func _advance(delta: float) -> void:
	if not is_inside_tree():
		return
	_sync_player_settings()
	if _upper:
		_step_upper(delta)
	advance(delta)
	_playback.post_process()
	if _upper:
		_upper.post_process()
		if _upper_weight == 0.0 and _upper_target == 0.0:
			_upper.stop()


## Moves the layer's weight toward its target, as far as `delta` goes.
func _step_upper(delta: float) -> void:
	if _upper_weight != _upper_target:
		var step: float = _upper_rate * absf(_playback.speed_scale * delta) if _upper_rate > 0.0 else 1.0
		_upper_weight = move_toward(_upper_weight, _upper_target, step)
	set(&"parameters/upper_body/blend_amount", _upper_weight)


func _fade_upper(target: float, seconds: float) -> void:
	_upper_target = target
	_upper_rate = 1.0 / seconds if seconds > 0.0 else 0.0
	if _inertia:
		_inertia.applied()
	if seconds <= 0.0:
		_upper_weight = target


## BODY into a Blend2 masked to the upper body, UPPER on its other input.
func _layered() -> AnimationNodeBlendTree:
	_upper = ClipPlayback.new()
	_upper.finished.connect(_on_upper_finished)
	var blend := AnimationNodeBlend2.new()
	blend.filter_enabled = true
	# The method track: a release key in the upper clip fires.
	blend.set_filter_path(NodePath(".."), true)
	var root := AnimationNodeBlendTree.new()
	root.add_node(&"body", _playback)
	root.add_node(&"upper", _upper)
	root.add_node(&"upper_body", blend)
	root.connect_node(&"upper_body", 0, &"body")
	root.connect_node(&"upper_body", 1, &"upper")
	root.connect_node(&"output", 0, &"upper_body")
	return root


## The filter names track paths, and only the upper clip's matter: a bone it
## does not key is left wholly to BODY, filtered or not. So each clip's
## upper-body tracks join the filter the first time it plays up there.
func _mask(animation: Animation) -> void:
	var blend := (tree_root as AnimationNodeBlendTree).get_node(&"upper_body") as AnimationNodeBlend2
	for track in animation.get_track_count():
		var path: NodePath = animation.track_get_path(track)
		if _upper_bones.has(StringName(path.get_concatenated_subnames())):
			blend.set_filter_path(path, true)


static func _skeleton_under(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for found in node.find_children("*", "Skeleton3D", true, false):
		return found
	return null


## `from` and every bone under it, by name; empty when there is no `from`.
static func _bones_from(skeleton: Skeleton3D, from: StringName) -> Dictionary:
	var bones := {}
	var top: int = skeleton.find_bone(from) if skeleton and from != &"" else -1
	if top == -1:
		return bones
	var reach: Array[int] = [top]
	while not reach.is_empty():
		var bone: int = reach.pop_back()
		bones[StringName(skeleton.get_bone_name(bone))] = true
		reach.append_array(Array(skeleton.get_bone_children(bone)))
	return bones


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


func _on_upper_finished(clip: StringName) -> void:
	_fade_upper(0.0, _upper_out)
	upper_finished.emit(clip)
