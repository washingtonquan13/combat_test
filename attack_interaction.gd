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
	# Not hostile-only anymore — a neutral or allied-faction unit is a
	# valid Attack target too (see FactionRelations/
	# UnitCombat._maybe_trigger_combat for what actually happens once the
	# attack lands: it escalates the two factions to hostile). The only
	# real exclusion is your own side.
	if unit_target.is_player_controlled():
		return false
	return actor.default_ability() != null


func execute(actor: Unit, target) -> void:
	actor.use_ability(actor.default_ability(), target)
