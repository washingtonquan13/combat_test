class_name OverworldEncounters
extends Node
## Random encounters on the overworld, owned by the overworld (see
## docs/systems/areas_bootstrap.md, "Random encounters"). overworld.gd
## makes one as a child; nothing else does.
##
## Every metre the commanded avatar walks rolls against its district's
## danger. A hit grows a red avatar out of the ground a short way off,
## which chases at a little under the party's pace: outrun it past
## leash_distance and it shrinks away; let it touch and both icons shrink,
## the screen goes black and the district's battle area loads, where
## BattleField starts the fight. The party comes back to the spot it was
## caught (the group's overworld_position, which nothing here touches),
## and walks grace_metres before the next roll. A district holds
## encounter_limit fights; after that it is quiet until a rest clears
## the count (clear_all()).
##
## What is being fought lives in FlagManager (PENDING_FLAG), not here, so
## the fight's own autosave, and Retry from the game over screen, bring
## the same enemies back.

## The fight under way: {"group": EncounterGroup path, "district": name}.
const PENDING_FLAG := "encounter/pending"
## Fights won in a district, by its node name, since the last rest.
const CLEARED_PREFIX := "encounter/cleared/"

## How far off a red avatar appears, in metres.
@export var spawn_distance: float = 45.0
## Past this far away, it gives up.
@export var leash_distance: float = 130.0
## Its pace, as a fraction of the party's.
@export var chase_speed: float = 0.85
## How close it has to get to catch you, centre to centre.
@export var contact_distance: float = 5.0
## Metres walked after arriving before the first roll.
@export var grace_metres: float = 120.0

var overworld: Node
var rng := RandomNumberGenerator.new()

var _chaser: OverworldAvatar
var _chaser_district: OverworldDistrict
var _last: Vector3
var _has_last := false
var _metre := 0.0
var _grace := 0.0


func _ready() -> void:
	rng.randomize()
	WorldManager.world_focused.connect(_on_world_focused)
	_grace = grace_metres


func _on_world_focused(world: Node) -> void:
	if world != overworld:
		_drop_chaser()
		return
	_grace = grace_metres
	_has_last = false


## The fight a red avatar caught you for, or {} with none.
static func pending() -> Dictionary:
	var value: Variant = FlagManager.get_flag(PENDING_FLAG, {})
	return value if value is Dictionary else {}


static func cleared_in(district_name: String) -> int:
	return int(FlagManager.get_flag(CLEARED_PREFIX + district_name, 0))


## Called when a pending fight is won: it counts against its district.
static func finish_pending() -> void:
	var fight := pending()
	FlagManager.clear_flag(PENDING_FLAG)
	if fight.has("district"):
		var district_name := String(fight.district)
		FlagManager.set_flag(CLEARED_PREFIX + district_name, cleared_in(district_name) + 1)


## Every district full again. The rest system's.
static func clear_all() -> void:
	for flag in FlagManager.get_flag_names_with_prefix(CLEARED_PREFIX):
		FlagManager.clear_flag(flag)


func chaser() -> OverworldAvatar:
	return _chaser if is_instance_valid(_chaser) else null


func _physics_process(_delta: float) -> void:
	var avatar: OverworldAvatar = overworld._active_avatar() if overworld else null
	if avatar == null or WorldManager.current_world() != overworld or avatar.is_entering():
		_has_last = false
		return
	if chaser():
		_chase(avatar)
		return
	var here := Vector3(avatar.global_position.x, 0.0, avatar.global_position.z)
	var walked := here.distance_to(_last) if _has_last else 0.0
	_last = here
	_has_last = true
	# A jump this long is a teleport (a load, a snap), not a walk.
	if walked > 50.0:
		return
	if _grace > 0.0:
		_grace -= walked
		return
	_metre += walked
	while _metre >= 1.0:
		_metre -= 1.0
		var district: OverworldDistrict = overworld._district_at(avatar.global_position)
		if can_fight(district) and rng.randf() < district.danger:
			_metre = 0.0
			start(district, avatar)
			return


