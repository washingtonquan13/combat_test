@tool
class_name CinematicStage
extends Node3D
## The root of an authored cutscene: a .tscn you can open, lay out, and
## SCRUB. The .tscn IS the cutscene — there is no resource per scene; a
## caller hands CinematicDirector.play() this scene's PackedScene.
##
## WHY A TIMELINE. A list of steps at offsets is written blind: the author
## picks numbers, runs the game, and adjusts. Godot already ships the tool
## for the other way round — an AnimationPlayer with keys you drag and a
## viewport that shows the frame you are standing on — and this makes a
## cutscene the kind of thing that tool edits.
##
## THE CONTRACT DOES NOT MOVE. CinematicDirector.play() still returns, the
## cast is still roles resolved late, and the camera still speaks exactly
## one vocabulary (CameraFraming, via FramingRig).
##
## CONVENTIONS — a stage is found by name, because a track is a NodePath:
##
##   Timeline   the AnimationPlayer. Its animations are the performances;
##              play()'s `animation` argument names which one runs.
##   Roles/     StageRole markers — the bodies. See stage_role.gd for why
##              the marker is not the unit.
##   Shots/     FramingRig nodes, ONE PER SHOT. The `shot` property below
##              names the live one, and keying `shot` on a discrete track
##              IS a camera cut. A move within a shot is keys on that rig's
##              own properties. Only the live shot drives the camera.
##   Marks/     optional Marker3Ds, stage-LOCAL. A world mark (group
##              scene_marks) belongs to an area and is shared; these move
##              with the stage and belong to the scene.
##   Beats/     BeatNode children — the things that HAPPEN (a line, a
##              walk, a spawn). The timeline fires one with a Call Method
##              key on the beat itself, method fire(); each beat reads its
##              own fire time back off the timeline (fire_time_of), which
##              is what lets skip and the editor preview find it.
##   props      runtime values a caller computed and hands in through
##              play() — fusion's result demon. Resources an author picks
##              are exported on the beat that uses them, not put here.
##   world_marks  the AREA marks (group scene_marks) the scene expects.
##              Declared so the name fields can offer them and a typo is a
##              warning in the editor rather than a push_error mid-scene.
##
## Native AnimationPlayer tracks are the right answer wherever one exists:
## an audio track on an AudioStreamPlayer3D child, a visibility track, any
## mesh the stage owns. Beats exist for the things that reach OUT of the
## stage — a unit, a role, the world.
##
## @tool, and every runtime path is guarded, because in the editor this
## node does two jobs only: offers dropdowns (the `shot` list) and drives a
## PREVIEW — one unsaved Camera3D following the live shot, and each beat
## previewing itself on the StageRole stand-ins as the timeline is
## scrubbed. Nothing the preview touches is saved into the .tscn.
##
## EVERY HELPER IS SAFE TO CALL WITH NOTHING RESOLVED. A cast where the
## leader died, a role never bound, a prop renamed: each warns and carries
## on. The beats call them from inside a method key, a bad place to throw
## from — the player would abandon the rest of the track mid-shot. AND
## NOTHING HERE AWAITS: a method key is a callback inside the player's own
## process step, and a coroutine started there would resume somewhere the
## player has no opinion about. Work that spans frames is ticked instead
## (run()).

const TIMELINE_NAME: StringName = &"Timeline"
const ROLES_NAME: StringName = &"Roles"
const SHOTS_NAME: StringName = &"Shots"
const MARKS_NAME: StringName = &"Marks"
const BEATS_NAME: StringName = &"Beats"
## The editor-only preview camera. Added without an owner so it is never
## packed — the same trick StageRole's stand-in uses.
const PREVIEW_NAME: StringName = &"__StagePreviewCamera"
const PREVIEW_SET_NAME: StringName = &"__StagePreviewSet"
## The animation a stage is assumed to perform when nothing has named one
## yet — the editor before anything is selected, and play()'s default.
const DEFAULT_ANIMATION: StringName = &"scene"
## Godot's reset-on-save animation. Never the performance, whatever the
## editor happens to have selected.
const RESET_ANIMATION: StringName = &"RESET"
## How often the editor preview re-runs with the time standing still.
const PREVIEW_REFRESH_FRAMES: int = 15

