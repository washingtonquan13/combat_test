class_name PlayerInteractionState
extends RefCounted
## Single source of truth for "what can the player currently do" — the
## condition every indicator/facing script (movement_indicator.gd,
## jump_indicator.gd, line_of_sight_indicator.gd, area_indicator.gd,
## unit_aim_facing.gd) needs answered before deciding whether to show
## anything or react to input at all.
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

## The unit whose turn it currently is, if and only if: combat is
## running, that unit is alive and player-controlled, and Unit.can_act()
## says it's free to do something (not busy, not prevented by an active
## status like Sleep/Stun). Returns null otherwise — every caller should
## treat a null return as "hide/do nothing," not try to reconstruct why
## on its own.
##
## Delegates the unit-intrinsic half of this check to Unit.can_act()
## rather than re-deriving it here — this is deliberately the ONLY place
## the player/turn-specific conditions (is it the current turn, is it
## player-controlled) get layered on top, so those two concerns
## (can THIS unit act at all vs. is it currently the PLAYER's turn to
## direct it) stay in exactly one place each rather than getting
## re-mixed together per caller.
static func get_active_unit() -> Unit:
	if not CombatManager.in_combat:
		return null

	var unit: Unit = CombatManager.current_unit
	if not unit or not is_instance_valid(unit) or not unit.is_alive():
		return null
	if not unit.is_player_controlled():
		return null
	if not unit.can_act():
		return null

	return unit


## Whether ANY ability is currently armed via AbilityManager — used by
## movement_indicator.gd specifically, since a click while anything is
## armed uses that ability instead of moving (see ground_click_target.gd),
## so the movement preview should stand down whenever this is true.
static func has_any_ability_armed() -> bool:
	return AbilityManager.armed_ability != null


## The currently armed ability, if and only if it's armed AND its
## targeting is an instance of targeting_type — used by
## jump_indicator.gd / line_of_sight_indicator.gd / area_indicator.gd,
## each of which only cares about ONE specific targeting shape. One
## generic implementation via is_instance_of() instead of three
## hand-written near-duplicates that only ever differed in which class
## they checked against.
static func get_armed_ability_of_targeting_type(targeting_type: Script) -> Ability:
	var ability: Ability = AbilityManager.armed_ability
	if not ability or not ability.targeting:
		return null
	if not is_instance_of(ability.targeting, targeting_type):
		return null
	return ability
