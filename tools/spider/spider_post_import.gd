@tool
extends EditorScenePostImport
## Tidies the Quaternius spider's shipped clips on import: plain names the
## unit can use, Idle and Walk looping, a default cross-fade, the bite's
## moment keyed where the head lunges home (glTF has no method tracks), Walk
## brought up to the speed units really move, the Downed pair made from
## Death (Knockdown is a copy, Get_Up is Death backwards), and Jump cut in
## three so a flight can last as long as it must. The push-off from a wall is
## built from Jump's own poses, so the legs stay on the body they were baked
## for.

const DEFAULT_BLEND: float = 0.15
const LOOPING: Array[String] = ["Idle", "Walk"]
## Frame 10 of 24 per second: the lunge reaches its furthest point.
const ATTACK_IMPACT: float = 10.0 / 24.0
## As shipped the feet plant at about 1.3 m/s at this body's size, and a unit
## moves at 4. Three times over keeps them from skating.
const WALK_SPEED: float = 3.0

## How finely a clip built here is keyed.
const SAMPLE_STEP: float = 1.0 / 60.0
## Where the shipped Jump does things, in seconds: lowest in its crouch, the
## thrust begun, the feet off the ground, in the air, about to touch down.
const JUMP_CROUCH: float = 0.25
const JUMP_THRUST: float = 0.29
const JUMP_OFF: float = 0.33
const JUMP_AIR_FROM: float = 0.375
const JUMP_AIR_TO: float = 0.458
const JUMP_LAND: float = 0.52
## The air part, slowed: it plays out in the first moments of a flight, then
## holds its last pose.
const JUMP_AIR_SPEED: float = 1.0 / 3.0
## The push-off: pressed in against the wall, then the kick.
const WALL_COIL: float = 0.34
const WALL_KICK: float = 0.1
const WALL_END: float = 0.5
## How much deeper than the shipped crouch it presses in.
const WALL_PRESS: float = 1.35
## How much more than the shipped leap the body peels away, head first.
const WALL_PEEL: float = 1.6
## The rear legs leave the wall last, by this many seconds.
const KICK_DELAY: Dictionary[String, float] = {"MidFront": 0.012, "MidBack": 0.025, "Back": 0.04}


func _post_import(scene: Node) -> Object:
	var players: Array[Node] = scene.find_children("*", "AnimationPlayer", true, false)
	if players.is_empty():
		push_error("spider_post_import: no AnimationPlayer")
		return scene
	var player: AnimationPlayer = players[0]
	player.playback_default_blend_time = DEFAULT_BLEND
	var library: AnimationLibrary = player.get_animation_library(&"")
	for from: StringName in library.get_animation_list():
		var to: String = String(from).get_slice("Spider_", 1)
		if to != "" and to != String(from):
			library.rename_animation(from, StringName(to))
	for clip: String in LOOPING:
		player.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
	_remap_times(player.get_animation("Walk"), WALK_SPEED, false)
	library.add_animation(&"Knockdown", player.get_animation("Death").duplicate(true))
	var get_up: Animation = player.get_animation("Death").duplicate(true)
	_remap_times(get_up, 1.0, true)
	library.add_animation(&"Get_Up", get_up)
	_mark_impact(player.get_animation("Attack"), ATTACK_IMPACT)
	var jump: Animation = player.get_animation("Jump")
	var take_off: Animation = _cut(jump, 0.0, JUMP_OFF)
	_mark_impact(take_off, JUMP_THRUST)
	library.add_animation(&"Jump_Start", take_off)
	var air: Animation = _cut(jump, JUMP_AIR_FROM, JUMP_AIR_TO)
	_remap_times(air, JUMP_AIR_SPEED, false)
	library.add_animation(&"Jump_Air", air)
	library.add_animation(&"Jump_Land", _cut(jump, JUMP_LAND, jump.length))
	var push_off: Animation = _push_off(jump)
	_mark_impact(push_off, WALL_COIL + 0.02)
	library.add_animation(&"Jump_Wall_Start", push_off)
	return scene


