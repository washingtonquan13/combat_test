class_name AttackInteraction
extends InteractionOption
## Right-click "Attack" — a second, independent way to reach the exact
## same Unit.use_ability() call unit.gd's own left-click quick-attack path
## already makes. Deliberately NOT unified with that path (e.g. by having
## one call into the other's helper) — left-click's routing is hard-won,
## working code (extra-action bug, combat-initiation triggers all landed
## there already); duplicating its two-line hostility/ability check here
## is cheaper than risking it. Worth unifying later if a third caller
## shows up wanting the same "can actor attack target right now" check.

func is_available(actor: Unit, target) -> bool:
	if not target is Unit:
		return false
	var unit_target: Unit = target
	if not actor.is_hostile_to(unit_target):
		return false
	return actor.default_ability() != null


func execute(actor: Unit, target) -> void:
	actor.use_ability(actor.default_ability(), target)
