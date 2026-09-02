extends AiTestCase
## The turn structure around a plan, not the plan itself. A free ability
## must not cost the turn — the bug that made a flyer choose between
## landing safely and doing anything at all, and pick the fall.


func run() -> void:
	_land_is_free()
	_landing_leaves_the_turn_intact()
	_combat_ai_respects_free_actions()


func _land_is_free() -> void:
	var land: Ability = load("res://data/abilities/land.tres")
	check("land.tres spends no attack action", not land.uses_attack_action)
	check_equalf("land.tres spends no movement", land.move_cost, 0.0)
	check_equalf("land.tres spends no FP", land.fp_cost, 0.0)


func _landing_leaves_the_turn_intact() -> void:
	var avian: Unit = spawn_demon("avian", Vector3(0.0, 8.0, 0.0), true, 2)
	if not avian.is_flying():
		check("SKIP guard: flying status applied", false, "is_flying() false")
		free_spawned()
		return
	var brute: Unit = spawn_brute(3.0)

	avian.use_ability(load("res://data/abilities/land.tres"), avian)

	check("after landing, the attack action is still unspent", not avian.has_attacked)
	check("after landing, movement is still unspent", avian.has_move_remaining(),
		"%.1f left" % avian.move_remaining)
	free_spawned()


## The economy above is only useful if CombatAI actually exploits it. It
## used to call end_turn() unconditionally after any ability, throwing the
## rest of the turn away and turning a free action into a wasted one.
##
## Single-token source matches only, deliberately. A multi-line match
## would depend on this repo's CRLF line endings and fail for reasons that
## have nothing to do with whether the code is right — which is exactly
## what happened to the first version of this suite.
func _combat_ai_respects_free_actions() -> void:
	var source: String = FileAccess.get_file_as_string("res://systems/combat_system/combat_ai.gd")
	check("CombatAI checks uses_attack_action before ending the turn",
		source.contains("plan.ability.uses_attack_action") and source.contains("if spends_turn:"))
	check("CombatAI re-asks for a plan after a free action",
		source.contains("_on_free_action_finished"))
	check("and caps that loop so a repeatable free ability cannot spin",
		source.contains("MAX_FREE_ACTIONS_PER_TURN"))