## Where in the WORLD this stage is put — a mark from group scene_marks,
## resolved through the cast. Empty leaves it at the world origin, which is
## right for a scene whose framing is relative to a person and wrong for
## one that lays out ground positions.
@export var anchor_mark: StringName = &""
## Name -> runtime value. Filled by the caller through play(); an authored
## entry is a default the caller can override.
@export var props: Dictionary = {}
## See the header. Offered alongside the stage's own Marks/ in every mark
## field, and the only names a warning cannot otherwise check.
@export var world_marks: PackedStringArray = PackedStringArray()
## The live shot: a child name under Shots/. Empty means the first one.
## Offered as a dropdown (see _validate_property), and keyed on a discrete
## track to cut.
@export var shot: StringName = &""
## The room this scene plays in, shown in the EDITOR only, so scrubbing
## shows the shot against the walls it will really have. Instanced
## unowned (never saved into this .tscn) at the stage origin, which is
## where the stage is anchored at runtime — so a set built around its own
## origin lines up with anchor_mark. At runtime the real area is there and
## this is ignored.
@export var preview_set: PackedScene = null:
	set(value):
		preview_set = value
		_rebuild_preview_set()
## Selects the preview camera so the 3D viewport's Preview toggle appears
## for it. Needed because the camera is unsaved and so never listed in the
## Scene dock, which is the only other way to select it.
@export_tool_button("Look through preview camera", "Camera3D")
var look_through_preview: Callable = _look_through_preview

var _cast: SceneCast = null
var _driven: Array[StageRole] = []
var _bound: bool = false
## A beat asked the timeline to hold for the player. The director polls
## this; see wait_for_advance().
var _waiting: bool = false
## Fired beats still at work, ticked every frame. See run().
var _active: Array[BeatNode] = []
## The beat whose line is in the subtitle band. See show_line().
var _line_owner: BeatNode = null
var _preview: Camera3D = null
var _preview_set_node: Node = null
var _previewed_at: float = -1.0
var _preview_countdown: int = 0


func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(true)
		_rebuild_preview_set()
		return
	set_process(false)


func _validate_property(property: Dictionary) -> void:
	if property.name == "shot":
		property.hint = PROPERTY_HINT_ENUM
		property.hint_string = ",".join(shot_names())
	elif property.name == "anchor_mark":
		property.hint = PROPERTY_HINT_ENUM_SUGGESTION
		property.hint_string = ",".join(world_marks)


# --- Discovery -----------------------------------------------------


## The AnimationPlayer that IS the performance, or null.
func timeline() -> AnimationPlayer:
	return get_node_or_null(NodePath(TIMELINE_NAME)) as AnimationPlayer


## The animation being performed, or being edited: whatever the Timeline
## has assigned, else the default name.
func performance() -> Animation:
	var player: AnimationPlayer = timeline()
	if player == null:
		return null
	var named: StringName = player.assigned_animation
	if named == &"" or named == RESET_ANIMATION or not player.has_animation(named):
		named = DEFAULT_ANIMATION
	return player.get_animation(named) if player.has_animation(named) else null


func shots() -> Array[FramingRig]:
	var found: Array[FramingRig] = []
	var holder: Node = get_node_or_null(NodePath(SHOTS_NAME))
	if holder:
		for child in holder.get_children():
			if child is FramingRig:
				found.append(child)
	return found


func shot_names() -> PackedStringArray:
	var names := PackedStringArray()
	for rig in shots():
		names.append(String(rig.name))
	return names


