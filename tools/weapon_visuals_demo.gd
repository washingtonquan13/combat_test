extends "res://tools/weapons_demo.gd"
## Recorded walkthrough of weapon visuals — NOT a test. Each attack row
## plays its own clip with the weapon in hand; a melee hit lands on the
## clip's impact key, a shot leaves on its release key and lands when
## the arrow, bolt, axe or bullet arrives, the defender dodges, parries
## or blocks as the roll said, every round of rapid fire is its own
## shot, and the attacker holds the turn through its recovery and a
## short gap. Every attack logs use / release / impact / damage / idle
## times from the use. Record it the same way as item_layer_demo.

## Hand slots: MAIN, OFF and RANGED come from weapons_demo.

## Game seconds, not wall time: under Movie Maker's fixed fps the two
## drift apart, and the timings are about what the game shows.
var _clock: float = 0.0


func _process(delta: float) -> void:
	_clock += delta


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	for key in [MAIN, OFF, RANGED, EquipSlot.Slot.RANGED_OFF_HAND]:
		if _hero.get_equipped_item(key):
			_hero.unequip_item(key)
	_hero.set_base_stat(StatIds.DX, 16)
	SelectionManager.select(_hero)
	await _wait(1.0)

	await _sword_hits_on_its_key()
	await _defense_matches_the_roll()
	await _bow_swaps_and_shoots()
	await _flights()
	await _pistol_one_hit_per_round()
	await _claws_play_their_own_clip()

	var total := _passed + _failed.size()
	_say("Done: %d/%d checks passed" % [_passed, total])
	print("DEMO RESULT: %d/%d passed" % [_passed, total])
	for f in _failed:
		print("  FAILED: ", f)
	await _wait(2.5)
	get_tree().quit()


func _sword_hits_on_its_key() -> void:
	_say("Iron sword in hand: Swing plays its clip, the hit lands on the swing's key")
	_hero.equip_item(MAIN, ItemInstance.new(IronSword))
	var near: Unit = _dummy(-1.2, 0.0)
	await _wait(2.0)
	_check("the sword is in the hero's hand", _weapons(_hero).held_model(MAIN) != null)
	var t: Dictionary = await _timed(_attack("Swing"), near)
	_check("the clip played (%s)" % t.clip, t.clip == "Weapon/Swing")
	_check("the hit landed on the clip's key (%.2f s in), not at the start" % t.impact, t.impact >= 0.2)
	_check("damage came with the impact (%.2f s)" % t.damage, t.damage >= t.impact and t.damage < t.impact + 0.05)
	_check("the hero held the turn through recovery and the gap (idle %.2f s after the clip)" % (t.done - t.impact),
		t.done - t.impact >= _animator(_hero).turn_gap)
	_say("Thrust plays its own clip")
	await _wait(1.5)
	var thrust: Dictionary = await _timed(_attack("Thrust"), near)
	_check("Thrust plays Weapon/Thrust (%s)" % thrust.clip, thrust.clip == "Weapon/Thrust")
	await _wait(2.0)
	near.queue_free()


func _defense_matches_the_roll() -> void:
	_say("A quick defender: it dodges, parries or blocks as its roll says")
	var defender: Unit = _dummy(-1.2, 0.0)
	defender.set_base_stat(StatIds.DX, 18)
	defender.set_base_stat(StatIds.HT, 18)
	defender.equip_item(MAIN, ItemInstance.new(IronSword))
	defender.equip_item(OFF, ItemInstance.new(load("res://data/items/wooden_shield.tres")))
	await _wait(2.0)
	var seen := []
	defender.defended.connect(func(_u, kind):
		await get_tree().process_frame
		seen.append([kind, String(_animator(defender).animation_player.current_animation)]))
	for i in 6:
		_hero.reset_turn_actions()
		var t: Dictionary = await _timed(_attack("Swing"), defender)
		if t.result.has("defense") and not t.result.get("hit", true):
			_say("Defended with a %s" % t.result.defense.kind)
			break
		await _wait(0.8)
	_check("the defender defended at least once", not seen.is_empty())
	if not seen.is_empty():
		var clip := {&"dodge": "Weapon/Dodge", &"parry": "Weapon/Parry", &"block": "Weapon/Block"}
		_check("the clip matches the roll (%s -> %s)" % seen[0], seen[0][1] == clip[seen[0][0]])
	await _wait(2.5)
	defender.queue_free()


func _bow_swaps_and_shoots() -> void:
	_say("Longbow: shooting draws the bow, the sword goes away")
	var far: Unit = _dummy(-8.0, 0.0)
	_hero.equip_item(RANGED, ItemInstance.new(load("res://data/items/longbow.tres")))
	await _wait(1.5)
	var t: Dictionary = await _timed(_attack("Shoot"), far)
	_check("the bow is drawn, the sword put away",
		_weapons(_hero).held_model(RANGED) != null and _weapons(_hero).held_model(MAIN) == null)
	_check("Shoot plays Weapon/Bow_Shot (%s)" % t.clip, t.clip == "Weapon/Bow_Shot")
	_check("the arrow left on the release key (%.2f s in)" % t.release, t.release >= 0.2)
	_check("it landed when the arrow arrived (%.2f s)" % t.impact, t.impact > t.release + 0.1)
	await _wait(2.0)
	far.queue_free()


