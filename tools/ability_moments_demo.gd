extends "res://tools/attack_flow_demo.gd"
## Recorded walkthrough of ability moments — NOT a test. The cast
## animation's own Call Method keys say when a cast lets go ("release")
## and, for Jump, when it lands its effect ("impact"); the projectile and
## the cast VFX wait for them. A hit mid wind-up lets the cast go at
## once, and an ability with no animation lets go at the start. Every
## step logs use / release / impact / done times from the use. Record it
## the same way as item_layer_demo.

const Jump: Ability = preload("res://data/abilities/jump.tres")


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	SelectionManager.select(_hero)
	await _wait(1.0)

	await _missile_waits_for_release()
	await _fireball_waits_for_release()
	await _jump_takes_off_on_its_key()
	await _hit_mid_wind_up_releases()
	await _no_animation_releases_at_once()

	var total := _passed + _failed.size()
	_say("Done: %d/%d checks passed" % [_passed, total])
	print("DEMO RESULT: %d/%d passed" % [_passed, total])
	for f in _failed:
		print("  FAILED: ", f)
	await _wait(2.5)
	get_tree().quit()


func _missile_waits_for_release() -> void:
	var dummy: Unit = _dummy(-8.0, 0.0)
	_say("Magic Missile: the missile leaves on the cast clip's release key")
	await _wait(2.0)
	var t: Dictionary = await _timed(Missile, dummy)
	_check("released after the wind-up (%.2f s in)" % t.release, t.release >= 0.15)
	_check("it landed after the release", t.impact > t.release)
	_check("the cast finished", t.done >= t.impact and not _hero.is_busy())
	await _wait(3.0)
	dummy.queue_free()


func _fireball_waits_for_release() -> void:
	var dummy: Unit = _dummy(-10.0, 0.0)
	_say("Fireball: the ball leaves on its Cast clip's release key")
	await _wait(2.0)
	var t: Dictionary = await _timed(Fireball, _spot(-10.0, 0.0))
	_check("released after the wind-up (%.2f s in)" % t.release, t.release >= 0.25)
	_check("it exploded after the release", t.impact > t.release)
	_check("the cast finished", t.done >= t.impact and not _hero.is_busy())
	await _wait(3.0)
	dummy.queue_free()


func _jump_takes_off_on_its_key() -> void:
	_say("Jump: the take-off waits for the crouch's impact key")
	await _wait(2.0)
	var from: Vector3 = _hero.global_position
	var t: Dictionary = await _timed(Jump, _spot(-4.0, 0.0))
	_check("took off after the crouch (%.2f s in)" % t.impact, t.impact >= 0.2)
	_check("the jump moved the unit", _hero.global_position.distance_to(from) > 2.0)
	_check("the jump finished", not _hero.is_busy())
	await _wait(3.0)


func _hit_mid_wind_up_releases() -> void:
	var dummy: Unit = _dummy(-8.0, 0.0)
	_say("A hit mid wind-up: the cast lets go at once and still finishes")
	await _wait(2.0)
	var hit_at := [-1.0]
	var start := [0]
	_hero.ability_use_started.connect(func(_a, _t, _ab):
		start[0] = Time.get_ticks_msec()
		get_tree().create_timer(0.05).timeout.connect(func():
			hit_at[0] = (Time.get_ticks_msec() - start[0]) / 1000.0
			_hero.take_damage(1)), CONNECT_ONE_SHOT)
	var t: Dictionary = await _timed(Missile, dummy)
	_check("released on the hit (hit %.2f s, release %.2f s)" % [hit_at[0], t.release],
		hit_at[0] >= 0.0 and t.release >= hit_at[0] and t.release < hit_at[0] + 0.1)
	_check("the cast still finished", t.done >= 0.0 and not _hero.is_busy())
	await _wait(3.0)
	dummy.queue_free()


func _no_animation_releases_at_once() -> void:
	var dummy: Unit = _dummy(-8.0, 0.0)
	_say("An ability with no cast animation lets go at the start")
	await _wait(2.0)
	var bare: Ability = Missile.duplicate()
	bare.plays_cast_animation = false
	var t: Dictionary = await _timed(bare, dummy)
	_check("released at the start (%.2f s in)" % t.release, t.release >= 0.0 and t.release < 0.05)
	_check("the cast finished", t.done >= 0.0 and not _hero.is_busy())
	await _wait(3.0)
	dummy.queue_free()


## Uses the ability and returns when each moment came, in seconds from
## the use (-1 if it never did); "done" is when the unit is idle again.
func _timed(ability: Ability, target) -> Dictionary:
	var t := {"release": -1.0, "impact": -1.0, "done": -1.0}
	var start := [0]
	var stamp := func(key: String):
		t[key] = (Time.get_ticks_msec() - start[0]) / 1000.0
	# The action's own impacted signal: Unit.impact_triggered comes only
	# after the waiting use_ability has already resumed.
	var on_start := func(_a, _t, _ab):
		start[0] = Time.get_ticks_msec()
		_hero.current_action.impacted.connect(func(): stamp.call("impact"))
	var on_release := func(_action): stamp.call("release")
	_hero.ability_use_started.connect(on_start)
	_hero.cast_released.connect(on_release)
	start[0] = Time.get_ticks_msec()
	await _hero.use_ability(ability, target)
	# A jump's move keeps the unit busy after use_ability returns.
	while _hero.is_busy():
		await get_tree().process_frame
	stamp.call("done")
	_hero.ability_use_started.disconnect(on_start)
	_hero.cast_released.disconnect(on_release)
	_say("%s: release %.2f s, impact %.2f s, done %.2f s" % [ability.ability_name, t.release, t.impact, t.done])
	return t
