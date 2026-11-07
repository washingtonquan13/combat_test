@tool
class_name SilhouetteBeat
extends BeatNode
## Paints an actor one flat colour, or takes the paint off again.
##
## Fusion's two hand-made effects that need a BODY rather than a prop: the
## parents going black before they break apart, and the result arriving as
## a white shape before its colours come back. Both are the same thing, a
## flat unlit colour laid over every mesh of the model, so they are one
## beat with a colour rather than two effects.
##
## HOW IT WORKS, in one line: every MeshInstance3D under the unit's
## CharacterModel gets `material_overlay` set to an unshaded material of
## `color`. Opaque, so it hides the model's own colours completely; clear
## sets the overlay back to nothing. The selection outline and the ground
## ring are not under CharacterModel and are left alone.
##
## Skipped, the beat still applies: a skipped scene must not leave the
## result painted white, so a clear is state, not decoration.

@export var role: StringName = &"":
	set(value):
		role = value
		_changed()
## The flat colour. Alpha below 1 lets the model show through.
@export var color: Color = Color.BLACK
## Take the paint off instead of putting it on. `color` is ignored.
@export var clear: bool = false


func _validate_property(property: Dictionary) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage and property.name == "role":
		_suggest_names(property, owner_stage.role_names())


func _fire(owner_stage: CinematicStage) -> void:
	_paint(owner_stage)


func _skip(owner_stage: CinematicStage) -> void:
	_paint(owner_stage)


func _paint(owner_stage: CinematicStage) -> void:
	var actor: Unit = owner_stage.actor(role)
	if actor == null:
		push_warning("SilhouetteBeat '%s': nobody is playing '%s'." % [name, role])
		return
	var model: Node = actor.get_node_or_null("CharacterModel")
	if model == null:
		return
	var paint: Material = null if clear else overlay_for(color)
	for mesh in model.find_children("*", "MeshInstance3D", true, false):
		(mesh as MeshInstance3D).material_overlay = paint


## The material a silhouette lays over a mesh. Shared with StageRole's
## stand-in so the editor preview and the game paint the same way.
static func overlay_for(paint_color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = paint_color
	if paint_color.a < 1.0:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material


## The stand-in takes the colour from the key onward. A clear beat paints
## nothing, which is what the stand-in already looks like after the stage
## resets it, so a later clear undoes an earlier paint in the preview too.
func preview(seconds_since_fire: float) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage == null or seconds_since_fire < 0.0:
		return
	var marker: StageRole = owner_stage.role_marker(role)
	if marker:
		marker.paint_stand_in(Color(0, 0, 0, 0) if clear else color)


func _beat_warnings(owner_stage: CinematicStage) -> PackedStringArray:
	var warnings := PackedStringArray()
	_check_role(warnings, owner_stage, "role", role)
	return warnings
