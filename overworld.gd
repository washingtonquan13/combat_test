extends Node3D
## Generic overworld shell — spawns the controllable avatar at whichever
## named SpawnPoints child matches the requested spawn point (falling
## back to Start), aims the follow camera at it, and answers WorldManager's
## duck-typed world contract. Every overworld instance shares this exact
## script; what makes one overworld different from another is entirely in
## its own authored scene (its Geometry, and which doors sit in its own
## SpawnPoints) — see overworld_door.gd for how a door itself decides
## where "in" leads. This is what makes more than one overworld possible
## at all: nothing here is specific to any one maze.
##
## Was a runtime maze generator (a LAYOUT text grid, walls/floor/door all
## built in _ready()) until the data-driven-areas pass baked that output
## into this scene's own authored nodes instead — see git history on this
## file for the generator this replaced.

const AVATAR_SCENE: PackedScene = preload("res://overworld_avatar.tscn")

@onready var _camera: OverworldCamera = $OverworldCamera
@onready var _spawn_points: Node3D = $SpawnPoints

var _avatar: OverworldAvatar


func _ready() -> void:
	_spawn_avatar()
	_camera.target = _avatar
	_camera.snap_to_target()


func get_base_mode() -> GameMode.Mode:
	return GameMode.Mode.OVERWORLD


## Duck-typed — see WorldManager.load_world()'s own header. The overworld
## holds one avatar, not a spawned tactical party; PartyManager.roster
## stays untouched either way, only whether it gets projected into live
## Units for THIS world varies.
func spawns_party() -> bool:
	return false


func get_tactical_camera() -> Camera3D:
	return _camera


## Falls back to the Start marker on an unknown/empty name — same
## "missing spawn point degrades gracefully" contract every world
## answering this duck-typed method follows.
func get_spawn_point(spawn_point_name: StringName) -> Node3D:
	var point := _spawn_points.find_child(String(spawn_point_name), true, false) as Node3D
	return point if point else _spawn_points.find_child("Start", true, false) as Node3D


func _spawn_avatar() -> void:
	_avatar = AVATAR_SCENE.instantiate()
	add_child(_avatar)
	_avatar.camera = _camera

	var spawn_point: Node3D = get_spawn_point(WorldManager.pending_spawn_point_name())
	_avatar.global_position = spawn_point.global_position

	# Landing directly on top of a door needs it unprimed, or its own
	# collider overlapping the avatar the instant it spawns would fire
	# body_entered again and bounce straight back — see overworld_door.gd.
	if spawn_point is OverworldDoor:
		spawn_point.set_primed(false)
