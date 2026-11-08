@tool
extends EditorScenePostImport
## Keys the dragon's release/impact moments into its clips on import.
##
## glTF has no method tracks, so export_dragon.py writes the moments beside
## the GLB (dragon_moments.json: clip -> method -> times in seconds), and
## this adds them back as a Call Method track on CharacterModel - the same
## track path ".." the humanoid libraries use (make_weapon_animations.gd).

const MOMENTS: String = "res://assets/dragon/dragon_moments.json"


func _post_import(scene: Node) -> Object:
	var moments = JSON.parse_string(FileAccess.get_file_as_string(MOMENTS))
	if not moments is Dictionary:
		push_error("dragon_post_import: can't read %s" % MOMENTS)
		return scene
	var players: Array[Node] = scene.find_children("*", "AnimationPlayer", true, false)
	if players.is_empty():
		push_error("dragon_post_import: no AnimationPlayer")
		return scene
	var player: AnimationPlayer = players[0]
	for clip: String in moments:
		if not player.has_animation(clip):
			push_error("dragon_post_import: no clip \"%s\"" % clip)
			continue
		var anim: Animation = player.get_animation(clip)
		var track: int = anim.add_track(Animation.TYPE_METHOD)
		anim.track_set_path(track, NodePath(".."))
		for method: String in moments[clip]:
			for time in moments[clip][method]:
				anim.track_insert_key(track, float(time), {"method": StringName(method), "args": []})
	return scene
