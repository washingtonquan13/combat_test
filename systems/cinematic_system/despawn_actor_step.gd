class_name DespawnActorStep
extends SceneStep
## Takes an actor off the screen mid-scene.
##
## The fusion cutscene's fourth beat: the two parent demons dissolve. What
## makes this worth a step rather than a line of gameplay code is the
## ORDER — DemonRoster.release() consumes them as roster entries the moment
## the fusion is confirmed, and they have to stay on screen for several
## beats after that. A tracked role would already be resolving to null by
## the time this ran, which is exactly why the cast distinguishes held
## roles from tracked ones.
##
## The visual dissolve is a VfxEffect the scene plays alongside this. The
## two techniques that beat actually needs — lightning, and dissolving a
## mesh into particles — were identified in the 2026-08-26 asset audit as
## genuinely new shader work rather than a reuse-and-assemble job, so this
## removes the actor and the spectacle arrives separately.

@export var role: StringName = &""
## Whether the role stops resolving too. False keeps the actor addressable
## for later beats even though it is gone from the world, which nothing
## needs yet — but "removed from the world" and "no longer in the cast" are
## genuinely different questions and collapsing them would be a guess.
@export var clears_role: bool = true


func apply(cast: SceneCast) -> void:
	if role == &"":
		return
	var leaving: Unit = cast.unit(role)
	if leaving == null:
		return
	if clears_role:
		cast.release_role(role)
	leaving.queue_free()


func describe() -> String:
	return "despawn '%s' at %.2fs" % [role, offset]