## Whether `district` has a fight left in it.
func can_fight(district: OverworldDistrict) -> bool:
	return district != null and district.danger > 0.0 and not district.encounters.is_empty() \
		and district.battle_area != &"" \
		and (district.encounter_limit <= 0 or cleared_in(district.name) < district.encounter_limit)


## A red avatar for `district`, spawn_distance away from `avatar`, or on
## top of it for an ambush, where the fight starts as it finishes
## growing. False when the district has nothing left or nowhere to put it.
func start(district: OverworldDistrict, avatar: OverworldAvatar, ambush: bool = false) -> bool:
	if chaser() or not can_fight(district):
		return false
	var at := avatar.global_position if ambush else _spawn_spot(avatar.global_position)
	if at == Vector3.INF:
		return false
	_chaser = overworld.AVATAR_SCENE.instantiate()
	_chaser.hostile = true
	_chaser.move_speed = avatar.move_speed * chase_speed
	_chaser.icon_scale = avatar.icon_scale
	_chaser.camera = avatar.camera
	_chaser_district = district
	overworld.add_child(_chaser)
	_chaser.global_position = at
	_chaser.set_view_scale(overworld._icon_view_scale())
	_chaser.add_collision_exception_with(avatar)
	avatar.add_collision_exception_with(_chaser)
	if ambush:
		_chaser.appear(func() -> void: _catch(avatar))
	else:
		_chaser.appear()
	return true


func _chase(avatar: OverworldAvatar) -> void:
	_chaser.set_view_scale(overworld._icon_view_scale())
	if _chaser.is_entering():
		_chaser.steer = Vector3.ZERO
		return
	var to := avatar.global_position - _chaser.global_position
	to.y = 0.0
	var gap := to.length()
	if gap <= contact_distance:
		_catch(avatar)
	elif gap >= leash_distance:
		var gone := _chaser
		_chaser = null
		gone.vanish(gone.queue_free)
	else:
		_chaser.steer = to / gap


## Both shrink where they stand, then the district's battle area loads
## behind the black.
func _catch(avatar: OverworldAvatar) -> void:
	var district := _chaser_district
	var group: EncounterGroup = district.encounters[_pick(district.encounters)]
	FlagManager.set_flag(PENDING_FLAG, {"group": group.resource_path, "district": String(district.name)})
	_chaser.steer = Vector3.ZERO
	_chaser.vanish()
	avatar.enter(avatar.global_position, func() -> void:
		WorldManager.travel_area(district.battle_area))


func _pick(table: Array[EncounterGroup]) -> int:
	var total := 0.0
	for line in table:
		total += maxf(line.weight, 0.0)
	var roll := rng.randf() * total
	for i in table.size():
		roll -= maxf(table[i].weight, 0.0)
		if roll < 0.0:
			return i
	return table.size() - 1


## Open ground spawn_distance from `from`, in plain view: the first of a
## ring of directions, starting somewhere random, whose drop ray lands on
## the floor rather than on a roof, a tree or a rock.
func _spawn_spot(from: Vector3) -> Vector3:
	var ground: Node = overworld.get_node_or_null(^"Ground")
	if ground == null:
		return Vector3.INF
	var space := (overworld as Node3D).get_world_3d().direct_space_state
	var first := rng.randf() * TAU
	for i in 12:
		var angle := first + TAU * i / 12.0
		var p := from + Vector3(cos(angle), 0.0, sin(angle)) * spawn_distance
		var query := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 300.0, p + Vector3.DOWN * 50.0)
		var hit := space.intersect_ray(query)
		if not hit.is_empty() and (hit.collider == ground or ground.is_ancestor_of(hit.collider)):
			return hit.position
	return Vector3.INF


func _drop_chaser() -> void:
	if chaser():
		_chaser.queue_free()
	_chaser = null