## The moment the action lands, keyed for CharacterModel: glTF has no method
## tracks.
func _mark_impact(anim: Animation, time: float) -> void:
	var track: int = anim.add_track(Animation.TYPE_METHOD)
	anim.track_set_path(track, NodePath(".."))
	anim.track_insert_key(track, time, {"method": &"impact", "args": []})


## The stretch of source between two times, as a clip of its own.
func _cut(source: Animation, from: float, to: float) -> Animation:
	var clip: Animation = source.duplicate(true)
	clip.loop_mode = Animation.LOOP_NONE
	for track: int in clip.get_track_count():
		_clear(clip, track)
		var time: float = from
		while true:
			clip.track_insert_key(track, time - from, _sampled(source, track, time))
			if time >= to:
				break
			time = minf(time + SAMPLE_STEP, to)
	clip.length = to - from
	return clip


## Launching off a wall. CrawlPose has already turned the model so its up is
## the wall's normal, so a crouch presses into the wall and Jump's thrust
## pushes out of it: the same poses, a deeper press held a little longer, and
## a sharper kick with the head peeling away first.
func _push_off(jump: Animation) -> Animation:
	var clip: Animation = jump.duplicate(true)
	clip.loop_mode = Animation.LOOP_NONE
	clip.length = WALL_END
	for track: int in clip.get_track_count():
		_clear(clip, track)
		var bone: String = clip.track_get_path(track).get_subname(0)
		var rest: Variant = _sampled(jump, track, 0.0)
		var pressed: Variant = _weighted(rest, _sampled(jump, track, JUMP_CROUCH), WALL_PRESS)
		var kicked: Variant = _sampled(jump, track, JUMP_AIR_TO)
		if bone == "Body" and clip.track_get_type(track) == Animation.TYPE_ROTATION_3D:
			kicked = _weighted(rest, kicked, WALL_PEEL)
		var delay: float = _kick_delay(bone)
		var time: float = 0.0
		while true:
			var value: Variant
			if time < WALL_COIL:
				value = _weighted(rest, pressed, smoothstep(0.0, WALL_COIL, time))
			else:
				var kick: float = clampf((time - WALL_COIL - delay) / WALL_KICK, 0.0, 1.0)
				value = _weighted(pressed, kicked, ease(kick, 0.5))
			clip.track_insert_key(track, time, value)
			if time >= WALL_END:
				break
			time = minf(time + SAMPLE_STEP, WALL_END)
	return clip


func _kick_delay(bone: String) -> float:
	for part: String in KICK_DELAY:
		if bone.begins_with(part):
			return KICK_DELAY[part]
	return 0.0


func _clear(anim: Animation, track: int) -> void:
	while anim.track_get_key_count(track) > 0:
		anim.track_remove_key(track, 0)


func _sampled(anim: Animation, track: int, time: float) -> Variant:
	match anim.track_get_type(track):
		Animation.TYPE_POSITION_3D:
			return anim.position_track_interpolate(track, time)
		Animation.TYPE_ROTATION_3D:
			return anim.rotation_track_interpolate(track, time)
	return anim.scale_track_interpolate(track, time)


## a toward b, past b when weight is over 1.
func _weighted(a: Variant, b: Variant, weight: float) -> Variant:
	if a is Quaternion:
		return (a as Quaternion).slerp(b, weight).normalized()
	return (a as Vector3).lerp(b, weight)


## Rewrites every key's time: divided by speed, or mirrored to play backwards.
func _remap_times(anim: Animation, speed: float, backwards: bool) -> void:
	var length: float = anim.length
	for track: int in anim.get_track_count():
		var keys: Array = []
		for key: int in anim.track_get_key_count(track):
			keys.append([anim.track_get_key_time(track, key), anim.track_get_key_value(track, key)])
		while anim.track_get_key_count(track) > 0:
			anim.track_remove_key(track, 0)
		for key: Array in keys:
			var time: float = length - key[0] if backwards else key[0] / speed
			anim.track_insert_key(track, time, key[1])
	anim.length = length / speed
