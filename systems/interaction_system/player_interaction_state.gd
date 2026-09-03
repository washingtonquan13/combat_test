class_name PlayerInteractionState
extends RefCounted
## Single source of truth for "what can the player currently do" — the
## condition every preview indicator, facing script, and click-to-act
## handler needs answered before deciding whether to show anything or
## react to input at all. See get_active_unit()'s own doc comment for the
## current, exact list of consumers — kept in exactly one place rather
## than copied here too, for the same reason this file exists at all.
##
## Existed as five independently hand-written copies of the same
## condition chain before this — when armed_ability was introduced, four
## of five consumers got updated and one didn't (movement_indicator.gd
## never learned abilities existed at all); when is_busy() needed
## checking, all five needed the identical one-line addition made
## independently by hand. Neither bug was a flaw in the actual turn-state
## machinery (CombatManager, Unit.is_busy(), use_ability()/move_to()'s
## own gating never let anything invalid actually happen) — it was that
## nothing enforced every OBSERVER of that state staying in sync with
## each other. This file is that enforcement point.
##
## Static utility, not an autoload — holds no state of its own, only
## reads from CombatManager/AbilityManager/Unit, which already ARE the
## actual sources of truth. Call directly, e.g.
## PlayerInteractionState.get_active_unit(), from anywhere.
##
## Down to one question. Three others lived here — has_any_ability_armed,
## get_armed_ability_of_targeting_type and get_armed_seeking_ability —
## and every one of them existed so an indicator could re-derive, every
## frame, whether IT was the one currently being aimed. That question has
## a single asker now (ClickRouter, which derives one PlayerIntent and
## tells each indicator whether it is live), and it asks AbilityManager
## directly, so all three lost their last caller at once. What is left is
## the question this file was actually built for: WHO is being
## commanded.

## The unit the player is currently commanding, in or out of combat — the
## acting unit whose turn it is during combat, or the first selected unit
## otherwise — as long as it's alive, player-controlled, and Unit.can_act()
## says it's free to do something (not busy, not prevented by an active
## status like Sleep/Stun). Returns null otherwise — every caller should
## treat a null return as "hide/do nothing," not try to reconstruct why
## on its own.
##
## Delegates the unit-intrinsic half of this check to Unit.can_act()
## rather than re-deriving it here — this is deliberately the ONLY place
## the player/turn-specific conditions (who's allowed to act right now,
## in or out of combat) get layered on top. Consumed by every preview
## indicator (movement_indicator.gd, jump_indicator.gd,
## line_of_sight_indicator.gd, area_indicator.gd, aerial_area_indicator.gd,
## seeking_indicator.gd, unit_aim_facing.gd) and by ClickRouter, which
## owns both the ground-targeted and the unit-targeted click paths —
## none of which has any OTHER
## combat-only gate, which is what makes widening this one function
## enough to make all of them correctly work out of combat too.
## The selection, always — the global in_combat branch that used to sit
## here is gone.
##
## It was redundant with machinery that already exists: SelectionManager
## auto-selects on turn_started, so during a fight the selection IS the
## current unit. What the branch actually did was make a party member
## standing OUTSIDE a fight unselectable in every sense that matters —
## their abilities, their indicators and their targeting all silently
## belonged to whoever was taking a turn somewhere else.
##
## Still null during an enemy turn, as before: the player's own selected
## unit is in that fight and it is not their turn, so is_commandable()
## refuses it. Same answer, reached by asking about the unit rather than
## about the world.
static func get_active_unit() -> Unit:
	for unit in SelectionManager.selected_units:
		if is_instance_valid(unit) and unit.is_commandable():
			return unit
	return null
