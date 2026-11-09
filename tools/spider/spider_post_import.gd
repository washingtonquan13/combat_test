@tool
extends EditorScenePostImport
## Tidies the Quaternius spider's shipped clips on import: plain names the
## unit can use, Idle and Walk looping, a default cross-fade, the bite's
## moment keyed where the head lunges home (glTF has no method tracks), Walk
## brought up to the speed units really move, and the Downed pair made from
## Death: Knockdown is a copy, Get_Up is Death backwards.

const DEFAULT_BLEND: float = 0.15
const LOOPING: Array[String] = ["Idle", "Walk"]
## Frame 10 of 24 per second: the lunge reaches its furthest point.
const ATTACK_IMPACT: float = 10.0 / 24.0
## As shipped the feet plant at about 1.3 m/s at this body's size, and a unit
## moves at 4. Three times over keeps them from skating.
const WALK_SPEED: float = 3.0


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
	var attack: Animation = player.get_animation("Attack")
	var track: int = attack.add_track(Animation.TYPE_METHOD)
	attack.track_set_path(track, NodePath(".."))
	attack.track_insert_key(track, ATTACK_IMPACT, {"method": &"impact", "args": []})
	return scene


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
