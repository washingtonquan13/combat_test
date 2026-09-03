class_name CinematicStage
extends Node3D
## The root of an authored scene: a .tscn you can open, lay out, and SCRUB.
##
## WHAT THIS IS FOR, AND IT IS NOW THE ONLY WAY A CUTSCENE IS AUTHORED.
## A phase list is written blind: the author picks numbers, runs the game,
## gets somewhere, and adjusts. Godot already ships the tool for the other
## way round — an AnimationPlayer with a timeline, keys you drag, and a
## viewport that shows the frame you are standing on — and this makes a
## cutscene the kind of thing that tool edits.
##
## The phase/step runtime that used to sit underneath still exists, but it
## has shrunk to what it is actually good at: ONE cut, right now, with no
## time in it — a line of dialogue re-framing its speaker. See
## dialogue_staging.gd, the only caller left. Anything with a SHAPE — beats,
## offsets, bodies appearing and leaving — is a timeline, and the six step
## classes that used to express those (spawn, despawn, place, clip, effect,
## sound) were deleted when fusion moved here. Their vocabulary is the
## method list below.
##
## THE CONTRACT DOES NOT MOVE. CinematicDirector.play() still returns, the
## cast is still roles resolved late, and the camera still speaks exactly
## one vocabulary (CameraFraming, via FramingRig). This is a second FRONT
## END on the same machine, not a second machine.
##
## CONVENTIONS, because a method track key can only carry strings and
## numbers and a stage therefore has to be findable by name:
##
##   Timeline    an AnimationPlayer. Its animations are the performances;
##               CinematicScene.animation names which one plays.
##   Roles       holds StageRole markers — the bodies. See stage_role.gd
##               for why the marker is not the unit.
##   FramingRig  the camera, as keyable properties. More than one is
##               allowed; they are all ticked, which is how a stage could
##               drive a second camera later without this file changing.
##   Marks       optional Marker3Ds, stage-LOCAL. A world mark (group
##               scene_marks) belongs to an area and is shared; these move
##               with the stage and belong to the scene.
##   props       Resources by name, because a method track key cannot carry
##               a Resource. `effect(&"flash", ...)` names an entry here,
##               and so does `spawn(..., "result", ...)`. Authored on the
##               stage for the ones a scene always uses, and MERGED IN by
##               the director for the ones only the caller knows — see
##               CinematicDirector.play()'s third argument.
##
## Native AnimationPlayer tracks are the right answer wherever one exists:
## audio tracks on an AudioStreamPlayer3D child, visibility tracks, tracks
## on any mesh the stage owns. The methods below exist only for the things
## that reach OUT of the stage — a unit, a role, the world — which is
## precisely why they are methods and not nodes.
##
## EVERY METHOD IS SAFE TO CALL WITH NOTHING RESOLVED. A cast where the
## leader died, a role that was never bound, a prop that was renamed: each
## warns and carries on. An AnimationPlayer is a bad place to throw from —
## it would abandon the rest of the track, mid-shot, and the scene would
## freeze rather than look wrong. AND NOTHING HERE AWAITS: a method track
## call is a callback inside the player's own process step, and a coroutine
## started there would resume in a place the player has no opinion about.

## Where in the WORLD this stage is put — a mark from group scene_marks,
## resolved through the cast. Empty leaves it at the world origin, which is
## right for a scene whose framing is relative to a person and wrong for
## one that lays out ground positions.
@export var anchor_mark: StringName = &""
## Name -> Resource, for the arguments a method track cannot carry. A
## VfxEffect for effect(), an SfxCue for sound(), a UnitDefinition for
## spawn(). A caller's props are merged over these at mount.
@export var props: Dictionary = {}

var _cast: SceneCast = null
var _driven: Array[StageRole] = []
var _rigs: Array[FramingRig] = []
var _bound: bool = false


func _ready() -> void:
	set_process(false)


## The AnimationPlayer that IS the performance, or null.
func timeline() -> AnimationPlayer:
	return get_node_or_null(NodePath("Timeline")) as AnimationPlayer


## Points the stage at a cast and starts driving. Called by the director
## after the stage is in the tree, and before the timeline plays.
##
## THE ANCHOR IS RESOLVED HERE rather than by the director, because the
## loudness has to live in one place: cast.mark() already push_errors on a
## mark an area does not have, and a scene naming a mark that is not there
## is an authoring error worth shouting about — a silent fall back to the
## origin puts a whole cutscene at the centre of the world while every
## individual thing still looks like it worked.
func bind(cast: SceneCast) -> void:
	_cast = cast
	_bound = true

	if anchor_mark != &"":
		var spot: Node3D = cast.mark(anchor_mark)
		if spot:
			global_transform = spot.global_transform

	_driven.clear()
	_rigs.clear()
	for node in find_children("*", "", true, false):
		if node is StageRole:
			var marker := node as StageRole
			if marker.drives_actor:
				_driven.append(marker)
			else:
				# The actor is the authority for this role, so the marker
				# is snapped onto it — that is what lets a rig aiming at
				# the role have something to point at, and what keeps the
				# editor layout and the runtime one the same shape.
				var actor: Unit = cast.unit(marker.role_name())
				if actor:
					marker.global_transform = actor.global_transform
		elif node is FramingRig:
			var rig := node as FramingRig
			rig.begin(cast)
			_rigs.append(rig)

	set_process(true)