## The shot driving the camera right now: the one `shot` names, else the
## first. A name with no rig falls back rather than going dark — the
## configuration warning is where that gets reported.
func live_shot() -> FramingRig:
	var all: Array[FramingRig] = shots()
	if all.is_empty():
		return null
	if shot != &"":
		for rig in all:
			if rig.name == shot:
				return rig
	return all[0]


func roles() -> Array[StageRole]:
	var found: Array[StageRole] = []
	var holder: Node = get_node_or_null(NodePath(ROLES_NAME))
	if holder:
		for node in holder.find_children("*", "Marker3D", true, false):
			if node is StageRole:
				found.append(node)
	return found


func role_names() -> PackedStringArray:
	var names := PackedStringArray()
	for marker in roles():
		names.append(String(marker.role_name()))
	return names


func role_marker(role: StringName) -> StageRole:
	for marker in roles():
		if marker.role_name() == role:
			return marker
	return null


## A stage-local mark by name, or null.
func local_mark(mark_name: StringName) -> Node3D:
	if mark_name == &"":
		return null
	var holder: Node = get_node_or_null(NodePath(MARKS_NAME))
	if holder == null:
		return null
	return holder.get_node_or_null(NodePath(String(mark_name))) as Node3D


func mark_names() -> PackedStringArray:
	var names := PackedStringArray()
	var holder: Node = get_node_or_null(NodePath(MARKS_NAME))
	if holder:
		for child in holder.get_children():
			if child is Node3D:
				names.append(String(child.name))
	return names


## Every name a mark field can resolve: the stage's own Marks/ and the
## declared world marks. What the dropdowns offer and the warnings accept.
func spot_names() -> PackedStringArray:
	var names: PackedStringArray = mark_names()
	for world_mark in world_marks:
		if not names.has(world_mark):
			names.append(world_mark)
	return names


## Whether `spot_name` resolves to something this stage knows of: a local
## mark, a role, or a declared world mark.
func knows_spot(spot_name: StringName) -> bool:
	return local_mark(spot_name) != null or role_marker(spot_name) != null \
		or world_marks.has(String(spot_name))


func beats() -> Array[BeatNode]:
	var found: Array[BeatNode] = []
	var holder: Node = get_node_or_null(NodePath(BEATS_NAME))
	if holder:
		for child in holder.get_children():
			if child is BeatNode:
				found.append(child)
	return found


## When the timeline fires `beat`: the earliest Call Method key, on any
## method track whose path resolves to it, calling fire(). -1 when nothing
## keys it — a beat that never fires, which BeatNode warns about.
##
## Read off the timeline rather than stored on the beat, so dragging the
## key is the only way to re-time it and the two can never disagree.
func fire_time_of(beat: Node) -> float:
	return _fire_time_in(performance(), beat)


## Whether any animation on the Timeline fires `beat` — a beat keyed only
## in a variant performance is not an unkeyed beat.
func is_keyed(beat: Node) -> bool:
	var player: AnimationPlayer = timeline()
	if player == null:
		return false
	for anim_name in player.get_animation_list():
		if _fire_time_in(player.get_animation(anim_name), beat) >= 0.0:
			return true
	return false


func _fire_time_in(anim: Animation, beat: Node) -> float:
	var player: AnimationPlayer = timeline()
	if player == null or anim == null:
		return -1.0
	var root: Node = player.get_node_or_null(player.root_node)
	if root == null:
		return -1.0
	var earliest: float = -1.0
	for track in anim.get_track_count():
		if anim.track_get_type(track) != Animation.TYPE_METHOD:
			continue
		if root.get_node_or_null(anim.track_get_path(track)) != beat:
			continue
		for key in anim.track_get_key_count(track):
			if anim.method_track_get_name(track, key) != &"fire":
				continue
			var time: float = anim.track_get_key_time(track, key)
			if earliest < 0.0 or time < earliest:
				earliest = time
	return earliest


