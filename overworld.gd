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

## One avatar per group standing here, by group. The overworld is a
## VIEW of PartyManager.groups rather than the owner of an avatar —
## which is what lets a split party be in two places on it instead of
## being collected on arrival.
var _avatars: Dictionary = {}


func _ready() -> void:
	# Re-synced on focus too, not only here: this world stays resident
	# while a group is standing in it, so coming back does not rebuild it
	# and _ready does not run again.
	WorldManager.world_focused.connect(_on_world_focused)
	sync_avatars()
	_camera.snap_to_target()


func _on_world_focused(world: Node) -> void:
	if world == self:
		sync_avatars()


func get_base_mode() -> GameMode.Mode:
	return GameMode.Mode.OVERWORLD


## Duck-typed — see WorldManager.load_world()'s own header. The overworld
## holds one avatar, not a spawned tactical party; PartyManager.roster
## stays untouched either way, only whether it gets projected into live
## Units for THIS world varies.
func spawns_party() -> bool:
	return false



## Rebuilds the avatars from PartyManager.groups: one per group standing
## in this overworld, the active one driveable and followed by the
## camera, the rest standing where they were left.
##
## Idempotent, and called on every focus — a group can arrive or leave
## while this world stays resident, and there is no signal for "the
## groups changed" worth adding when re-deriving is this cheap.
func sync_avatars() -> void:
	var area: AreaDefinition = WorldManager.area_of(self)
	var here: Array[PartyGroup] = []
	if area:
		here = PartyManager.groups_in_area(area.id)

	for group in _avatars.keys().duplicate():
		if group in here and not group.embodied:
			continue
		# Left, or was embodied somewhere else: its avatar is not standing
		# here any more.
		var stale: Node = _avatars[group]
		_avatars.erase(group)
		if is_instance_valid(stale):
			stale.queue_free()

	for group in here:
		if group.embodied:
			continue
		if not _avatars.has(group) or not is_instance_valid(_avatars[group]):
			_avatars[group] = _make_avatar(group)

	var active: OverworldAvatar = null
	for group in _avatars:
		var avatar: OverworldAvatar = _avatars[group]
		avatar.active = group == PartyManager.active_group
		if avatar.active:
			active = avatar

	# Snapped, not lerped, when the group being commanded changes: the
	# camera is jumping to different people somewhere else on the map, and
	# sliding across the whole overworld to get there reads as a glitch
	# rather than as a move.
	# Groups standing around are scenery to each other, not obstacles.
	# Without this, walking the active group past the one waiting on the
	# overworld means shoving it across the map.
	var bodies: Array = _avatars.values()
	for i in bodies.size():
		for j in range(i + 1, bodies.size()):
			if is_instance_valid(bodies[i]) and is_instance_valid(bodies[j]):
				bodies[i].add_collision_exception_with(bodies[j])

	if active and _camera.target != active:
		_camera.target = active
		_camera.snap_to_target()


## Null when no group here is the active one — which happens the
## instant before sync_avatars runs, and while the player is commanding
## a group in some other world entirely.
func _active_avatar() -> OverworldAvatar:
	for group in _avatars:
		if group == PartyManager.active_group and is_instance_valid(_avatars[group]):
			return _avatars[group]
	return null


## A group with no remembered position has just walked in, so it lands
## at whichever door this load resolved to. One that has been here
## before stands where it was left.
func _make_avatar(group: PartyGroup) -> OverworldAvatar:
	var avatar: OverworldAvatar = AVATAR_SCENE.instantiate()
	avatar.group = group
	add_child(avatar)
	avatar.camera = _camera

	if group.overworld_position == Vector3.ZERO:
		var spawn_point: Node3D = get_spawn_point(WorldManager.pending_spawn_point_name())
		if spawn_point:
			group.overworld_position = spawn_point.global_position
	avatar.global_position = group.overworld_position
	return avatar
