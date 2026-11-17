class_name ClipPlayback
extends AnimationRootNode
## One clip at a time, crossfaded from the ones before it: what an
## AnimationPlayer does, as a node an AnimationTree can hold.
##
## WHY THIS EXISTS. A body's clips used to be played by its AnimationPlayer,
## and an AnimationPlayer can only ever show one thing. Layering (a bow drawn
## over a run) needs an AnimationTree. But none of the tree's own nodes plays
## "any clip, crossfaded over any time, from wherever the last fade had got
## to": a state machine fades between two states at a time with its own
## rules, so moving onto it would change how every interrupted crossfade
## looks. This node is the player's own playback, line for line, so moving
## a body onto a tree changes nothing that can be seen.
##
## THE PLAYER, LINE FOR LINE. The state and the arithmetic below are Godot
## 4.4's AnimationPlayer::play_section, _process_playback_data,
## _blend_playback_data and _blend_post_process: one current clip and a list
## of fading-out ones, each with blend_left; the current one weighs whatever
## the fades leave; a finished clip snaps to its end and drops every fade.
## The weights go to the same mixer through blend_animation, so the pose is
## the same sum the player made. Not carried over because no body uses it:
## queue(), play sections, auto-capture, and an animation's `next`.
##
## WHO ADVANCES IT. BodyAnimationTree, by hand, only while something plays,
## exactly when the player would have processed. A tree left to process
## itself would go on applying a finished clip every frame, where the player
## stops and leaves the pose alone.

## The clip played, and where in it: the player's PlaybackData.
class Track:
	var clip: StringName = &""
	var animation: Animation = null
	var pos: float = 0.0
	var speed_scale: float = 1.0

	func copy() -> Track:
		var twin := Track.new()
		twin.clip = clip
		twin.animation = animation
		twin.pos = pos
		twin.speed_scale = speed_scale
		return twin


## A clip on its way out: the player's Blend.
class Fade:
	var track: Track = null
	var blend_left: float = 0.0
	var blend_time: float = 0.0


const CMP_EPSILON := 0.00001

## Emitted after the pose is applied, as the player's animation_finished is.
signal finished(clip: StringName)

## Every clip's speed, as AnimationPlayer.speed_scale.
var speed_scale: float = 1.0
## The crossfade when a play asks for the default, as
## AnimationPlayer.playback_default_blend_time.
var default_blend_time: float = 0.0

var current: Track = null
var assigned: StringName = &""
var playing: bool = false
var _fades: Array[Fade] = []
var _started: bool = false
var _seeked: bool = false
var _internal_seeked: bool = false
var _end_reached: bool = false
var _end_notify: bool = false
var _processed_from: Animation = null
## A second loop shown under the current one, in step with it (a walk
## under a run as the run slows: UnitLocomotion). It weighs `partner_weight`
## of what the current one weighs, and stands where `partner_sync` (the
## current clip's position in, the partner's out) puts it after the current
## one has moved, so the two never drift apart. Not in the player: our own.
## A play of another clip drops it.
var partner: Track = null
var partner_weight: float = 0.0
var partner_sync: Callable = Callable()


## Shows `clip` under the current one at `weight` (0-1), placed by `sync`.
func set_partner(clip: StringName, animation: Animation, weight: float, sync: Callable) -> void:
	if partner == null or partner.clip != clip:
		partner = Track.new()
		partner.clip = clip
		partner.animation = animation
	partner_weight = clampf(weight, 0.0, 1.0)
	partner_sync = sync
	if current != null and sync.is_valid():
		partner.pos = sync.call(current.pos)


func clear_partner() -> void:
	partner = null
	partner_weight = 0.0
	partner_sync = Callable()


## Plays `clip` (an Animation the tree has under that name), crossfading
## from what is showing over `custom_blend` seconds, or the default when
## negative. Playing the clip already playing changes nothing, as the
## player's play() does not.
func play(clip: StringName, animation: Animation, custom_blend: float = -1.0, custom_scale: float = 1.0) -> void:
	if current != null:
		var blend_time: float = maxf(custom_blend, 0.0)
		if _less(custom_blend, 0.0) and is_zero_approx(blend_time) and default_blend_time != 0.0:
			blend_time = default_blend_time
		if blend_time > 0.0 and not is_zero_approx(blend_time):
			var fade := Fade.new()
			fade.track = current.copy()
			fade.blend_left = current_blend_amount()
			fade.blend_time = blend_time
			_fades.append(fade)
		else:
			_fades.clear()
	if assigned != clip:
		clear_partner()
	var resumed: Track = current
	current = Track.new() if resumed == null else resumed
	current.clip = clip
	current.animation = animation
	current.speed_scale = custom_scale
	if assigned != clip:
		current.pos = 0.0
		assigned = clip
	elif is_equal_approx(current.pos, animation.length):
		_seek_internal(0.0, true)
	elif playing:
		return
	_seeked = false
	_started = true
	playing = true


## Moves the current clip to `time`, as AnimationPlayer.seek(). The pose is
## shown at once only when `update` says so; the caller does that, since
## only the tree can apply a pose.
func seek(time: float) -> void:
	_seek_internal(time, false)


func _seek_internal(time: float, internal: bool) -> void:
	if current == null:
		return
	current.pos = time
	_seeked = true
	_internal_seeked = internal


## How much the current clip weighs while older ones fade out.
func current_blend_amount() -> float:
	var blend := 1.0
	for fade in _fades:
		blend -= fade.blend_left
	return maxf(0.0, blend)


