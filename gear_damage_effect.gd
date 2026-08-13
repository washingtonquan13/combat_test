class_name GearDamageEffect
extends AbilityEffect
## Rolls damage from whichever weapon the attacker actually has
## equipped, instead of a fixed bonus baked into the ability itself
## (see StDamageEffect) — the ability just says "melee" or "ranged" via
## category; the equipped weapon (or lack of one) decides the rest.
## Swing/Thrust weapons share StDamageEffect.roll_damage()'s exact
## GURPS formula, just fed the weapon's damage_bonus instead of a value
## hardcoded on this effect; Fixed weapons roll their own dice entirely,
## ignoring the attacker's ST.
##
## Nothing equipped in either hand for this category: falls back to
## bare-handed ST damage (roll_damage with bonus 0) rather than dealing
## zero — a simplification, not a real unarmed-combat model.

enum WeaponCategory { MELEE, RANGED }

@export var category: WeaponCategory = WeaponCategory.MELEE


func apply(attacker: Unit, target, _ability: Ability) -> Dictionary:
	if not target is Unit:
		return {}

	var weapon: GearItem = _find_weapon(attacker)
	var raw_damage: int = _roll(attacker, weapon)
	var applied: int = max(raw_damage - target.get_stat("DR"), 0)
	target.take_damage(applied)

	return {"raw_damage": raw_damage, "damage": applied}


## Main hand first, then off hand — covers a two-handed weapon in the
## main slot (the common case) as well as an off-hand-only weapon (a
## dagger paired with a shield in the main slot). Returns null if
## neither slot holds an actual weapon (empty, or gear with no
## weapon_data — a shield, say).
func _find_weapon(attacker: Unit) -> GearItem:
	var main_key: String = "MeleeMainHand" if category == WeaponCategory.MELEE else "RangedMainHand"
	var off_key: String = "MeleeOffHand" if category == WeaponCategory.MELEE else "RangedOffHand"

	var main_item: Item = attacker.get_equipped_item(main_key)
	if main_item and main_item.gear_data and main_item.gear_data.weapon_data:
		return main_item.gear_data

	var off_item: Item = attacker.get_equipped_item(off_key)
	if off_item and off_item.gear_data and off_item.gear_data.weapon_data:
		return off_item.gear_data

	return null


func _roll(attacker: Unit, weapon: GearItem) -> int:
	if not weapon:
		return StDamageEffect.roll_damage(attacker.get_stat("ST"), StDamageEffect.DamageType.SWING, 0)

	var weapon_data: WeaponData = weapon.weapon_data
	match weapon_data.damage_type:
		WeaponData.DamageType.FIXED:
			var total: int = 0
			for _i in weapon_data.fixed_dice_count:
				total += randi_range(1, weapon_data.fixed_dice_sides)
			return total + weapon_data.fixed_dice_bonus
		WeaponData.DamageType.THRUST:
			return StDamageEffect.roll_damage(attacker.get_stat("ST"), StDamageEffect.DamageType.THRUST, weapon_data.damage_bonus)
		_:
			return StDamageEffect.roll_damage(attacker.get_stat("ST"), StDamageEffect.DamageType.SWING, weapon_data.damage_bonus)


func describe() -> String:
	var label := "Melee" if category == WeaponCategory.MELEE else "Ranged"
	return "%s weapon damage" % label