func _flights() -> void:
	var far: Unit = _dummy(-8.0, 0.0)
	_hero.unequip_item(RANGED)
	_say("Crossbow: a bolt, flatter and faster than the arrow")
	_hero.equip_item(RANGED, ItemInstance.new(load("res://data/items/crossbow.tres")))
	await _wait(1.5)
	var bolt: Dictionary = await _timed(_attack("Shoot"), far)
	_check("Crossbow plays Weapon/Crossbow_Shot, bolt lands after release",
		bolt.clip == "Weapon/Crossbow_Shot" and bolt.impact > bolt.release and bolt.release >= 0.0)
	await _wait(2.0)
	_hero.unequip_item(RANGED)
	_hero.unequip_item(MAIN)
	_say("Throwing axe: thrown end over end, and still in hand after")
	_hero.equip_item(MAIN, ItemInstance.new(load("res://data/items/throwing_axe.tres")))
	await _wait(1.5)
	var axe: Dictionary = await _timed(_attack("Throw"), far)
	_check("Throw plays Weapon/Throw, the axe lands after release",
		axe.clip == "Weapon/Throw" and axe.impact > axe.release and axe.release >= 0.0)
	await _wait(2.0)
	far.queue_free()


func _pistol_one_hit_per_round() -> void:
	_say("Pistol, RoF 3: three rounds, each its own flash, tracer and hit")
	var far: Unit = _dummy(-8.0, 0.0)
	_hero.equip_item(RANGED, ItemInstance.new(load("res://data/items/pistol.tres")))
	await _wait(1.5)
	var t: Dictionary = await _timed(_attack("Shoot"), far)
	_check("Shoot plays Weapon/Pistol_Shot (%s)" % t.clip, t.clip == "Weapon/Pistol_Shot")
	_check("three rounds released, one per key (%s)" % str(t.releases), t.releases.size() == 3)
	var hits: int = t.result.get("hits", 0) if t.result.get("hit", false) else 0
	_check("damage came once per hit, as each round arrived (%d hits, %d damage moments)" % [hits, t.damages.size()],
		t.damages.size() == hits)
	if t.damages.size() >= 2:
		_check("the hits are spread over the rounds, not all at once", t.damages[-1] - t.damages[0] >= 0.1)
	await _wait(2.5)
	far.queue_free()


func _claws_play_their_own_clip() -> void:
	_say("A clawed beast, bare-handed: its claws play their own clip")
	var beast: Unit = _dummy(-1.2, 0.0)
	beast.abilities.append(load("res://data/abilities/basic_attack_melee.tres"))
	beast.natural_attacks.append(load("res://data/attacks/claws.tres"))
	var target: Unit = _dummy(-2.4, 0.0)
	await _wait(1.5)
	var claws: Ability = null
	for a in beast.combat_abilities():
		if a.ability_name == "Claws":
			claws = a
	_check("the beast is offered Claws", claws != null)
	if claws:
		var t: Dictionary = await _timed(claws, target, beast)
		_check("Claws plays Weapon/Claw (%s)" % t.clip, t.clip == "Weapon/Claw")
	await _wait(2.5)
	beast.queue_free()
	target.queue_free()


## Uses the ability and returns when each moment came, in seconds from
## the use: "release"/"impact" the first, "releases"/"damages" every
## one, "done" when the attacker is idle again, plus the clip it played
## and the use's result.
func _timed(ability: Ability, target, attacker: Unit = null) -> Dictionary:
	if attacker == null:
		attacker = _hero
	attacker.reset_turn_actions()
	var t := {"release": -1.0, "impact": -1.0, "damage": -1.0, "done": -1.0,
		"releases": [], "damages": [], "clip": "", "result": {}}
	var start := [_clock]
	var now := func() -> float: return _clock - start[0]
	var on_start := func(_a, _t, _ab):
		start[0] = _clock
		attacker.current_action.impacted.connect(func():
			if t.impact < 0.0:
				t.impact = now.call())
		await get_tree().process_frame
		t.clip = String(_animator(attacker).animation_player.current_animation)
	var on_release := func(_action):
		t.releases.append(now.call())
		if t.release < 0.0:
			t.release = now.call()
	var on_damage := func(_u, _amount, _source = null):
		t.damages.append(now.call())
		if t.damage < 0.0:
			t.damage = now.call()
	attacker.ability_use_started.connect(on_start)
	attacker.cast_released.connect(on_release)
	if target is Unit:
		target.took_damage.connect(on_damage)
	t.result = await attacker.use_ability(ability, target)
	while attacker.is_busy():
		await get_tree().process_frame
	t.done = now.call()
	attacker.ability_use_started.disconnect(on_start)
	attacker.cast_released.disconnect(on_release)
	if target is Unit:
		target.took_damage.disconnect(on_damage)
	_say("%s: %s, release %.2f s, impact %.2f s, damage %s, idle %.2f s"
		% [ability.ability_name, t.clip, t.release, t.impact, str(t.damages), t.done])
	print("[timing] %s %s release=%.2f impact=%.2f damages=%s done=%.2f releases=%s"
		% [ability.ability_name, t.clip, t.release, t.impact, str(t.damages), t.done, str(t.releases)])
	return t


func _animator(unit: Unit) -> UnitAnimator:
	return unit.get_node("UnitAnimator") as UnitAnimator


func _weapons(unit: Unit) -> UnitWeapons:
	return unit.get_node("UnitWeapons") as UnitWeapons