## Done after a seek the caller has already shown, so the next advance
## does not treat it as a seek again.
func clear_seek() -> void:
	_seeked = false


## Whether the next advance must first apply the start of a clip just
## played, as the player's _check_immediately_after_start.
func just_started() -> bool:
	return _started


## Stops advancing and leaves the pose where it is, as AnimationPlayer.pause().
func pause() -> void:
	playing = false


## Shows nothing at all from here on, as AnimationPlayer.stop() with nothing
## assigned. Only a layer is ever stopped: a body's base always shows a clip.
func stop() -> void:
	current = null
	assigned = &""
	playing = false
	clear_partner()
	_fades.clear()
	_started = false
	_seeked = false


func _process(time: float, seek_request: bool, _is_external_seeking: bool, test_only: bool) -> float:
	if test_only or current == null or current.animation == null:
		return 0.0
	# Not seeking, the tree hands the root its delta as `time`. A paused clip
	# is still applied, where it stands: the tree runs while another layer
	# plays, and this one must keep its pose without moving on.
	var delta: float = 0.0 if seek_request or not playing else time
	_processed_from = current.animation
	_end_reached = false
	_end_notify = false
	var started: bool = _started
	_started = false

	var seeked: bool = _seeked
	var internal_seeked: bool = _internal_seeked
	if not is_zero_approx(delta):
		_seeked = false
		_internal_seeked = false
	var weight: float = current_blend_amount()
	var under: float = partner_weight if partner != null and not _end_reached else 0.0
	_blend_track(current, delta, weight * (1.0 - under), seeked, internal_seeked, started, true)
	if under > 0.0 and not _end_reached:
		if partner_sync.is_valid():
			partner.pos = partner_sync.call(current.pos)
		blend_animation(partner.clip, partner.pos, 0.0, true, false, weight * under,
			Animation.LOOPED_FLAG_NONE)
	if _end_reached:
		_fades.clear()
		return 0.0
	var gone: Array[Fade] = []
	for fade in _fades:
		fade.blend_left = maxf(0.0, fade.blend_left - absf(speed_scale * delta) / fade.blend_time)
		if fade.blend_left < 0.0 or is_equal_approx(fade.blend_left, 0.0):
			gone.append(fade)
			fade.blend_left = CMP_EPSILON
		_blend_track(fade.track, delta, fade.blend_left, false, false, false, false)
	for fade in gone:
		_fades.erase(fade)
	return 0.0


## After the pose is applied: a clip that reached its end stops and says
## so, unless something already played another in its place.
func post_process() -> void:
	if _end_reached and current != null and _processed_from == current.animation:
		playing = false
		if _end_notify:
			finished.emit(assigned)
	_end_reached = false
	_end_notify = false
	_processed_from = null


func _blend_track(track: Track, p_delta: float, blend: float, seeked: bool, internal_seeked: bool, started: bool, is_current: bool) -> void:
	var animation: Animation = track.animation
	var speed: float = speed_scale * track.speed_scale
	var backwards: bool = speed < 0.0
	var delta: float = 0.0 if started else p_delta * speed
	var next_pos: float = track.pos + delta
	var start := 0.0
	var end: float = animation.length
	var looped_flag: Animation.LoopedFlag = Animation.LOOPED_FLAG_NONE

	match animation.loop_mode:
		Animation.LOOP_NONE:
			if _less(next_pos, start):
				next_pos = start
			elif _greater(next_pos, end):
				next_pos = end
			delta = next_pos - track.pos
		Animation.LOOP_LINEAR:
			if _less(next_pos, start) and not _less(track.pos, start):
				looped_flag = Animation.LOOPED_FLAG_START
			if _greater(next_pos, end) and not _greater(track.pos, end):
				looped_flag = Animation.LOOPED_FLAG_END
			next_pos = fposmod(next_pos - start, end - start) + start
		Animation.LOOP_PINGPONG:
			if _less(next_pos, start) and not _less(track.pos, start):
				track.speed_scale *= -1.0
				looped_flag = Animation.LOOPED_FLAG_START
			if _greater(next_pos, end) and not _greater(track.pos, end):
				track.speed_scale *= -1.0
				looped_flag = Animation.LOOPED_FLAG_END
			next_pos = pingpong(next_pos - start, end - start) + start

	var prev_pos: float = track.pos
	if is_current and animation.loop_mode == Animation.LOOP_NONE:
		if not backwards and not _greater(prev_pos, end) and is_equal_approx(next_pos, end):
			next_pos = end
			_end_reached = true
			_end_notify = _less(prev_pos, end)
			blend = 1.0
		if backwards and not _less(prev_pos, start) and is_equal_approx(next_pos, start):
			next_pos = start
			_end_reached = true
			_end_notify = _greater(prev_pos, start)
			blend = 1.0
	track.pos = next_pos

	if started:
		blend_animation(track.clip, prev_pos, 0.0, true, false, blend, looped_flag)
	else:
		blend_animation(track.clip, next_pos, delta, seeked,
			not internal_seeked, blend, looped_flag)


## Animation::is_less_approx and is_greater_approx: strictly past, and not
## merely a rounding error away.
static func _less(a: float, b: float) -> bool:
	return a < b and not is_equal_approx(a, b)


static func _greater(a: float, b: float) -> bool:
	return a > b and not is_equal_approx(a, b)
