extends "res://tools/item_layer_demo.gd"
## Recorded walkthrough of the 11-01 combat rules — NOT a test. Damage
## types against DR, aimed Vitals/Skull, Deceptive Attack, Bloodied and
## Exhausted, worn-gear encumbrance, and Downed through to the game over
## screen. The target is a same-faction dummy in a leather chestpiece,
## so no fight starts. Record it the same way as item_layer_demo.

const Vitals: Ability = preload("res://data/abilities/target_vitals.tres")
const Head: Ability = preload("res://data/abilities/target_head.tres")
const LEVEL_NAMES: Array[String] = ["None", "Light", "Medium", "Heavy", "Extra-Heavy"]

var _hero: Unit
var _dummy: Unit


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	for key in [EquipSlot.Slot.MELEE_MAIN_HAND, EquipSlot.Slot.MELEE_OFF_HAND, EquipSlot.Slot.RANGED_MAIN_HAND, EquipSlot.Slot.RANGED_OFF_HAND]:
		if _hero.get_equipped_item(key):
			_hero.unequip_item(key)
	_hero.equip_item(EquipSlot.Slot.MELEE_MAIN_HAND, ItemInstance.new(IronSword))
	_dummy = _make_dummy(-1.2)
	_dummy.equip_item(EquipSlot.Slot.CHEST_ARMOR, ItemInstance.new(load("res://data/items/leather_chestpiece.tres")))
	SelectionManager.select(_hero)
	await _wait(1.0)

	await _damage_types()
	await _aimed_attacks()
	await _deceptive_attack()
	await _bloodied_and_exhausted()
	await _encumbrance()
	await _downed_and_game_over()

	var total := _passed + _failed.size()
	_say("Done: %d/%d checks passed" % [_passed, total])
	print("DEMO RESULT: %d/%d passed" % [_passed, total])
	for f in _failed:
		print("  FAILED: ", f)
	await _wait(3.0)
	get_tree().quit()


func _damage_types() -> void:
	var dr: int = floori(_dummy.get_stat(StatIds.DR))
	_say("Damage types: the dummy wears a leather chestpiece, DR %d" % dr)
	await _wait(2.5)
	var cr: int = DamageResolver.injury(10, _dummy, DamageResolver.WoundType.CRUSHING)
	var cut: int = DamageResolver.injury(10, _dummy, DamageResolver.WoundType.CUTTING)
	var imp: int = DamageResolver.injury(10, _dummy, DamageResolver.WoundType.IMPALING)
	_say("A roll of 10 after DR %d:  cr x1 = %d,  cut x1.5 = %d,  imp x2 = %d" % [dr, cr, cut, imp])
	_check("DR comes off first, then the wounding multiplier",
		cr == 10 - dr and cut == floori((10 - dr) * 1.5) and imp == (10 - dr) * 2)
	await _wait(4.0)
	await _strike("Swing", "Swing the sword (cut)")
	await _strike("Thrust", "Thrust (imp)")


func _aimed_attacks() -> void:
	var thrust: Ability = _attack("Thrust")
	var base: int = _hero.to_hit_target(_dummy, thrust)
	_say("Aim: Target Vitals (-3, imp x3) and Target Head (-7, skull DR +2, x4)")
	await _wait(3.0)
	_hero.set_toggled(Vitals, true)
	var vitals_skill: int = _hero.to_hit_target(_dummy, thrust)
	var vitals_hit: int = DamageResolver.injury(10, _dummy, DamageResolver.WoundType.IMPALING, 1.0, false, false, Vitals.hit_location)
	_say("Vitals: skill %d -> %d; a 10 does %d" % [base, vitals_skill, vitals_hit])
	_check("Vitals is -3 to hit", vitals_skill == base - 3)
	await _wait(3.0)
	await _strike("Thrust", "Thrust at the vitals")
	_hero.set_toggled(Head, true)
	var head_skill: int = _hero.to_hit_target(_dummy, thrust)
	var skull_hit: int = DamageResolver.injury(10, _dummy, DamageResolver.WoundType.IMPALING, 1.0, false, false, Head.hit_location)
	_check("one aim at a time: Head replaces Vitals", _hero.is_toggled(Head) and not _hero.is_toggled(Vitals))
	_check("Head is -7 to hit", head_skill == base - 7)
	_say("Head: skill %d -> %d; a 10 does %d through the skull's extra DR" % [base, head_skill, skull_hit])
	await _wait(3.5)
	await _strike("Thrust", "Thrust at the head")
	_hero.set_toggled(Head, false)


