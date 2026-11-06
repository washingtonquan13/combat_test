@tool
class_name BeatNode
extends Node
## Something that HAPPENS in a cutscene — a line, a walk, a spawn — as a
## node under the stage's Beats/ holder. The base class; each kind of beat
## is a subclass in beats/.
##
## A NODE, NOT A METHOD-KEY ARGUMENT LIST. A method key can only carry
## strings and numbers, typed blind into the track editor; a beat node
## carries real exported fields (dropdowns, resource pickers) that the
## inspector can check. The timeline fires it with a Call Method key whose
## path is this node and whose method is fire(), with no arguments — picked
## from a list, nothing typed. One track per beat: two keys at one time on
## one track is the epsilon-replace trap the stage warns about.
##
## THE ENTRY POINTS, one per situation a beat can be in. The public ones
## are final here and guard the editor and an unbound stage once, so a
## subclass implements only the underscored hooks:
##
##   fire()       -> _fire()    the timeline reached the key. Do the
##                              thing, visuals and all. Must not await: it
##                              runs inside the player's own process step.
##                              Work that spans frames calls stage.run(self)
##                              and is then ticked.
##   tick(delta)                a running beat's frame. Return false when
##                              done. The scene is not over while any beat
##                              is running (CinematicStage.is_running).
##   finish()     -> _finish()  the scene is ending early while this beat
##                              is still running: land where it was going.
##   skip()       -> _skip()    the scene skipped (or was settled by an
##                              abort) before the key was reached. Apply
##                              the END STATE only — the body exists, the
##                              body is gone, the actor is on the mark —
##                              with no visuals and no sound. Called in
##                              timeline order by skip_to_end().
##   preview(t)                 the editor is scrubbing; `t` is seconds
##                              since this beat's key (negative: not yet).
##                              Show the state on the StageRole STAND-INS
##                              (StageRole.stand_in()), never on anything
##                              saved. The stage resets every stand-in and
##                              then previews beats in firing order, so a
##                              beat only ever expresses "what does time t
##                              look like", starting from where the earlier
##                              beats left the stand-ins.
##
## A beat holds no fire time of its own. It reads it off the timeline
## (fire_time()), so dragging the key is the only way to re-time it and
## the two cannot disagree. It DOES record whether it has fired, because
## that — not a comparison of times — is what skip_to_end() needs to know.
##
## Role and mark fields are offered as dropdowns of what the stage has
## (_suggest_names), and a name the stage lacks is a configuration warning
## (_check_role/_check_spot). A subclass lists its own problems in
## _beat_warnings().

var _fired: bool = false


func fire() -> void:
	var owner_stage: CinematicStage = _live_stage()
	if owner_stage == null:
		return
	_fired = true
	_fire(owner_stage)


func skip() -> void:
	var owner_stage: CinematicStage = _live_stage()
	if owner_stage == null:
		return
	_fired = true
	_skip(owner_stage)


func finish() -> void:
	var owner_stage: CinematicStage = _live_stage()
	if owner_stage:
		_finish(owner_stage)


func has_fired() -> bool:
	return _fired


func tick(_delta: float) -> bool:
	return false


func preview(_seconds_since_fire: float) -> void:
	pass


func _fire(_stage: CinematicStage) -> void:
	pass


func _skip(_stage: CinematicStage) -> void:
	pass


func _finish(_stage: CinematicStage) -> void:
	pass


## The stage this beat belongs to (Beats/ is a direct child of it), or
## null when the beat is not under one.
func stage() -> CinematicStage:
	var holder: Node = get_parent()
	return holder.get_parent() as CinematicStage if holder else null


## When the timeline fires this beat, or -1 if nothing keys it.
func fire_time() -> float:
	var owner_stage: CinematicStage = stage()
	return owner_stage.fire_time_of(self) if owner_stage else -1.0


## The stage, if this is a real performance: not the editor, and bound to
## a cast. The one guard every runtime entry point goes through.
func _live_stage() -> CinematicStage:
	if Engine.is_editor_hint():
		return null
	var owner_stage: CinematicStage = stage()
	return owner_stage if owner_stage and owner_stage.is_bound() else null


# --- Editor --------------------------------------------------------


## Offers `names` as the property's dropdown. SUGGESTION, not a closed
## enum: a world mark the stage has not declared is still a legal value,
## and the warning is where it gets questioned.
func _suggest_names(property: Dictionary, names: PackedStringArray) -> void:
	property.hint = PROPERTY_HINT_ENUM_SUGGESTION
	property.hint_string = ",".join(names)


## Roles, then everything a mark field accepts — for a field that may name
## either (a turn's target, an effect's origin).
func _role_and_spot_names(owner_stage: CinematicStage) -> PackedStringArray:
	var names: PackedStringArray = owner_stage.role_names()
	names.append_array(owner_stage.spot_names())
	return names


## A setter's second half: the warning may have changed with the value.
func _changed() -> void:
	if Engine.is_editor_hint() and is_inside_tree():
		update_configuration_warnings()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	var owner_stage: CinematicStage = stage()
	if owner_stage == null:
		warnings.append("A beat belongs under a CinematicStage's 'Beats' node.")
		return warnings
	if not owner_stage.is_keyed(self):
		warnings.append("Nothing on the Timeline fires this beat — add a Call Method track on this node with a key calling fire().")
	warnings.append_array(_beat_warnings(owner_stage))
	return warnings


func _beat_warnings(_stage: CinematicStage) -> PackedStringArray:
	return PackedStringArray()


func _check_role(warnings: PackedStringArray, owner_stage: CinematicStage,
		field: String, value: StringName) -> void:
	if value == &"":
		warnings.append("'%s' is empty." % field)
	elif owner_stage.role_marker(value) == null:
		warnings.append("'%s' names role '%s', which has no StageRole under Roles/." % [field, value])


## `optional` for a field whose empty value means something ("at the same
## place", "where it already is").
func _check_spot(warnings: PackedStringArray, owner_stage: CinematicStage,
		field: String, value: StringName, optional: bool = false) -> void:
	if value == &"":
		if not optional:
			warnings.append("'%s' is empty." % field)
	elif not owner_stage.knows_spot(value):
		warnings.append("'%s' names '%s': not a role, not under Marks/, and not in the stage's world_marks."
			% [field, value])


# --- Preview helpers -----------------------------------------------


## The stand-in for `role`, or null.
func _stand_in(owner_stage: CinematicStage, role: StringName) -> Node3D:
	var marker: StageRole = owner_stage.role_marker(role)
	return marker.stand_in() if marker else null


## Where `spot_name` is in the editor: a role's stand-in (as the earlier
## beats left it) or a stage mark. Null for a world mark, which only exists
## in an area — a beat aimed at one simply does not preview its movement.
func _preview_spot(owner_stage: CinematicStage, spot_name: StringName) -> Node3D:
	if spot_name == &"":
		return null
	var local: Node3D = owner_stage.local_mark(spot_name)
	if local:
		return local
	return _stand_in(owner_stage, spot_name)


## Turns a stand-in to face `point` on the ground plane. A stand-in has no
## facing offset — that is a property of a real model's rig.
func _preview_face(body: Node3D, point: Vector3) -> void:
	var flat := Vector3(point.x, body.global_position.y, point.z)
	if body.global_position.distance_squared_to(flat) > 0.0001:
		body.look_at(flat, Vector3.UP)