## Keyed beats in the order the timeline fires them, each paired with its
## time: [[beat, time, index], ...]. Beats at the same time keep their
## order under Beats/ — sort_custom is not stable, so the tie is broken
## explicitly.
func timed_beats() -> Array:
	var timed: Array = []
	var all: Array[BeatNode] = beats()
	for index in all.size():
		var time: float = fire_time_of(all[index])
		if time >= 0.0:
			timed.append([all[index], time, index])
	timed.sort_custom(func(a: Array, b: Array) -> bool:
		return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]))
	return timed


# --- Runtime -------------------------------------------------------


## Points the stage at a cast and starts driving. Called by the director
## after the stage is in the tree, and before the timeline plays.
##
## THE ANCHOR IS RESOLVED HERE rather than by the director, because the
## loudness has to live in one place: cast.mark() already push_errors on a
## mark an area does not have, and a silent fall back to the origin puts a
## whole cutscene at the centre of the world while every individual thing
## still looks like it worked.
func bind(cast: SceneCast) -> void:
	_cast = cast
	_bound = true
	_waiting = false
	_active.clear()
	_line_owner = null
	var own_marks: Dictionary = {}
	for mark_name in mark_names():
		own_marks[StringName(mark_name)] = local_mark(StringName(mark_name))
	cast.use_stage_marks(own_marks)

	if anchor_mark != &"":
		var spot_node: Node3D = cast.mark(anchor_mark)
		if spot_node:
			global_transform = spot_node.global_transform

	_driven.clear()
	for marker in roles():
		if marker.drives_actor:
			_driven.append(marker)
		else:
			# The actor is the authority for this role, so the marker is
			# snapped onto it — that is what lets a rig aiming at the role
			# have something to point at, and keeps the editor layout and
			# the runtime one the same shape.
			var actor_now: Unit = cast.unit(marker.role_name())
			if actor_now:
				marker.global_transform = actor_now.global_transform
	for rig in shots():
		rig.begin(cast)

	set_process(true)


## Stops driving. The actors are left exactly where the scene put them and
## still claimed — the DIRECTOR releases claims, on every exit path, which
## is the one place that can be sure it happens however a scene ends.
##
## A beat still running here is DROPPED, not finished. A scene that ended
## normally has none (is_running() waits them out), and a skipped or
## settled one finished them in skip_to_end(); what is left is a scene
## whose world is being unloaded, where there is nothing to finish onto.
func unbind() -> void:
	set_process(false)
	for rig in shots():
		rig.end()
	_driven.clear()
	_active.clear()
	_line_owner = null
	if _cast:
		_cast.use_stage_marks({})
	_cast = null
	_bound = false
	_waiting = false


func is_bound() -> bool:
	return _bound


func cast() -> SceneCast:
	return _cast


## Whether the performance is still going: playing, held for input, or
## with a beat still at work (a walk that outlasts the last key). The
## director asks this rather than the player, because a held timeline is
## not a finished one, and neither is a scene whose actor is mid-stride.
func is_running() -> bool:
	if _waiting or not _active.is_empty():
		return true
	var player: AnimationPlayer = timeline()
	return player != null and player.is_playing()


func is_waiting() -> bool:
	return _waiting


## Holds the timeline until the player presses cinematic_advance. Called
## by a beat from inside its fire(), i.e. from inside the player's own
## process step.
##
## HELD BY speed_scale, NOT pause(). pause() from within a method key tears
## down the player's caches while it is still iterating them; a zero speed
## changes nothing but how far the next step moves, and is_playing() stays
## true, which is also the honest answer. The director polls is_waiting()
## and calls advance(); nothing here awaits anything.
func wait_for_advance() -> void:
	if Engine.is_editor_hint() or not _bound:
		return
	var player: AnimationPlayer = timeline()
	if player == null:
		return
	_waiting = true
	player.speed_scale = 0.0