func _deceptive_attack() -> void:
	var swing: Ability = _attack("Swing")
	var skill: int = _hero.to_hit_target(_dummy, swing)
	var defense: int = _hero._combat.defense_against(_dummy, swing).target
	_say("Deceptive Attack: each level is -2 to your skill, -1 to their defense")
	await _wait(3.0)
	_hero.set_toggled(UnitCombat.DECEPTIVE_ATTACK, true)
	_hero.set_toggle_level(UnitCombat.DECEPTIVE_ATTACK, 2)
	var feint_skill: int = _hero.to_hit_target(_dummy, swing)
	var feint_defense: int = _hero._combat.defense_against(_dummy, swing).target
	_say("Level 2: skill %d -> %d, their defense %d -> %d" % [skill, feint_skill, defense, feint_defense])
	_check("level 2 is -4 to hit and -2 to defend", feint_skill == skill - 4 and feint_defense == defense - 2)
	await _wait(3.5)
	await _strike("Swing", "Swing with a level-2 feint")
	_hero.set_toggled(UnitCombat.DECEPTIVE_ATTACK, false)


func _bloodied_and_exhausted() -> void:
	var bloodied: StatusEffect = Unit.LOW_POOL_STATUSES[StatIds.HP]
	var exhausted: StatusEffect = Unit.LOW_POOL_STATUSES[StatIds.FP]
	var hp_max: int = floori(_dummy.get_stat(StatIds.HP))
	var move: float = _dummy.get_stat(StatIds.MOVE)
	var dodge: float = _dummy.get_stat(StatIds.DODGE)
	_say("Bloodied: under a third of max HP, Move and Dodge are halved")
	await _wait(2.5)
	_dummy.set_pool(StatIds.HP, hp_max / 3 - 1)
	await get_tree().process_frame
	_say("Dummy at %d/%d HP: Bloodied %s, Move %s -> %s, Dodge %s -> %s" % [_dummy.get_pool(StatIds.HP), hp_max,
		"on" if _dummy.has_status(bloodied) else "OFF", move, _dummy.get_stat(StatIds.MOVE), dodge, _dummy.get_stat(StatIds.DODGE)])
	_check("Bloodied comes on below a third", _dummy.has_status(bloodied))
	_check("Bloodied halves Move and Dodge",
		absf(_dummy.get_stat(StatIds.MOVE) - move / 2.0) <= 0.5 and absf(_dummy.get_stat(StatIds.DODGE) - dodge / 2.0) <= 0.5)
	await _wait(4.0)
	_dummy.set_pool(StatIds.HP, hp_max)
	await get_tree().process_frame
	_check("healed back over a third, it comes off", not _dummy.has_status(bloodied))

	var fp_max: int = floori(_hero.get_stat(StatIds.FP))
	var st: float = _hero.get_stat(StatIds.ST)
	_say("Exhausted: under a third of max FP — Move, Dodge and ST halved")
	await _wait(2.5)
	_hero.set_pool(StatIds.FP, fp_max / 3 - 1)
	await get_tree().process_frame
	_say("Hero at %d/%d FP: Exhausted %s, ST %s -> %s" % [_hero.get_pool(StatIds.FP), fp_max,
		"on" if _hero.has_status(exhausted) else "OFF", st, _hero.get_stat(StatIds.ST)])
	_check("Exhausted comes on and halves ST", _hero.has_status(exhausted) and absf(_hero.get_stat(StatIds.ST) - st / 2.0) <= 0.5)
	await _wait(4.0)
	_hero.set_pool(StatIds.FP, fp_max)
	await get_tree().process_frame


func _encumbrance() -> void:
	var overview: Node = get_tree().get_first_node_in_group("party_overview")
	overview.open_for(_hero)
	var move: float = _hero.get_stat(StatIds.MOVE)
	var dodge: float = _hero.get_stat(StatIds.DODGE)
	_say("Encumbrance: worn weight against Basic Lift %s lb (ST x ST / 5)" % _hero.basic_lift())
	await _wait(3.0)
	_hero.unequip_item(EquipSlot.Slot.MELEE_MAIN_HAND)
	var heavy: Array = [
		[EquipSlot.Slot.CHEST_ARMOR, "leather_chestpiece"], [EquipSlot.Slot.BOOTS, "leather_boots"],
		[EquipSlot.Slot.HELMET, "leather_helmet"], [EquipSlot.Slot.MELEE_MAIN_HAND, "greatsword"],
		[EquipSlot.Slot.RANGED_OFF_HAND, "tower_shield"], [EquipSlot.Slot.RANGED_MAIN_HAND, "rifle"]]
	for pair in heavy:
		var item := ItemInstance.new(load("res://data/items/%s.tres" % pair[1]))
		if not _hero.weight_allows(pair[0], item):
			_say("%s won't go on: past 10 x Basic Lift" % item.display_name())
			await _wait(2.5)
			continue
		_hero.equip_item(pair[0], item)
		_say("Wearing %s lb: %s. Move %s, Dodge %s" % [_hero.worn_weight(), LEVEL_NAMES[_hero.encumbrance_level()],
			_hero.get_stat(StatIds.MOVE), _hero.get_stat(StatIds.DODGE)])
		await _wait(2.5)
	var level: int = _hero.encumbrance_level()
	_check("heavy gear sets a level that costs Move and Dodge",
		level > 0 and _hero.get_stat(StatIds.MOVE) < move and _hero.get_stat(StatIds.DODGE) == dodge - level)
	_say("The bar under the paperdoll shows the level; the bag itself is never weighed")
	await _wait(4.0)
	for pair in heavy:
		if _hero.get_equipped_item(pair[0]):
			_hero.unequip_item(pair[0])
	_check("taking it off restores Move and Dodge",
		_hero.get_stat(StatIds.MOVE) == move and _hero.get_stat(StatIds.DODGE) == dodge)
	_hero.equip_item(EquipSlot.Slot.MELEE_MAIN_HAND, ItemInstance.new(IronSword))
	await _wait(1.5)
	overview.close()
	await _wait(0.5)


