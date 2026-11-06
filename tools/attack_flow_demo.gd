extends "res://tools/item_layer_demo.gd"
## Recorded walkthrough of the attack flow (1bf3e4c) — NOT a test. A
## missile's damage is rolled at the cast and lands when it arrives; a
## fireball's blast is decided per unit the same way; a target killed
## mid-flight takes nothing; and a unit dying mid-action no longer ends
## the next unit's turn. Targets out of combat are same-faction dummies,
## so no fight starts. Record it the same way as item_layer_demo.

const Missile: Ability = preload("res://data/abilities/magic_missile.tres")
const Fireball: Ability = preload("res://data/abilities/explosive_fireball.tres")

var _hero: Unit


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	SelectionManager.select(_hero)
	await _wait(1.0)

	await _missile_lands_what_was_rolled()
	await _fireball_lands_what_was_rolled()
	await _target_killed_mid_flight()
	await _death_mid_action_keeps_next_turn()

	var total := _passed + _failed.size()
	_say("Done: %d/%d checks passed" % [_passed, total])
	print("DEMO RESULT: %d/%d passed" % [_passed, total])
	for f in _failed:
		print("  FAILED: ", f)
	await _wait(2.5)
	get_tree().quit()


func _missile_lands_what_was_rolled() -> void:
	var dummy: Unit = _dummy(-8.0, 0.0)
	_say("Magic Missile: the damage is rolled at the cast")
	await _wait(2.0)
	var hp: int = dummy.get_pool(StatIds.HP)
	var planned := [-1]
	var grab := func(_a, _t, _ab): planned[0] = _hero.current_action.planned_damage()
	_hero.ability_use_started.connect(grab, CONNECT_ONE_SHOT)
	var in_flight := [-1]
	# Partway through the flight: the roll is known, nothing has landed.
	get_tree().create_timer(0.25).timeout.connect(func():
		in_flight[0] = hp - dummy.get_pool(StatIds.HP)
		_say("Rolled %d at the cast. In flight: %d taken so far" % [planned[0], in_flight[0]]))
	var result: Dictionary = await _hero.use_ability(Missile, dummy)
	var taken: int = hp - dummy.get_pool(StatIds.HP)
	_check("nothing lands while the missile flies", in_flight[0] == 0)
	_check("on arrival it lands exactly the %d rolled" % planned[0], planned[0] > 0 and taken == planned[0])
	_check("it arrived (no timeout)", not result.has("impact_timed_out"))
	_say("Arrived: took %d, exactly what was rolled" % taken)
	await _wait(3.0)
	dummy.queue_free()


func _fireball_lands_what_was_rolled() -> void:
	var dummies: Array[Unit] = [_dummy(-10.0, -1.0), _dummy(-10.0, 1.0), _dummy(-11.5, 0.0)]
	var spot: Vector3 = _spot(-10.5, 0.0)
	_say("Fireball: who it catches and what each takes is decided at the cast")
	await _wait(2.0)
	var hp := dummies.map(func(d): return d.get_pool(StatIds.HP))
	var planned := {}
	var grab := func(_a, _t, _ab):
		for plan in _hero.current_action.plans:
			for entry in plan.get("affected", []):
				if entry.has("damage"):
					planned[entry.unit] = entry.damage
	_hero.ability_use_started.connect(grab, CONNECT_ONE_SHOT)
	await _hero.use_ability(Fireball, spot)
	await _wait(0.5)
	var lines: Array[String] = []
	var all_match := not planned.is_empty()
	for i in dummies.size():
		var taken: int = hp[i] - dummies[i].get_pool(StatIds.HP)
		var want: int = planned.get(dummies[i], 0)
		lines.append("%d/%d" % [taken, want])
		all_match = all_match and taken == want
	_check("each caught dummy took what was decided (%d caught)" % planned.size(), all_match)
	_say("Taken / rolled at the cast: " + ", ".join(lines))
	await _wait(3.5)
	for d in dummies:
		d.queue_free()