## Releases a wait_for_advance() hold. Called by the director on input,
## and by a LineBeat whose auto_seconds ran out.
func advance() -> void:
	if not _waiting:
		return
	_waiting = false
	var player: AnimationPlayer = timeline()
	if player:
		player.speed_scale = 1.0


## A fired beat that has more to do on later frames (a walk, a line on a
## timer) asks to be ticked. Ticked in _drive() until its tick() says it is
## done; see is_running() for why the scene waits for it.
func run(beat: BeatNode) -> void:
	if not _active.has(beat):
		_active.append(beat)


## Brings the performance to its AUTHORED END STATE, now.
##
## Three parts, because a timeline holds three kinds of thing:
##   - PROPERTY tracks are state, so seeking to the end with update lands
##     every one on its final value (the last shot, the rig's last move).
##     update_only, so method keys are NOT called — the beats are settled
##     below, and doing both would fire one twice.
##   - Beats still RUNNING (a walk half-way) are finished: put where they
##     were going.
##   - Beats NOT YET FIRED get skip(), in timeline order, which applies
##     each one's end state with no visuals and no sound. "Not yet fired"
##     is each beat's own record rather than a comparison with the play
##     position, because a key at the exact position skip was pressed on
##     may or may not have fired yet depending on the callback mode.
## Then one frame of driving, so the camera is on the final framing before
## the director unbinds — a skipped scene ends like a finished one.
func skip_to_end() -> void:
	if Engine.is_editor_hint():
		return
	var player: AnimationPlayer = timeline()
	var anim: Animation = performance()
	if player == null or anim == null:
		return
	_waiting = false
	player.speed_scale = 1.0
	player.seek(anim.length, true, true)
	player.pause()
	var running: Array[BeatNode] = _active.duplicate()
	_active.clear()
	for beat in running:
		if is_instance_valid(beat):
			beat.finish()
	for pair in timed_beats():
		var beat: BeatNode = pair[0]
		if not beat.has_fired():
			beat.skip()
	_drive(0.0)


## Bodies first, camera second, every frame. A shot resolved before the
## actors moved would frame them one frame late, which on a fast move is
## visible as a camera that lags its subject.
func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		_editor_tick()
		return
	_drive(delta)


func _drive(delta: float) -> void:
	# Beats before markers: a walking beat moves its actor AND its driven
	# marker (see put()), so the copy below agrees with it either way.
	for beat in _active.duplicate():
		if not is_instance_valid(beat) or not beat.tick(delta):
			_active.erase(beat)
	for marker in _driven:
		if not is_instance_valid(marker):
			continue
		var actor_now: Unit = actor(marker.role_name())
		if actor_now:
			actor_now.global_transform = marker.global_transform
	var rig: FramingRig = live_shot()
	if rig:
		rig.tick()


# --- Helpers the beats call ------------------------------------------
# Called by BeatNode subclasses, NOT keyed. The timeline's only method
# keys are fire() on a beat; a key on the stage itself is flagged by the
# configuration warning below, because an argument list typed into a key
# is exactly the blind authoring beats replaced.


## Brings an actor into the world and HOLDS it in a role.
##
## Holding is why this is not gameplay code: a scene that CREATES an actor
## is the only authority on it.
func spawn(role: StringName, definition: UnitDefinition, at: StringName = &"") -> Unit:
	if not _ready_to_act("spawn"):
		return null
	if role == &"":
		push_warning("CinematicStage.spawn: no role named.")
		return null
	if definition == null or definition.unit_scene == null:
		push_warning("CinematicStage.spawn: no UnitDefinition with a unit_scene for '%s'." % role)
		return null
	var parent: Node = WorldManager.spawn_parent()
	if parent == null:
		push_warning("CinematicStage.spawn: nowhere to spawn '%s' — no world." % role)
		return null

	var spawned: Unit = definition.unit_scene.instantiate()
	# BEFORE add_child, and this is not stylistic. Unit adopts its body in
	# _enter_tree, so a definition assigned afterwards produces a unit with
	# no model at all — silently, because a bodiless unit works fine.
	spawned.definition = definition
	parent.add_child(spawned)

	_cast.hold(role, spawned)
	var spot_node: Node3D = spot(at)
	if spot_node:
		put(role, spot_node.global_transform)
	return spawned