func _downed_and_game_over() -> void:
	var party: Array = PartyManager.everyone().filter(func(u): return u is Unit and u.is_alive())
	_say("Downed: below 0 HP each threshold is an HT roll to stay up; fail it and you go down, not die")
	await _wait(3.5)
	var first: Unit = party[0]
	var who: String = _plain(first)
	_down(first)
	await _wait(0.5)
	_check("%s is Downed, not dead" % who, first.is_downed() and first.is_alive())
	_check("one member down is not a loss", not PartyManager.is_defeated())
	_say("%s fails the roll and is Downed (HP %d). The rest are still standing" % [who, first.get_pool(StatIds.HP)])
	await _wait(3.5)
	_say("Down the rest: nobody standing is a loss")
	await _wait(2.0)
	for unit in party.slice(1):
		_down(unit)
		await _wait(0.6)
	await _wait(1.5)
	var screen: Control = get_tree().get_first_node_in_group("game_over")
	_check("the whole party Downed is a loss", PartyManager.is_defeated())
	_check("the game over screen is on screen", screen != null and screen.is_visible_in_tree())
	await _wait(4.0)


## Damage to below 0, then a failed HT roll — the roll is random, so
## the failure is forced the same way test_game_over does it.
func _down(unit: Unit) -> void:
	unit.take_damage(unit.get_pool(StatIds.HP) + 2)
	if unit.is_downed() or not unit.is_alive():
		return
	unit.apply_status(UnitCombat.downed_status())
	unit.downed_changed.emit(unit)


func _plain(unit: Unit) -> String:
	var tags := RegEx.create_from_string(r"\[[^\]]*\]")
	return tags.sub(LogFormat.unit_name(unit), "", true)


## Attacks the dummy with the named sword attack and captions the outcome.
func _strike(name: String, caption: String) -> void:
	_say(caption)
	await _wait(1.0)
	_hero.reset_turn_actions()
	var before: int = _dummy.get_pool(StatIds.HP)
	var result: Dictionary = await _hero.use_ability(_attack(name), _dummy)
	await _wait(0.8)
	var line: String
	if not result.has("to_hit"):
		line = "did not attack"
	elif not result.to_hit.success:
		line = "miss (rolled %d vs %d)" % [result.to_hit.roll, result.to_hit.target]
	elif not result.get("hit", false):
		line = "%s stopped it" % result.defense.kind
	else:
		line = "hit for %d" % (before - _dummy.get_pool(StatIds.HP))
	_say(caption + "  →  " + line)
	_dummy.set_pool(StatIds.HP, floori(_dummy.get_stat(StatIds.HP)))
	await _wait(2.5)


func _attack(name: String) -> Ability:
	for a in _hero.combat_abilities():
		if a.ability_name == name and a.effects.any(func(e): return e is GearDamageEffect):
			return a
	return null


## A same-faction target: hitting it starts no fight.
func _make_dummy(forward: float) -> Unit:
	var unit: Unit = load("res://systems/unit_system/unit.tscn").instantiate()
	var definition := UnitDefinition.new()
	definition.model_scene = load("res://scenes/character_models/placeholder_model.tscn")
	unit.definition = definition
	WorldManager.spawn_parent().add_child(unit)
	unit.faction = _hero.faction
	unit.set_base_stat(StatIds.HP, 60)
	unit.set_pool(StatIds.HP, 60)
	unit.global_position = _hero.global_position + _hero.visual_forward() * forward
	return unit