func _target_killed_mid_flight() -> void:
	var dummy: Unit = _dummy(-8.0, 0.0)
	_say("A target that dies while the missile is in the air")
	await _wait(2.0)
	var used := [false]
	_hero.ability_used.connect(func(_a, _t, _r): used[0] = true, CONNECT_ONE_SHOT)
	get_tree().create_timer(0.15).timeout.connect(func():
		if is_instance_valid(dummy):
			dummy.take_damage(5000)
			_say("Killed mid-flight..."))
	var result: Dictionary = await _hero.use_ability(Missile, dummy)
	_check("the dead target takes nothing", result.get("target_lost", false) and result.damage == 0)
	# The caster holds its turn through the recovery and UnitAnimator.turn_gap.
	while _hero.is_busy():
		await _hero.became_idle
	_check("the cast still finishes", used[0] and _hero.current_action == null and not _hero.is_busy())
	_say("...the missile lands on nothing, and the cast finishes cleanly")
	await _wait(3.0)


## The old bug: a unit asked to end its turn while busy queued that on
## became_idle; if it died first, its leftover end_busy ended the NEXT
## unit's turn. The next unit is player-controlled (the party joins
## too), which waits for orders, so it should still be up after the
## stale idle.
func _death_mid_action_keeps_next_turn() -> void:
	_say("A unit dies mid-action: the next unit's turn must not be skipped")
	await _wait(2.0)
	var caster: Unit = _fighter(&"player", 14, -4.0, -3.0, "Caster")
	var next: Unit = _fighter(&"player", 12, -4.0, 3.0, "Next")
	var foe: Unit = _fighter(&"enemy", 8, -14.0, 0.0, "Foe")
	# Not a party member: it dies at 0 HP instead of going Downed.
	caster.summoned_by = next
	var encounter: Encounter = CombatManager.start_combat([caster, next, foe] as Array[Unit])
	await encounter.turn_started
	_check("the caster goes first", encounter.current_unit == caster)
	await _wait(1.0)

	var slow: Ability = Missile.duplicate()
	slow.cast_vfx = null
	slow.timing = Missile.timing.duplicate()
	slow.timing.impact_timeout = 1.0
	_say("Caster fires and ends the turn while still busy...")
	caster.use_ability(slow, foe)
	await get_tree().process_frame
	CombatManager.end_turn(caster)
	await _wait(0.3)
	_say("...and dies before the attack lands")
	var after := [null]
	encounter.turn_started.connect(func(u): after[0] = u, CONNECT_ONE_SHOT)
	caster.take_damage(5000)
	await _wait(0.2)
	var heir: Unit = after[0]
	_check("the turn passes on from the dead caster", heir != null and encounter.current_unit == heir)
	# The caster's attack resolves at 1.0 s and its busy ends; before the
	# fix that ended the next unit's turn too.
	await _wait(2.0)
	_check("that unit still has its turn after the dead caster's attack resolves",
		heir != null and encounter.current_unit == heir and heir.is_my_turn())
	_say("%s still has its turn: %s" % [LogFormat.unit_name(heir) if heir else "?",
		"yes" if heir and encounter.current_unit == heir else "NO"])
	await _wait(3.0)
	if heir:
		CombatManager.end_turn(heir)
	await _wait(0.5)


## A same-faction target: hitting it starts no fight.
func _dummy(forward: float, side: float) -> Unit:
	var unit: Unit = _body()
	unit.faction = _hero.faction
	unit.set_base_stat(StatIds.HP, 300)
	unit.set_pool(StatIds.HP, 300)
	unit.global_position = _spot(forward, side)
	return unit


## A combatant whose initiative is set by DX and HT together.
func _fighter(faction: StringName, speed_stat: int, forward: float, side: float, label: String) -> Unit:
	var unit: Unit = _body()
	unit.name = label
	unit.faction = faction
	unit.set_base_stat(StatIds.DX, speed_stat)
	unit.set_base_stat(StatIds.HT, speed_stat)
	unit.set_base_stat(StatIds.HP, 60)
	unit.set_pool(StatIds.HP, 60)
	unit.global_position = _spot(forward, side)
	unit.reset_turn_actions()
	return unit


func _body() -> Unit:
	var unit: Unit = load("res://systems/unit_system/unit.tscn").instantiate()
	var definition := UnitDefinition.new()
	definition.model_scene = load("res://scenes/character_models/placeholder_model.tscn")
	unit.definition = definition
	WorldManager.spawn_parent().add_child(unit)
	return unit


func _spot(forward: float, side: float) -> Vector3:
	var right: Vector3 = _hero.visual_forward().cross(Vector3.UP)
	return _hero.global_position + _hero.visual_forward() * forward + right * side