## Takes an actor off the screen, and out of its role. A TRACKED role is
## freed too — despawning the leader frees the leader — so a scene that
## only wants someone out of shot moves them instead.
func despawn(role: StringName) -> void:
	if not _ready_to_act("despawn"):
		return
	var leaving: Unit = actor(role)
	if leaving == null:
		push_warning("CinematicStage.despawn: nobody is playing '%s'." % role)
		return
	_cast.release_role(role)
	leaving.queue_free()


## Puts the actor in `role` at `where` — and, for a role whose marker
## drives its actor, the marker too, or the next frame's copy would put
## the actor straight back. The one way a beat moves a body.
func put(role: StringName, where: Transform3D) -> void:
	var actor_now: Unit = actor(role)
	if actor_now:
		actor_now.global_transform = where
	sync_marker(role)


## Copies an actor's transform onto its marker when the marker drives it.
## For a beat that turned the actor through the Unit's own API.
func sync_marker(role: StringName) -> void:
	var marker: StageRole = role_marker(role)
	var actor_now: Unit = actor(role)
	if marker and actor_now and marker.drives_actor:
		marker.global_transform = actor_now.global_transform


## Makes an actor play a clip, and claims it while it does — the claim is
## what stops gameplay animating over the shot. Released by the director
## when the scene ends, however it ends.
func clip(role: StringName, animation_name: String, claims: bool = true) -> void:
	if not _ready_to_act("clip"):
		return
	var actor_now: Unit = actor(role)
	if actor_now == null:
		push_warning("CinematicStage.clip: nobody is playing '%s'." % role)
		return
	var animator: UnitAnimator = actor_now.animator()
	if animator == null:
		# Normal: a bodiless unit, or a model with no AnimationPlayer.
		return
	if claims:
		animator.claim_for_cutscene()
		_cast.note_claim(actor_now)
	animator.play_cutscene_clip(animation_name)


## `from` and `to` are role or mark names; an empty `to` means "at the same
## place", which is every burst that is not a projectile.
func effect(vfx: VfxEffect, from: StringName, to: StringName = &"") -> void:
	if not _ready_to_act("effect") or vfx == null:
		return
	# The world, not an actor: an actor freed mid-effect takes any Tween it
	# owns with it and cuts the visual off.
	var context: Node = WorldManager.spawn_parent()
	if context == null or not context.is_inside_tree():
		return
	var start: Vector3 = point(from)
	var finish: Vector3 = point(to) if to != &"" else start
	# Not awaited, and this must never await — see the header.
	vfx.play(context, start, finish)


func sound(cue: SfxCue, at: StringName) -> void:
	if not _ready_to_act("sound") or cue == null:
		return
	var context: Node = WorldManager.spawn_parent()
	if context == null or not context.is_inside_tree():
		return
	cue.play(context, point(at))


## Puts a line in the subtitle band on behalf of `beat`. clear_line() only
## clears a line the same beat put up, so a timed line running out does not
## wipe the next one that has already replaced it.
func show_line(beat: BeatNode, speaker: String, text: String) -> void:
	if not _ready_to_act("show_line"):
		return
	_line_owner = beat
	var screen: CinematicOverlay = CinematicDirector.overlay()
	if screen:
		screen.show_line(speaker, text)


func clear_line(beat: BeatNode) -> void:
	if Engine.is_editor_hint() or _line_owner != beat:
		return
	_line_owner = null
	var screen: CinematicOverlay = CinematicDirector.overlay()
	if screen:
		screen.clear_line()


