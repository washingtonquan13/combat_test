class_name FpDrainBehavior
extends StatusBehavior
## Spends FP at the start of each of the owner's turns while active —
## same "one reusable behavior, wrapped in different StatusEffect
## resources" idiom DamageOverTimeBehavior already establishes for
## Bleeding/Burning/Poison. Built for flying.tres (see that file): flight
## stays pure upside on combat modifiers (no to-hit/defense penalty for
## being airborne), so THIS is the actual cost — sustained flight runs on
## an FP clock instead of a duration timer.
##
## Removing the status when the unit can't pay is deliberately NOT a
## no-op or a "you take damage instead" branch — it calls
## unit.remove_status(active.effect) with voluntary defaulting to false,
## which is what routes a flying unit's forced grounding through the
## exact machinery already built for it: StatusManager.remove() ->
## ForceLandOnExpireBehavior.on_remove() -> Unit.land(false) -> fall
## damage (see that file). Running out of FP mid-air is a real
## consequence, and none of that path is new here — this is the one
## place that TRIGGERS it for this specific reason.

@export var fp_per_turn: int = 1


func on_turn_start(unit: Unit, active: ActiveStatus) -> void:
	var cost: int = fp_per_turn * active.stacks
	if unit.current_fp < cost:
		# Removal (not damage, not a partial charge) — this status simply
		# can no longer be sustained. unit.remove_status(), not
		# StatusManager directly — Unit is the public-facing surface
		# every other status-lifecycle caller in this project already
		# goes through.
		unit.remove_status(active.effect)
		return

	unit.current_fp -= cost


func describe() -> String:
	return "%d FP per turn" % fp_per_turn
