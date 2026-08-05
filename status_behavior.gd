class_name StatusBehavior
extends Resource
## Base class for what a status effect actually DOES. One StatusEffect
## can combine several of these — e.g. Sleep = IncapacitateBehavior
## (can't act) + RemoveOnDamageBehavior (any hit cancels it), neither of
## which alone IS Sleep, but together they are — same reasoning as
## Ability/AbilityEffect: small, reusable, single-purpose pieces instead
## of one flat class per status with a growing pile of mostly-unused
## fields.
##
## Each behavior only implements the specific hook(s) it actually needs;
## every hook has a harmless no-op default, so a pure damage-over-time
## behavior doesn't need to stub out "prevents_turn" or vice versa.

## Called once when the status is first applied to unit.
func on_apply(_unit: Unit, _active: ActiveStatus) -> void:
	pass


## Called once when the status is removed (expired, cured, replaced).
func on_remove(_unit: Unit, _active: ActiveStatus) -> void:
	pass


## Called at the start of unit's own turn (see StatusManager.
## tick_turn_start), after this application's duration has already been
## decided to continue (a status still gets its final tick's effect on
## the turn it expires, not skipped).
func on_turn_start(_unit: Unit, _active: ActiveStatus) -> void:
	pass


## Whether this behavior wants to prevent the unit from acting on its own
## turn at all (Sleep, Stun, Paralysis, ...) — if ANY active status
## returns true here, Unit.move_to()/use_ability() both refuse to do
## anything (see StatusManager.prevents_turn()).
func prevents_turn() -> bool:
	return false


## Called whenever unit takes damage from any source, AFTER the damage is
## applied — lets a behavior react, e.g. RemoveOnDamageBehavior clearing
## the whole status (not just itself) when its owner is hit.
func on_damage_taken(_unit: Unit, _amount: int, _active: ActiveStatus) -> void:
	pass


## Flat modifier to an INCOMING attack's to-hit target number, from the
## perspective of the unit this status is attached to being the
## DEFENDER. This is a roll-under system (see Unit.roll_vs) — a HIGHER
## target number is EASIER for the attacker to hit, so a positive
## modifier here helps the attacker (e.g. Prone making melee attacks
## against you easier) and a negative one hurts them (Prone making
## ranged attacks against you harder). Summed across every active status
## on the defender for a given attack.
func modify_incoming_attack_to_hit(_defender: Unit, _attacker: Unit, _ability: Ability) -> int:
	return 0


## The Bless/outgoing-side counterpart to modify_incoming_attack_to_hit
## above — a flat modifier to an OUTGOING attack's to-hit target number,
## from the perspective of the unit this status is attached to being the
## ATTACKER. Same roll-under convention: a positive modifier helps the
## unit carrying this status land their OWN attacks; summed across every
## active status on the ATTACKER for a given attack (see
## StatusManager.outgoing_attack_to_hit_modifier).
func modify_outgoing_attack_to_hit(_attacker: Unit, _target, _ability: Ability) -> int:
	return 0


## Human-readable summary for tooltips. Override in each subclass.
func describe() -> String:
	return ""