## `text` with every {key} replaced by the prop of that name — how a line
## says the result's name without a beat per demon. Only plain values (a
## String, a StringName, a number) fill a token; a token naming anything
## else, or nothing, is left as written so the gap is visible on screen
## rather than silently blank.
func fill(text: String) -> String:
	var values := {}
	for key in props:
		var value: Variant = props[key]
		if value is String or value is StringName or value is int or value is float:
			values[String(key)] = str(value)
	return text.format(values)


## A runtime value by key. Both key types are tried because a Dictionary
## does NOT treat &"result" and "result" as the same key, and the two ends
## are written by different hands.
func prop(key: String) -> Variant:
	var found: Variant = props.get(StringName(key))
	return found if found != null else props.get(key)


# --- Name resolution -----------------------------------------------


## Who is playing `role`, or null.
func actor(role: StringName) -> Unit:
	return _cast.unit(role) if _cast else null


## A transform to put something on, from a name that may be a stage-local
## mark, a StageRole, or a world mark. Stage-local wins: an area sharing a
## mark name with a scene's own staging should not silently retarget it.
func spot(spot_name: StringName) -> Node3D:
	if spot_name == &"":
		return null
	var local: Node3D = local_mark(spot_name)
	if local:
		return local
	var marker: StageRole = role_marker(spot_name)
	if marker:
		return marker
	if _cast and _cast.has_mark(spot_name):
		return _cast.mark(spot_name)
	return null


## Where someone or something IS: the actor in a role first (an actor
## moves, and a non-driving marker does not follow it), then spot(). What
## a walk heads for and a turn faces.
func locate(spot_name: StringName) -> Node3D:
	var actor_now: Unit = actor(spot_name)
	return actor_now if actor_now else spot(spot_name)


## Somewhere for an effect or a sound to happen. The actor's CHEST in a
## role — an effect at someone's feet reads as missing them — then the
## same order as spot().
func point(spot_name: StringName) -> Vector3:
	if spot_name == &"":
		return Vector3.ZERO
	var actor_now: Unit = actor(spot_name)
	if actor_now:
		return actor_now.anchor(CharacterModel.Anchor.CHEST)
	var spot_node: Node3D = spot(spot_name)
	return spot_node.global_position if spot_node else Vector3.ZERO


## Also the editor guard for every helper, in one place: autoloads do not
## run in the editor, so a helper reaching WorldManager or the director
## from a @tool script there would be calling into nothing.
func _ready_to_act(what: String) -> bool:
	if Engine.is_editor_hint():
		return false
	if _cast == null:
		push_warning("CinematicStage.%s called on a stage that is not bound." % what)
		return false
	return true


# --- Editor --------------------------------------------------------


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if timeline() == null:
		warnings.append("No 'Timeline' AnimationPlayer child — there is no performance to play.")
	if shots().is_empty():
		warnings.append("No FramingRig under 'Shots' — the scene has no camera.")
	elif shot != &"" and not shot_names().has(String(shot)):
		warnings.append("'shot' names '%s', which is not a child of Shots." % shot)
	warnings.append_array(_method_key_problems())
	return warnings


## Two kinds of method key that look right in the track editor and are not:
##
##   TWO KEYS AT ONE TIME ON ONE TRACK. The editor REPLACES a key inserted
##   within an epsilon of an existing one, so a pair meant to fire together
##   becomes one; and a pair that made it into the file this way fires in
##   an order nobody chose. Give each beat its own track instead.
##   A KEY ON THE STAGE ITSELF. The helpers are for beats; a key calling
##   one is an argument list typed blind, which is what beats replaced.
func _method_key_problems() -> PackedStringArray:
	var found := PackedStringArray()
	var player: AnimationPlayer = timeline()
	if player == null:
		return found
	var root: Node = player.get_node_or_null(player.root_node)
	for anim_name in player.get_animation_list():
		var anim: Animation = player.get_animation(anim_name)
		for track in anim.get_track_count():
			if anim.track_get_type(track) != Animation.TYPE_METHOD:
				continue
			var path: NodePath = anim.track_get_path(track)
			if root and root.get_node_or_null(path) == self:
				found.append("'%s': a method track keys the stage itself — use a beat under Beats/."
					% anim_name)
			for key in range(1, anim.track_get_key_count(track)):
				var time: float = anim.track_get_key_time(track, key)
				if is_equal_approx(time, anim.track_get_key_time(track, key - 1)):
					found.append("'%s': two method keys at %.3fs on track '%s' — give each its own track."
						% [anim_name, time, path])
	return found


