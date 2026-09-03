class_name ActorClipStep
extends SceneStep
## Makes an actor do something.
##
## The gap this closes was the difference between a staging system and a
## cutscene system. Before it, a scene could move bodies between marks and
## point a camera at them, and that was all — every scene was statues
## sliding around while the camera did the work.
##
## CLAIMS THE ACTOR BY DEFAULT. Gameplay animates units reactively: taking
## damage plays a hit clip, moving plays a walk, arming an ability plays a
## pose. Any of those landing mid-performance replaces the clip out from
## under the shot, and nothing reports it — the animation simply changes
## and the scene looks wrong rather than broken. The claim is released by
## the director when the scene ends, however it ends.
##
## Death is NOT suppressed by the claim. See UnitAnimator's own note: an
## actor that dies and keeps standing is a worse lie than an interrupted
## performance.

@export var role: StringName = &""
@export var animation_name: String = ""
## False for a clip a scene is happy to have interrupted — a background
## actor idling, say, where a hit reaction is more truthful than the pose.
@export var claims_actor: bool = true


func apply(cast: SceneCast) -> void:
	if role == &"" or animation_name == "":
		return
	var actor: Unit = cast.unit(role)
	if actor == null:
		return
	var animator: UnitAnimator = actor.animator()
	if animator == null:
		# A body with no animator is a normal state — a bodiless unit, or a
		# model that brought no AnimationPlayer. The scene carries on.
		return
	if claims_actor:
		animator.claim_for_cutscene()
		cast.note_claim(actor)
	animator.play_cutscene_clip(animation_name)


func describe() -> String:
	return "'%s' plays %s at %.2fs" % [role, animation_name, offset]