## Stops driving. The actors are left exactly where the scene put them and
## still claimed — the DIRECTOR releases claims, on every exit path, which
## is the one place that can be sure it happens however a scene ends.
func unbind() -> void:
	set_process(false)
	for rig in _rigs:
		if is_instance_valid(rig):
			rig.end()
	_rigs.clear()
	_driven.clear()
	_cast = null
	_bound = false


func is_bound() -> bool:
	return _bound


## Bodies first, camera second, every frame. A rig that resolved its shot
## before the actors moved would frame them one frame late, which on a
## fast move is visible as a camera that lags its subject.
func _process(_delta: float) -> void:
	for marker in _driven:
		if not is_instance_valid(marker):
			continue
		var actor: Unit = _actor(marker.role_name())
		if actor:
			actor.global_transform = marker.global_transform
	for rig in _rigs:
		if is_instance_valid(rig):
			rig.tick()


# --- Method-track targets ------------------------------------------
# Each takes roles and marks BY NAME, so a key needs nothing but strings
# and numbers.
#
# TWO KEYS MAY NOT SHARE A TIME. Animation replaces a key whose time
# matches an existing one to within an epsilon, so "place both parents at
# 1.2" silently becomes "place the second one", and the .tscn still looks
# right. Stagger them by an animation step — see fusion.tscn, whose pair
# land at 1.2 and 1.21.


## Brings an actor into the world and HOLDS it in a role.
##
## `definition_name` NAMES a UnitDefinition, and is resolved in two places,
## in this order:
##
##   1. `props`, by name. The fusion result is COMPUTED at perform() time
##      from the two demons going in, so there is no path to write on a
##      key — the caller hands it to the director, which merges it into
##      props at mount, and the timeline names the slot.
##   2. a res:// path, loaded. The static case: a scene that always
##      produces the same body says so on the key and needs no caller.
##
## Props first, because a runtime value is the more specific answer and a
## scene that has been handed one should not silently fall back to a
## default baked into its own timeline.
##
## The name is a String rather than a StringName only because a path has
## to fit in the same argument; a props key is looked up both ways, since
## a Dictionary tells the two types apart and a key written either way in
## the editor should find its prop.
##
## Holding is why this is not gameplay code: a scene that CREATES an actor
## is the only authority on it, and there is nobody to ask for a thing
## that did not exist when the scene started.
func spawn(role: StringName, definition_name: String, at: StringName = &"") -> void:
	if not _ready_to_act("spawn"):
		return
	if role == &"":
		push_warning("CinematicStage.spawn: no role named.")
		return
	var definition: UnitDefinition = _definition(definition_name)
	if definition == null or definition.unit_scene == null:
		push_warning("CinematicStage.spawn: '%s' names no UnitDefinition with a unit_scene."
			% definition_name)
		return
	var parent: Node = WorldManager.spawn_parent()
	if parent == null:
		push_warning("CinematicStage.spawn: nowhere to spawn '%s' — no world." % role)
		return

	var spawned: Unit = definition.unit_scene.instantiate()
	# BEFORE add_child, and this is not stylistic. Unit adopts its body in
	# _enter_tree, so a definition assigned afterwards produces a unit with
	# no model at all — silently, because a bodiless unit walks, fights and
	# dies perfectly well. This project has shipped that bug twice.
	spawned.definition = definition
	parent.add_child(spawned)

	var spot: Node3D = _spot(at)
	if spot:
		spawned.global_transform = spot.global_transform
	_cast.hold(role, spawned)


## Takes an actor off the screen, and out of its role.
func despawn(role: StringName) -> void:
	if not _ready_to_act("despawn"):
		return
	var leaving: Unit = _actor(role)
	if leaving == null:
		push_warning("CinematicStage.despawn: nobody is playing '%s'." % role)
		return
	_cast.release_role(role)
	leaving.queue_free()


## Puts an actor on a mark. For a role that is not driven by its marker;
## a driven one is placed by keying the marker itself, which is the whole
## reason drives_actor exists.
func place(role: StringName, mark: StringName) -> void:
	if not _ready_to_act("place"):
		return
	var actor: Unit = _actor(role)
	if actor == null:
		push_warning("CinematicStage.place: nobody is playing '%s'." % role)
		return
	var spot: Node3D = _spot(mark)
	if spot == null:
		push_warning("CinematicStage.place: no mark or role named '%s'." % mark)
		return
	actor.global_transform = spot.global_transform


