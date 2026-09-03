extends AiTestCase
## A scene can make an actor DO something, and gameplay stops arguing with
## it while it does.
##
## Before these three step types the system could compose shots and slide
## bodies between marks, and nothing else — every scene was statues while
## the camera did the work. That is a staging system, not a cutscene one.
##
## THE CLAIM IS THE INTERESTING HALF. Gameplay animates units reactively:
## damage plays a hit clip, movement plays a walk, arming plays a pose. Any
## of those landing mid-performance replaces the clip out from under the
## shot and NOTHING REPORTS IT — the animation just changes, and the scene
## reads as badly directed rather than as broken. That is the failure this
## suite exists to catch, because no other kind of test would.

const CLIP := "Idle"


func run() -> void:
	var actor: Unit = spawn_brute(0.0, 0.0)
	await get_tree().process_frame

	var animator: UnitAnimator = actor.animator()
	check("SETUP: the actor has an animator to direct",
		animator != null,
		"no UnitAnimator, so nothing below tests anything")
	if animator == null:
		return

	var cast := SceneCast.new().track_unit(&"actor", actor)
	cast.tree = get_tree()

	# --- a scene can direct a performance --------------------------------
	var clip := ActorClipStep.new()
	clip.role = &"actor"
	clip.animation_name = CLIP
	clip.apply(cast)

	check("a scene can make an actor play a clip",
		animator.is_claimed_for_cutscene(),
		"the step ran but never claimed the actor")

	# --- and gameplay stops arguing --------------------------------------
	# ASSERTED ON THE ANIMATION, not on the claim flag. The first version of
	# this checked that is_claimed_for_cutscene() was still true after
	# damage — which removing the guard does not change, so the check could
	# not fail and sabotaging it left the suite green. What a lost claim
	# actually looks like is the CLIP changing.
	var performing: String = animator.animation_player.current_animation
	check("SETUP: the performance clip is actually playing",
		performing != "",
		"nothing is playing, so a hit reaction has nothing to interrupt")
	check("SETUP: and the rig has a hit clip that could interrupt it",
		animator.animation_player.has_animation(animator.hit_animation),
		"no '%s' on this rig — the sabotage below would pass for the " % animator.hit_animation +
		"wrong reason, because there is nothing to replace it with")

	actor.took_damage.emit(actor, 5)
	check("a hit reaction does not replace the performance",
		animator.animation_player.current_animation == performing,
		"the clip changed from '%s' to '%s' — gameplay animated over the " % [
			performing, animator.animation_player.current_animation] +
		"shot, and nothing would have reported it")

	# --- death is deliberately still allowed through ----------------------
	check("but death is not suppressed",
		_death_is_ungated(),
		"the claim swallows the death animation too, which leaves a unit " +
		"standing after it dies — a worse lie than an interrupted shot")

	# --- and the director always hands the actor back ---------------------
	await _the_actor_is_given_back_however_the_scene_ends(actor, animator)

	# --- the other two steps decline rather than throw --------------------
	var effect := SceneEffectStep.new()
	effect.from_role = &"actor"
	effect.apply(cast)
	var sound := SceneSoundStep.new()
	sound.at_role = &"actor"
	sound.apply(cast)
	check("an effect and a sound step with nothing assigned do nothing quietly",
		true,
		"reaching this line at all is the assertion — neither threw")


## The claim must survive a scene being ABORTED, not just finishing. An
## actor left claimed is a unit that never reacts to being hit again, for
## the rest of the session, and nothing would ever report it.
func _the_actor_is_given_back_however_the_scene_ends(actor: Unit, animator: UnitAnimator) -> void:
	var clip := ActorClipStep.new()
	clip.role = &"actor"
	clip.animation_name = CLIP

	var beat := ScenePhase.new()
	beat.duration_seconds = 30.0
	beat.steps = [clip]
	var scene := CinematicScene.new()
	scene.id = &"test_performance"
	scene.phases = [beat]

	var cast := SceneCast.new().track_unit(&"actor", actor)
	CinematicDirector.play(scene, cast)
	await get_tree().process_frame
	check("SETUP: the scene claimed the actor",
		animator.is_claimed_for_cutscene(),
		"nothing was claimed, so releasing it proves nothing")

	CinematicDirector.abort()
	var spent: int = 0
	while CinematicDirector.is_active() and spent < 600:
		await get_tree().process_frame
		spent += 1

	check("an aborted scene still hands the actor back",
		not animator.is_claimed_for_cutscene(),
		"the actor is still claimed after the scene was cut short — it " +
		"will never react to anything again")


## Reads the source rather than triggering a death, which would tear down
## the unit this suite is still using.
func _death_is_ungated() -> bool:
	var file := FileAccess.open("res://systems/unit_system/unit_animator.gd", FileAccess.READ)
	if file == null:
		return false
	var text: String = file.get_as_text()
	file.close()
	var at: int = text.find("func _on_died")
	if at == -1:
		return false
	return not text.substr(at, 160).contains("_cutscene_claimed")
