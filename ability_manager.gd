extends Node
## Autoload singleton. Register as "AbilityManager" under
## Project > Project Settings > AutoLoad.
##
## Tracks which ability is currently "armed" for click-to-target — the
## hook the ability hotbar drives (arm an ability by clicking its hotbar
## slot, then click a target). When nothing's armed, click routing
## (Unit._on_input_event) falls back to whichever unit is acting and
## uses ITS OWN default ability.
##
## Auto-disarms whenever the armed ability becomes unusable by the
## current unit for the rest of THIS turn — an attack-action ability
## right after it's used (has_attacked is now true, so it can never be
## used again until next turn), specifically. Without this, armed_ability
## stayed set to something that would just silently fail if clicked, and
## every indicator that correctly checks "is X currently armed" (see
## PlayerInteractionState) kept showing a preview for it regardless —
## the fix belongs here, at the actual source of truth, rather than
## teaching every indicator to separately re-derive "but is it REALLY
## still usable" on top of "is it armed," which would just be the same
## duplicated-logic problem PlayerInteractionState was built to end.
##
## Movement-budget abilities (Jump) are deliberately NOT auto-disarmed
## this way as long as there's still move budget left — unlike an attack
## you've already spent, you may reasonably want to jump again this turn.

signal ability_armed(ability: Ability)

var armed_ability: Ability = null

## The unit whose ability_used signal we're currently listening to, so we
## know when to re-check whether armed_ability is still usable. Tracked
## explicitly rather than assumed to always equal CombatManager.
## current_unit, since disarm() needs to cleanly unhook from whichever
## unit was being watched even if the current unit has since changed.
var _watched_unit: Unit = null


func arm(ability: Ability) -> void:
	armed_ability = ability
	_watch_current_unit()
	ability_armed.emit(ability)


func disarm() -> void:
	_unwatch_unit()
	if armed_ability == null:
		return
	armed_ability = null
	ability_armed.emit(null)


func _watch_current_unit() -> void:
	var unit: Unit = CombatManager.current_unit
	if unit == _watched_unit:
		return
	_unwatch_unit()
	_watched_unit = unit
	if _watched_unit:
		_watched_unit.ability_used.connect(_on_watched_unit_ability_used)


func _unwatch_unit() -> void:
	if _watched_unit and is_instance_valid(_watched_unit) and _watched_unit.ability_used.is_connected(_on_watched_unit_ability_used):
		_watched_unit.ability_used.disconnect(_on_watched_unit_ability_used)
	_watched_unit = null


## Fires after ANY ability use by the unit we're currently watching, not
## just uses of the armed ability specifically — using a DIFFERENT
## ability (e.g. the unit's default melee attack, if the player clicked
## an enemy while something else happened to be armed... though in
## practice armed_ability always takes priority when set, see
## Unit._on_input_event) can still spend the SAME shared attack-action
## budget the armed ability depends on, so it's the right thing to
## re-check regardless of which ability actually fired the signal.
func _on_watched_unit_ability_used(attacker: Unit, _target, _result: Dictionary) -> void:
	if not armed_ability:
		return
	if not _is_still_usable(attacker, armed_ability):
		disarm()


## Whether armed_ability could still legally be used by unit again this
## turn — NOT a range/target check (that depends on wherever the player
## next aims, and is re-evaluated fresh every time regardless), just the
## turn-economy side: the attack action, if this ability needs one, and
## remaining move budget, if it's a movement-budget ability like Jump.
func _is_still_usable(unit: Unit, ability: Ability) -> bool:
	if ability.uses_attack_action and unit.has_attacked:
		return false
	if _is_move_budget_ability(ability) and not unit.has_move_remaining():
		return false
	return true


func _is_move_budget_ability(ability: Ability) -> bool:
	for effect in ability.effects:
		if effect is MoveCasterEffect:
			return true
	return false
