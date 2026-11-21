@tool
class_name Cutscene
extends DirectedScene
## A cutscene made by hand: one scene, one Timeline, everything keyed.
##
## The scene holds the people (CutsceneRole nodes with a body under each),
## plain Camera3D nodes, and an AnimationPlayer named "Timeline" whose
## animation "scene" is the performance. Roles are moved by keying their
## position and rotation, their clips are keys on an Animation Playback
## track, the live camera is a key on this node's `shot`, and a line is a
## Call Method key on say(). Scrubbing the Timeline in the editor shows
## the same keys the game plays.
##
## What this script adds to that, and all it adds:
##   - the role bodies are swapped for the real units' dressed bodies, the
##     units are hidden for the scene, and put where their body ended;
##   - `shot` cuts the game's camera;
##   - say() shows a line and holds the Timeline until the player advances;
##   - skip jumps to the last frame.
##
## Played with CinematicDirector.play(), like every other scene.

## The camera that is live. Key this on the Timeline (a property track,
## update mode Discrete) to cut. A path from this node to a Camera3D.
@export var shot: NodePath = NodePath(""):
	set(value):
		shot = value
		_show_shot()

@export_group("Where it plays")
## A role whose unit already stands in the world. The whole scene is put
## down so that role starts exactly where its unit stands, facing the way
## it faces. Empty: see anchor_mark.
@export var anchor: NodePath = NodePath("")
## A mark in the area (a Node3D in the "scene_marks" group, by name) the
## scene's origin is put on. Used when `anchor` is empty. With both empty
## the scene plays where it was authored, in world coordinates.
@export var anchor_mark: StringName = &""

@export_group("")
## Values a caller hands the scene through CinematicDirector.play().
@export var props: Dictionary = {}

var _bound: bool = false
var _waiting: bool = false
var _roles: Array = []
## Set by the director on a scene it puts into the world to act.
var acting: bool = false
## A cutscene sitting in an area keeps itself as it was authored, taken
## before its bodies set themselves up, to make each play's copy from.
var _authored: Cutscene = null


func _enter_tree() -> void:
	if not Engine.is_editor_hint() and not acting and _authored == null:
		_authored = duplicate() as Cutscene


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and is_instance_valid(_authored):
		_authored.free()


## A fresh copy of this scene as authored, for the director to play.
func acting_copy() -> Cutscene:
	var copy := (_authored if _authored else self).duplicate() as Cutscene
	if copy:
		copy.acting = true
	return copy


func _ready() -> void:
	# A cutscene sitting in an area is out of sight until it plays.
	if not Engine.is_editor_hint() and not _bound:
		visible = false


func bind(cast: SceneCast) -> void:
	visible = true
	_roles.clear()
	for found in find_children("*", "Node3D", true, false):
		if found is CutsceneRole:
			_roles.append(found)

	for role: CutsceneRole in _roles:
		role.find_unit(cast)
	_place()
	for role: CutsceneRole in _roles:
		if role.unit == null:
			role.spawn_unit()

	var timeline_root: Node = _timeline_root()
	# Which clip tracks play which role's body, read before the bodies are
	# swapped: afterwards the paths they were authored against are gone.
	var clip_tracks: Array = _clip_tracks(timeline_root)
	for role: CutsceneRole in _roles:
		role.dress()
	_retarget(clip_tracks, timeline_root)

	_bound = true
	_show_shot()


func unbind() -> void:
	_end_line()
	for role: CutsceneRole in _roles:
		if is_instance_valid(role):
			role.undress()
	_roles.clear()
	if _bound:
		CameraDirector.deactivate_cinematic_camera()
	_bound = false


func is_running() -> bool:
	var player: AnimationPlayer = timeline()
	return _waiting or (player != null and player.is_playing())


func is_waiting() -> bool:
	return _waiting


func advance() -> void:
	_end_line()


func skip_to_end() -> void:
	_end_line()
	var player: AnimationPlayer = timeline()
	if player == null or player.current_animation == "":
		return
	# seek() applies every property and clip track at that time and fires
	# no method keys, so no line opens on the way.
	player.seek(player.current_animation_length, true)


func commit_stand_ins() -> void:
	for role: CutsceneRole in _roles:
		if is_instance_valid(role):
			role.settle()


