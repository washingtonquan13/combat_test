class_name PickUpEffect
extends AbilityEffect
## Gets a Downed ally back on their feet (Unit.pick_up). Heals nothing:
## they stand up at whatever negative HP they went down at.


func apply(attacker: Unit, target, _ability: Ability, _is_critical: bool) -> Dictionary:
	if not target is Unit or not target.pick_up():
		return {}
	SystemLog.print("%s picks %s up." % [LogFormat.unit_name(attacker), LogFormat.unit_name(target)])
	return {"picked_up": true}


func describe() -> String:
	return "Picks up a Downed ally"
