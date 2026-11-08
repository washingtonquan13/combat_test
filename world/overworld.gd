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
## hand, so only the ways an overworld genuinely differs from an ordinary
## area (get_base_mode(), spawns_party(), needs_navigation()) are overridden
## here.
##
## Was a runtime maze generator (a LAYOUT text grid, walls/floor/door all
## built in _ready()) until the data-driven-areas pass baked that output
## into this scene's own authored nodes instead — see git history on this
## file for the generator this replaced.

const AVATAR_SCENE: PackedScene = preload("res://world/overworld_avatar.tscn")

## Multiplies the avatar's speed. A map built at a
## smaller scale is crossed faster, so the walk still feels the same.
@export var avatar_speed_scale: float = 1.0
## How many times larger the avatar's icon is drawn; see
## OverworldAvatar.icon_scale.
@export var avatar_icon_scale: float = 1.0
## The avatar's icon in the tactical view, as a fraction of its size on
## screen in the follow view: the map is the subject there, the icon only
## marks where you are on it.
@export_range(0.05, 1.0) var tactical_icon_size: float = 0.35
## World units round the avatar where bridge decks above it are cut away
## so a steep camera can still see it; 0 for a low camera that looks
## under the decks instead.
@export var deck_cutaway_radius: float = 7.0
## Seconds the avatar has to stay in a new district before the area
## label changes, so walking along a border does not flicker the name.
@export var district_settle_time: float = 1.0

## How often the avatar's district is looked up, in seconds.
const DISTRICT_POLL := 0.2

@onready var _camera: OverworldCamera = $OverworldCamera
@onready var _environment: WorldEnvironment = get_node_or_null(^"WorldEnvironment")
@onready var _sun: DirectionalLight3D = get_node_or_null(^"DirectionalLight3D")

## What the scene authored for the follow view, which the tactical view
## scales out from; see _apply_view_scale.
var _fog_begin := 0.0
var _fog_end := 0.0
var _shadow_distance := 0.0
var _view_scale := 1.0

## One avatar per group standing here, by group. The overworld is a
## VIEW of PartyManager.groups rather than the owner of an avatar —
## which is what lets a split party be in two places on it instead of
## being collected on arrival.
var _avatars: Dictionary = {}

## The district the label shows, and the one the avatar has been
## standing in for _candidate_time without it showing yet.
var _district: OverworldDistrict
var _candidate: OverworldDistrict
var _candidate_time := 0.0
var _poll := 0.0


func _ready() -> void:
	# Re-synced on focus too, not only here: this world stays resident
	# while a group is standing in it, so coming back does not rebuild it
	# and _ready does not run again.
	WorldManager.world_focused.connect(_on_world_focused)
	RenderingServer.global_shader_parameter_set(&"deck_cutaway_radius", deck_cutaway_radius)
	if _environment and _environment.environment:
		# Its own copy: the scene's is shared by every load of it.
		_environment.environment = _environment.environment.duplicate()
		_fog_begin = _environment.environment.fog_depth_begin
		_fog_end = _environment.environment.fog_depth_end
	if _sun:
		_shadow_distance = _sun.directional_shadow_max_distance
	sync_avatars()
	_camera.snap_to_target()


func _on_world_focused(world: Node) -> void:
	if world == self:
		# Global to every world, so set again whenever this one comes back.
		RenderingServer.global_shader_parameter_set(&"deck_cutaway_radius", deck_cutaway_radius)
		sync_avatars()
		# One that shrank into a door and is still here never left (its
		# trip was refused, or went nowhere): it stands up again.
		for avatar in _avatars.values():
			if is_instance_valid(avatar):
				avatar.stand()
		_apply_view_scale(_view_scale)
		# The label cleared itself when another world took focus; the
		# next poll puts the name back, quietly.
		_district = null


func _process(delta: float) -> void:
	var view := _camera.view_scale()
	if not is_equal_approx(view, _view_scale) and WorldManager.current_world() == self:
		_apply_view_scale(view)
	_poll += delta
	if _poll < DISTRICT_POLL:
		return
	var step := _poll
	_poll = 0.0
	var avatar := _active_avatar()
	if avatar == null or WorldManager.current_world() != self:
		return
	var here := _district_at(avatar.global_position)
	if here == null or here == _district:
		_candidate = null
		return
	# The first name after arriving shows at once; a change waits until
	# the avatar has really crossed.
	if _district != null:
		if here != _candidate:
			_candidate = here
			_candidate_time = 0.0
		_candidate_time += step
		if _candidate_time < district_settle_time:
			return
	var announce := _district != null
	_district = here
	_candidate = null
	get_tree().call_group(&"area_label", &"show_area", here.display_name, announce)


## Everything sized for the follow view grows with the camera's distance
## (OverworldCamera.view_scale): the distance haze moves out with it, so
## the tactical view looks down through clear air at the whole map, the
## sun's shadows reach as far as it can see, and the cutaway of the decks
## over the avatar stays the same size on screen; its icon shrinks on
## screen to tactical_icon_size of what it was. The fog at
## the map's edge is not scaled; it is the end of the world, not haze.
func _apply_view_scale(f: float) -> void:
	_view_scale = f
	if _environment and _fog_end > 0.0:
		_environment.environment.fog_depth_begin = _fog_begin * f
		_environment.environment.fog_depth_end = _fog_end * f
	if _sun and _shadow_distance > 0.0:
		_sun.directional_shadow_max_distance = _shadow_distance * f
	RenderingServer.global_shader_parameter_set(&"deck_cutaway_radius", deck_cutaway_radius * f)
	for avatar in _avatars.values():
		if is_instance_valid(avatar):
			avatar.set_view_scale(_icon_view_scale())



## What the avatar's icon is scaled by for the current view: the camera's
## pull-back, shrunk to tactical_icon_size of it through the swing.
func _icon_view_scale() -> float:
	return _view_scale * lerpf(1.0, tactical_icon_size, _camera.tactical_blend())


## The smallest district holding p, or null outside them all.
func _district_at(p: Vector3) -> OverworldDistrict:
	var districts := get_node_or_null(^"Districts")
	if districts == null:
		return null
	var best: OverworldDistrict = null
	for child in districts.get_children():
		var district := child as OverworldDistrict
		if district and district.has_point(p) and (best == null or district.area() < best.area()):
			best = district
	return best


func get_base_mode() -> GameMode.Mode:
	return GameMode.Mode.OVERWORLD


## Duck-typed — see WorldManager.load_world()'s own header. The overworld
## holds one avatar, not a spawned tactical party; PartyManager.roster
## stays untouched either way, only whether it gets projected into live
## Units for THIS world varies.
func spawns_party() -> bool:
	return false


## The avatar steers directly; nothing here ever asks for a path.
func needs_navigation() -> bool:
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
	avatar.move_speed *= avatar_speed_scale
	avatar.icon_scale = avatar_icon_scale
	add_child(avatar)
	avatar.set_view_scale(_icon_view_scale())
	avatar.camera = _camera

	if group.overworld_position == Vector3.ZERO:
		var spawn_point: Node3D = get_spawn_point(WorldManager.pending_spawn_point_name())
		if spawn_point:
			group.overworld_position = spawn_point.global_position
	avatar.global_position = group.overworld_position
	return avatar