## A line. Key it on a Call Method track on this node at the moment it is
## spoken. `who` is the name of a role in this scene (shown as that unit's
## name) or any text to show as the speaker. The Timeline holds on this
## frame until the player advances.
func say(who: String, text: String) -> void:
	if Engine.is_editor_hint() or not _bound:
		return
	var player: AnimationPlayer = timeline()
	var overlay: CinematicOverlay = CinematicDirector.overlay()
	if player == null:
		return
	if overlay:
		overlay.show_line(_speaker(who), text)
	_waiting = true
	# Held by speed, not pause(): pausing a player from inside one of its
	# own method keys breaks it.
	player.speed_scale = 0.0


func _end_line() -> void:
	if not _waiting:
		return
	_waiting = false
	var overlay: CinematicOverlay = CinematicDirector.overlay()
	if overlay:
		overlay.clear_line()
	var player: AnimationPlayer = timeline()
	if player:
		player.speed_scale = 1.0


func _speaker(who: String) -> String:
	for role: CutsceneRole in _roles:
		if String(role.name) == who and role.unit:
			return role.unit.get_display_name()
	return who


func _show_shot() -> void:
	if not is_inside_tree() or shot.is_empty():
		return
	var live := get_node_or_null(shot) as Camera3D
	if live == null:
		return
	if Engine.is_editor_hint():
		# What the viewport's Cinematic Preview shows.
		live.make_current()
	elif _bound:
		CameraDirector.activate_cinematic_camera(live)


## Puts the whole scene down in the world: on the anchor role's unit, else
## on the anchor mark, else where it was authored.
func _place() -> void:
	var on: CutsceneRole = null
	if not anchor.is_empty():
		on = get_node_or_null(anchor) as CutsceneRole
	if on and on.unit:
		var stands: Transform3D = _upright(on.unit_body_transform())
		var authored: Transform3D = global_transform.affine_inverse() * on.body_transform()
		global_transform = stands * _upright(authored).affine_inverse()
		return
	if anchor_mark != &"":
		for mark in get_tree().get_nodes_in_group(SceneCast.MARK_GROUP):
			var spot := mark as Node3D
			if spot and spot.name == anchor_mark and spot.get_world_3d() == get_world_3d():
				global_transform = _upright(spot.global_transform)
				return
		push_warning("Cutscene '%s': no mark '%s' in this area." % [scene_file_path, anchor_mark])


## The same place, turned only about the vertical.
static func _upright(from: Transform3D) -> Transform3D:
	var ahead: Vector3 = from.basis.z
	ahead.y = 0.0
	if ahead.length_squared() < 0.0001:
		return Transform3D(Basis.IDENTITY, from.origin)
	return Transform3D(Basis(Vector3.UP, atan2(ahead.x, ahead.z)), from.origin)


func _timeline_root() -> Node:
	var player: AnimationPlayer = timeline()
	return player.get_node_or_null(player.root_node) if player else null


## [animation name, track index, role] for every Animation Playback track
## that plays a player inside a role's body.
func _clip_tracks(timeline_root: Node) -> Array:
	var found: Array = []
	var player: AnimationPlayer = timeline()
	if player == null or timeline_root == null:
		return found
	for clip_name in player.get_animation_list():
		var clip: Animation = player.get_animation(clip_name)
		for track in clip.get_track_count():
			if clip.track_get_type(track) != Animation.TYPE_ANIMATION:
				continue
			var plays: Node = timeline_root.get_node_or_null(clip.track_get_path(track))
			for role: CutsceneRole in _roles:
				if plays and role.body and role.body.is_ancestor_of(plays):
					found.append([clip_name, track, role])
	return found


## Points those tracks at the dressed bodies' own players. On copies: the
## animations in the scene file are shared by every play of it.
func _retarget(clip_tracks: Array, timeline_root: Node) -> void:
	var player: AnimationPlayer = timeline()
	if player == null or clip_tracks.is_empty():
		return
	for library_name in player.get_animation_library_list():
		var authored: AnimationLibrary = player.get_animation_library(library_name)
		var mine := AnimationLibrary.new()
		for clip_name in authored.get_animation_list():
			mine.add_animation(clip_name, authored.get_animation(clip_name).duplicate())
		player.remove_animation_library(library_name)
		player.add_animation_library(library_name, mine)
	for entry in clip_tracks:
		var role: CutsceneRole = entry[2]
		var plays: AnimationPlayer = role.body.resolve_animation_player() if role.body else null
		if plays:
			player.get_animation(entry[0]).track_set_path(entry[1], timeline_root.get_path_to(plays))
