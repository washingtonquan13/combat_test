extends AiTestCase
## A flying body looks like it is flying, from the push off the ground to
## the touch back down onto it.
##
## The clips come from the BODY (CharacterModel's Flight Animation group),
## the moments from two Unit signals: took_off from GrantFlightEffect and
## touched_down from the end of UnitMovement.land's descent. The descent is
## the subtle part: the flying status is gone before it starts, so a body
## that went by is_flying() alone would stand in mid-air on the way down.
##
## Reads UnitAnimator's _base_animation deliberately, as the body-animation
## suites already do: what a finished one-shot falls back to is the state
## under test, and it is not visible from outside until a clip ends.


func run() -> void:
	await _lifts_hovers_glides_and_lands()
	await _spawned_flying_hovers_without_a_takeoff()


func _lifts_hovers_glides_and_lands() -> void:
	var fly: Ability = load("res://data/abilities/fly.tres")
	var unit: Unit = spawn_unit(&"player", 12, 12, 20, [melee(), fly], Vector3.ZERO)
	await get_tree().process_frame
	var animator: Node = unit.get_node("UnitAnimator")
	var player: AnimationPlayer = animator.animation_player

	check("SETUP: the body names its flight clips",
		animator.takeoff_animation == "Flight/Takeoff" and animator.fly_idle_animation == "Flight/Hover",
		"takeoff=%s hover=%s" % [animator.takeoff_animation, animator.fly_idle_animation])
	check("SETUP: every flight clip is in the body's library",
		player.has_animation("Flight/Takeoff") and player.has_animation("Flight/Hover")
			and player.has_animation("Flight/Fly_Fwd") and player.has_animation("Flight/Land"))
	check("on the ground it idles", player.current_animation == "Idle", player.current_animation)

	unit.set_base_stat(StatIds.FP, 20 - floori(unit.get_stat(StatIds.HT)))
	unit.set_pool(StatIds.FP, 20)
	var used: Dictionary = await unit.use_ability(fly, unit)
	check("SETUP: Fly was really used", unit.is_flying(), str(used))
	check("flying, the Fly toggle is on", fly.is_on_for(unit))
	check("taking off plays the takeoff, with no cast clip first", player.current_animation == "Flight/Takeoff",
		player.current_animation)
	check("and it rests on the hover after", animator._base_animation == "Flight/Hover",
		animator._base_animation)
	check("the climb waits for the push off the ground",
		is_equal_approx(unit.global_position.y, 0.0), "y=%.2f" % unit.global_position.y)

	await get_tree().create_timer(1.2).timeout
	check("up in the air it hovers", player.current_animation == "Flight/Hover",
		player.current_animation)
	check("SETUP: it really climbed", unit.global_position.y > 1.5, "y=%.2f" % unit.global_position.y)

	unit.movement_started.emit(unit)
	check("moving in the air glides, not jogs", player.current_animation == "Flight/Fly_Fwd",
		player.current_animation)
	unit.movement_finished.emit(unit)
	check("stopping in the air goes back to the hover", player.current_animation == "Flight/Hover",
		player.current_animation)

	var fp_before: int = unit.get_pool(StatIds.FP)
	unit.use_ability(fly, unit)
	check("using Fly again lands, and the toggle is off", not unit.is_flying() and not fly.is_on_for(unit))
	check("landing costs no FP", unit.get_pool(StatIds.FP) == fp_before,
		"%d -> %d" % [fp_before, unit.get_pool(StatIds.FP)])
	check("landing comes down in the hover, with no cast clip",
		player.current_animation == "Flight/Hover", player.current_animation)
	unit.movement_finished.emit(unit)
	check("on the way down it still hovers, though no longer 'flying'",
		player.current_animation == "Flight/Hover", player.current_animation)

	await get_tree().create_timer(1.2).timeout
	check("SETUP: it reached the ground", unit.global_position.y < 0.05, "y=%.2f" % unit.global_position.y)
	check("touching down plays the landing",
		player.current_animation == "Flight/Land" or animator._base_animation == "Idle"
			and player.current_animation == "Idle",
		player.current_animation)
	check("and it rests on the ground idle after", animator._base_animation == "Idle",
		animator._base_animation)
	free_spawned()


func _spawned_flying_hovers_without_a_takeoff() -> void:
	var unit: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(0, 4, 0))
	await get_tree().process_frame
	var animator: Node = unit.get_node("UnitAnimator")
	var player: AnimationPlayer = animator.animation_player
	var fly: Ability = load("res://data/abilities/fly.tres")
	unit.apply_status((fly.effects[0] as GrantFlightEffect).flying_status)
	check("a flight status with no takeoff swaps idle for the hover",
		player.current_animation == "Flight/Hover" and animator._base_animation == "Flight/Hover",
		"%s / %s" % [player.current_animation, animator._base_animation])
	free_spawned()