## Scrubbing, watched. The AnimationPlayer editor seeks the Timeline, which
## sets the rigs' and the stage's keyed properties; this follows along so
## the preview camera shows the live shot and the beats show their state.
## Beats are re-previewed when the time moves, and every so often anyway so
## an edited beat field shows up without a scrub.
func _editor_tick() -> void:
	if not _in_edited_scene():
		return
	var now: float = _editor_time()
	_preview_countdown -= 1
	if now != _previewed_at or _preview_countdown <= 0:
		_previewed_at = now
		_preview_countdown = PREVIEW_REFRESH_FRAMES
		_preview_beats(now)
	_preview_shot()


func _in_edited_scene() -> bool:
	if not is_inside_tree():
		return false
	var edited: Node = get_tree().edited_scene_root
	return edited != null and (edited == self or edited.is_ancestor_of(self))


func _editor_time() -> float:
	var player: AnimationPlayer = timeline()
	if player == null or player.assigned_animation == &"":
		return 0.0
	return player.current_animation_position


## Every stand-in back to its marker, then each keyed beat in firing order
## told how long ago it fired (negative: not yet). Resetting first is what
## makes the preview a pure function of the time — scrub backwards and a
## spawned body disappears again.
func _preview_beats(now: float) -> void:
	for marker in roles():
		marker.reset_preview()
	for pair in timed_beats():
		(pair[0] as BeatNode).preview(now - float(pair[1]))


func _preview_shot() -> void:
	var rig: FramingRig = live_shot()
	if rig == null:
		return
	var camera: Camera3D = _preview_camera()
	var source: Callable = rig.editor_source()
	var eye: Vector3 = rig.position_for(source)
	var target: Vector3 = rig.look_for(source)
	camera.fov = rig.fov_degrees
	if eye.is_equal_approx(Vector3.ZERO) and target.is_equal_approx(Vector3.ZERO):
		return  # nothing on this stage answers to the shot's roles yet
	camera.global_position = eye
	if not eye.is_equal_approx(target):
		camera.look_at(target, CameraFraming.up_for(eye, target))


## The editor's copy of preview_set, rebuilt when the field changes. Only
## in the editor, and only for the scene being edited: a stage instanced
## inside something else must not drag its room along.
func _rebuild_preview_set() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	if is_instance_valid(_preview_set_node):
		_preview_set_node.queue_free()
		_preview_set_node = null
	if preview_set == null or not _in_edited_scene():
		return
	_preview_set_node = preview_set.instantiate()
	_preview_set_node.name = PREVIEW_SET_NAME
	add_child(_preview_set_node)


## Made on first use and never owned, so it is never packed.
func _preview_camera() -> Camera3D:
	if is_instance_valid(_preview):
		return _preview
	_preview = Camera3D.new()
	_preview.name = PREVIEW_NAME
	add_child(_preview)
	return _preview


func _look_through_preview() -> void:
	if not Engine.is_editor_hint():
		return
	# Looked up by name: EditorInterface does not exist in an exported
	# build, and naming the class would fail to parse there.
	var editor: Object = Engine.get_singleton(&"EditorInterface")
	if editor == null:
		return
	var selection: Object = editor.call(&"get_selection")
	selection.call(&"clear")
	selection.call(&"add_node", _preview_camera())
