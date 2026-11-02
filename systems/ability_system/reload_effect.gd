class_name ReloadEffect
extends AbilityEffect
## Fills every held weapon's magazine (WeaponData.shots). GURPS counts
## reload time in seconds per weapon (the (3) in Shots 9(3)); here it is
## one attack action for all of them, offered whenever a magazine weapon
## is held (UnitCombat.combat_abilities).


func apply(attacker: Unit, _target, _ability: Ability, _is_critical: bool) -> Dictionary:
	if attacker.reload_all() == 0:
		SystemLog.print("%s has nothing to reload." % LogFormat.unit_name(attacker))
	return {}


func describe() -> String:
	return "Reloads every held weapon"
