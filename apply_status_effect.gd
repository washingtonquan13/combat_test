class_name ApplyStatusEffect
extends AbilityEffect
## Applies a status effect to target on use — combine with DamageEffect
## etc. in the SAME ability's effects array for something like "this
## attack also causes Bleeding," or use alone for a pure status-
## inflicting ability (a sleep dart, a shove that knocks someone Prone).
## This is the bridge between the ability system and the status system —
## nothing about Ability/Unit.use_ability() needed to change for this to
## work, since it's just another AbilityEffect subclass slotting into
## the existing effects array.

@export var status: StatusEffect


func apply(_attacker: Unit, target, _ability: Ability) -> Dictionary:
	if not target is Unit or not status:
		return {}

	target.apply_status(status)
	return {"applied_status": status.status_name}


func describe() -> String:
	return "Applies %s" % (status.status_name if status else "(no status set)")
