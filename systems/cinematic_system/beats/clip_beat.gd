@tool
class_name ClipBeat
extends BeatNode
## Makes an actor play one of its own animation clips — a bow, a flinch, a
## pose. Claims the animator by default so gameplay does not animate over
## the shot; the director releases every claim when the scene ends.
##
## A clip can go on part of the body (layer): over the legs of whatever
## the body is doing (UPPER, a bow drawn over a walk; an UPPER beat with no
## clip lowers it again), or as a hit's recoil on top of it (FLINCH).
##
## Skipped, nothing is played. A clip is performance, not state, and the
## claim it would have taken is released at the end regardless — gameplay
## picks the actor's animation back up either way.

@export var role: StringName = &"":
	set(value):
		role = value
		_changed()
## A clip name on the actor's model's AnimationPlayer. Free text: the stage
## has no model to list clips from.
@export var animation_name: String = "":
	set(value):
		animation_name = value
		_changed()
## Hold off gameplay's own animation until the scene ends.
@export var claims: bool = true
## Where on the body. See the header.
@export var layer: BodyAnimationTree.Layer = BodyAnimationTree.Layer.BODY
## Seconds to blend in over. Below 0 = the body's own stance blend time.
@export_range(-1.0, 3.0, 0.05, "suffix:s") var blend: float = -1.0


func _validate_property(property: Dictionary) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage and property.name == "role":
		_suggest_names(property, owner_stage.role_names())


func _fire(owner_stage: CinematicStage) -> void:
	owner_stage.clip(role, animation_name, claims, layer, blend)


## The clip on the role's preview body (StageRole.preview_unit), held on
## its last frame once it has played through. BODY layer only: the editor
## has no layered tree to put an UPPER or FLINCH clip over the legs with.
func preview(seconds_since_fire: float) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage == null or seconds_since_fire < 0.0 or layer != BodyAnimationTree.Layer.BODY:
		return
	_preview_clip(owner_stage, role, animation_name, seconds_since_fire)


func _beat_warnings(owner_stage: CinematicStage) -> PackedStringArray:
	var warnings := PackedStringArray()
	_check_role(warnings, owner_stage, "role", role)
	if animation_name == "" and layer != BodyAnimationTree.Layer.UPPER:
		warnings.append("'animation_name' is empty.")
	return warnings