## Makes an actor play a clip, and claims it while it does.
##
## The claim is what stops gameplay animating over the shot: damage plays
## a hit clip, movement plays a walk, and either landing mid-performance
## replaces the pose with nothing reporting it. Released by the director
## when the scene ends, however it ends.
func clip(role: StringName, animation_name: String, claims: bool = true) -> void:
	if not _ready_to_act("clip"):
		return
	var actor: Unit = _actor(role)
	if actor == null:
		push_warning("CinematicStage.clip: nobody is playing '%s'." % role)
		return
	var animator: UnitAnimator = actor.animator()
	if animator == null:
		# Normal, not an error: a bodiless unit, or a model that brought no
		# AnimationPlayer. The scene carries on.
		return
	if claims:
		animator.claim_for_cutscene()
		_cast.note_claim(actor)
	animator.play_cutscene_clip(animation_name)


## Plays a VfxEffect from `props`. `from` and `to` are role or mark names;
## an empty `to` means "at the same place", which is every burst that is
## not a projectile.
func effect(prop: StringName, from: StringName, to: StringName = &"") -> void:
	if not _ready_to_act("effect"):
		return
	var vfx: VfxEffect = props.get(prop) as VfxEffect
	if vfx == null:
		push_warning("CinematicStage.effect: no VfxEffect prop named '%s'." % prop)
		return
	# The world, not an actor: an actor freed mid-effect takes any Tween it
	# owns with it and cuts the visual off.
	var context: Node = WorldManager.spawn_parent()
	if context == null or not context.is_inside_tree():
		return
	var start: Vector3 = _point(from)
	var finish: Vector3 = _point(to) if to != &"" else start
	# Not awaited, and this method must never await — see the header.
	vfx.play(context, start, finish)


## Plays an SfxCue from `props` at a role or mark.
##
## A sound that BELONGS to the stage (it is always in the same place,
## always at the same moment) is better as a native audio track on an
## AudioStreamPlayer3D child. This is for the ones that happen where an
## actor happens to be.
func sound(prop: StringName, at: StringName) -> void:
	if not _ready_to_act("sound"):
		return
	var cue: SfxCue = props.get(prop) as SfxCue
	if cue == null:
		push_warning("CinematicStage.sound: no SfxCue prop named '%s'." % prop)
		return
	var context: Node = WorldManager.spawn_parent()
	if context == null or not context.is_inside_tree():
		return
	cue.play(context, _point(at))


# --- Name resolution -----------------------------------------------


## A UnitDefinition from a props key or a res:// path — see spawn().
##
## Both key types are tried because a Dictionary does NOT treat &"result"
## and "result" as the same key, and the two ends of this are written by
## different hands: a caller passes props in code (StringName), an author
## types a key into the inspector (String).
##
## ResourceLoader.exists() rather than a bare load(), so a name that was
## meant as a prop and found nothing declines through spawn()'s own
## warning instead of also filling the log with a missing-file error.
func _definition(named: String) -> UnitDefinition:
	var prop: Variant = props.get(StringName(named))
	if prop == null:
		prop = props.get(named)
	if prop is UnitDefinition:
		return prop
	if named.begins_with("res://") and ResourceLoader.exists(named):
		return load(named) as UnitDefinition
	return null


func _ready_to_act(what: String) -> bool:
	if _cast == null:
		push_warning("CinematicStage.%s called on a stage that is not bound." % what)
		return false
	return true


func _actor(role: StringName) -> Unit:
	return _cast.unit(role) if _cast else null


## A transform to put something on, from a name that may be a stage-local
## mark, a StageRole, or a world mark. Stage-local wins: a stage is the
## more specific answer, and an area sharing a mark name with a scene's own
## staging should not silently retarget it.
func _spot(spot_name: StringName) -> Node3D:
	if spot_name == &"":
		return null
	var marks: Node = get_node_or_null(NodePath("Marks"))
	if marks:
		var local := marks.get_node_or_null(NodePath(String(spot_name))) as Node3D
		if local:
			return local
	var marker: StageRole = _role_marker(spot_name)
	if marker:
		return marker
	if _cast and _cast.has_mark(spot_name):
		return _cast.mark(spot_name)
	return null


## Somewhere for an effect or a sound to happen. Same order as _spot, then
## the ACTOR in the role — which is what an effect usually means when it
## names a role, since an actor moves and its marker may not.
func _point(spot_name: StringName) -> Vector3:
	if spot_name == &"":
		return Vector3.ZERO
	var actor: Unit = _actor(spot_name)
	if actor:
		return actor.anchor(CharacterModel.Anchor.CHEST)
	var spot: Node3D = _spot(spot_name)
	return spot.global_position if spot else Vector3.ZERO


func _role_marker(role: StringName) -> StageRole:
	for node in find_children("*", "", true, false):
		if node is StageRole and (node as StageRole).role_name() == role:
			return node
	return null
