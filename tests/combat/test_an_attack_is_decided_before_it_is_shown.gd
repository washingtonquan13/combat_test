extends AiTestCase
## An ability use is decided before anyone sees it, and always finishes.
##
## UnitCombat rolls everything up front and hands presentation an
## AbilityAction (Unit.current_action) at ability_use_started. An
## ability that waits for impact lands exactly what was rolled then —
## when the projectile arrives, or at the timeout if nothing ever
## signals — and a target killed during the wait takes nothing.


func wants_world() -> bool:
	return true


func run() -> void:
	var caster: Unit = spawn_unit(&"player", 10, 10, 20, [], Vector3.ZERO)
	var target: Unit = spawn_unit(&"player", 10, 10, 200, [], Vector3(0, 0, -4))
	await get_tree().process_frame

	var missile: Ability = load("res://data/abilities/magic_missile.tres")
	var planned := [-1]
	var grab := func(_a, _t, _ab): planned[0] = caster.current_action.planned_damage() if caster.current_action else -1
	caster.ability_use_started.connect(grab)

	var hp: int = target.get_pool(StatIds.HP)
	var result: Dictionary = await caster.use_ability(missile, target)
	check("the missile lands what was rolled before it flew",
		planned[0] > 0 and hp - target.get_pool(StatIds.HP) == planned[0] and not result.has("impact_timed_out"),
		"planned %d, took %d" % [planned[0], hp - target.get_pool(StatIds.HP)])
	check("the action is let go once it finishes", caster.current_action == null)

	# Nothing in the cast ever signals impact: the timeout lands it.
	var silent: Ability = missile.duplicate()
	silent.cast_vfx = null
	silent.timing = missile.timing.duplicate()
	silent.timing.impact_timeout = 0.2
	caster.reset_turn_actions()
	hp = target.get_pool(StatIds.HP)
	result = await caster.use_ability(silent, target)
	check("with no impact signal, the timeout still lands it",
		result.get("impact_timed_out", false) and hp - target.get_pool(StatIds.HP) == planned[0],
		"timed out %s, planned %d, took %d" % [result.get("impact_timed_out", false), planned[0], hp - target.get_pool(StatIds.HP)])

	# The target dies while the attack is still in the air.
	caster.reset_turn_actions()
	var used := [false]
	caster.ability_used.connect(func(_a, _t, _r): used[0] = true, CONNECT_ONE_SHOT)
	get_tree().create_timer(0.05).timeout.connect(func(): target.take_damage(5000))
	result = await caster.use_ability(silent, target)
	check("a target killed mid-flight takes nothing, and the use still ends",
		result.get("target_lost", false) and result.damage == 0 and result.effects.is_empty() and used[0] and caster.current_action == null,
		str(result))

	caster.ability_use_started.disconnect(grab)
	free_spawned()
