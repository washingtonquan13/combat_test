extends Node
## Autoload singleton. Register as "AbilityManager" under
## Project > Project Settings > AutoLoad.
##
## Tracks which ability is currently "armed" for click-to-target — the
## hook the ability hotbar drives (arm an ability by clicking its hotbar
## slot, then click a target). When nothing's armed, click routing
## (ClickRouter.click_unit) falls back to whichever unit is acting and
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

## Who armed_ability is armed FOR - the commanded unit at arm() time. The
## signal itself is global, so this is how each unit's armed-stance
## presentation (UnitAnimator, UnitSfx, UnitVfx) tells whether the arming
## is its own. Still set while ability_armed(null) is emitted, so the unit
## that was armed can put its stance away; cleared right after.
var armed_unit: Unit = null

## The unit whose ability_used signal we're currently listening to, so we
## know when to re-check whether armed_ability is still usable. Tracked
## explicitly rather than assumed to always equal CombatManager.
## current_unit, since disarm() needs to cleanly unhook from whichever
## unit was being watched even if the current unit has since changed.
var _watched_unit: Unit = null

## Absolute world Y an aimed shape's point is taken at - see
## AimingIntent.steer, the only writer (set_aim_height_override /
## clear_aim_height_override): the latched height plane's Y when the
## cursor point is on it, a hovered unit's centre of mass, or nothing.
## Read through AbilityTargeting.resolve_target_point by both the preview
## (Aim.build) and the click, so the confirmed cast can't disagree with
## what the preview showed. has_aim_height_override false means "use the
## natural ground-hover height" (a cone's level AIM_LIFT, flat on the
## ground for the rest). Reset whenever the armed ability changes - a
## leftover height from a previous, unrelated cast should never silently
## carry into a new one.
var aim_height_override: float = 0.0
var has_aim_height_override: bool = false

## Where a LineTargeting ability's line starts, once its first click is
## in (see LineTargeting.resolve_click). Reset with the armed ability, as
## the aim height is.
var line_start: Vector3 = Vector3.ZERO
var has_line_start: bool = false


func arm(ability: Ability) -> void:
	var unit: Unit = PlayerInteractionState.get_active_unit()
	if armed_ability and armed_unit != unit:
		# Arming for someone else: the unit that was armed puts its stance
		# away first, or nothing would ever tell it to.
		disarm()
	armed_ability = ability
	armed_unit = unit
	has_aim_height_override = false
	has_line_start = false
	_watch_current_unit()
	ability_armed.emit(ability)


func disarm() -> void:
	_unwatch_unit()
	has_aim_height_override = false
	has_line_start = false
	if armed_ability == null:
		return
	armed_ability = null
	ability_armed.emit(null)
	armed_unit = null


## Called by AimingIntent.steer whenever the cursor's aim point carries
## its own height (see there; ClickRouter.resolve_cursor owns the plane
## and the input). A plain setter here rather than the intent writing the
## fields directly, so this stays the one place the "is a height
## override active" state actually lives.
func set_aim_height_override(y: float) -> void:
	aim_height_override = y
	has_aim_height_override = true


## The aim point is a plain surface point again: no height of its own.
func clear_aim_height_override() -> void:
	has_aim_height_override = false


func set_line_start(point: Vector3) -> void:
	line_start = point
	has_line_start = true


func clear_line_start() -> void:
	has_line_start = false


## Follows the COMMANDED unit, the same one every indicator and the
## hotbar follow (see PlayerInteractionState.get_active_unit). Reading
## CombatManager.current_unit meant watching the focused encounter's
## combatant — nobody at all out of combat, and somebody in another
## world once the party could be in two places.
func _watch_current_unit() -> void:
	var unit: Unit = PlayerInteractionState.get_active_unit()
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
## UnitCombat.resolve_click_ability) can still spend the SAME shared attack-action
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
	if ability.attack_action_spent_by(unit):
		return false
	if ability.has_move_caster_effect() and not unit.has_move_remaining():
		return false
	return true
