extends GameArea
## Generic overworld shell — spawns the controllable avatar at whichever
## named SpawnPoints child matches the requested spawn point (falling
## back to Start), aims the follow camera at it. Every overworld instance
## shares this exact script; what makes one overworld different from
## another is entirely in its own authored scene (its Geometry, and which
## doors sit in its own SpawnPoints) — see overworld_door.gd for how a
## door itself decides where "in" leads. This is what makes more than one
## overworld possible at all: nothing here is specific to any one maze.
##
## Extends GameArea (see that file) rather than answering the world
## contract itself — get_spawn_point()'s inherited find_child()-then-
## "Start"-fallback behavior already matches what this file used to do by
## hand, so only the two ways an overworld genuinely differs from an
## ordinary area (get_base_mode(), spawns_party()) are overridden here.
##
## Was a runtime maze generator (a LAYOUT text grid, walls/floor/door all
## built in _ready()) until the data-driven-areas pass baked that output
## into this scene's own authored nodes instead — see git history on this
## file for the generator this replaced.

const AVATAR_SCENE: PackedScene = preload("res://overworld_avatar.tscn")

@onready var _camera: OverworldCamera = $OverworldCamera

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


## Read by SaveManager to restore the avatar's exact saved position
## after a load — the overworld has no "party" for PartyManager.members
## to index into (see spawns_party() above), so this is the one other
## place a saved position needs to land. Public rather than reaching
## into the private _avatar field from outside, same as this file's
## other duck-typed accessors (get_tactical_camera, get_spawn_point).
func get_avatar() -> OverworldAvatar:
	return _avatar


func _spawn_avatar() -> void:
	_avatar = AVATAR_SCENE.instantiate()
	add_child(_avatar)
	_avatar.camera = _camera

	var spawn_point: Node3D = get_spawn_point(WorldManager.pending_spawn_point_name())
	_avatar.global_position = spawn_point.global_position
