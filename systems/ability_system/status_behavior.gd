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


## Called when a surface puts this status on unit by their getting into
## it - stepping into fire, a wall springing up round them - after it is
## applied (see SurfaceManager._process). Not at turn start, when the
## status's own on_turn_start already bites.
func on_contact(_unit: Unit, _active: ActiveStatus) -> void:
	pass


## Called once when the status is removed (expired, cured, replaced).
## voluntary is true only when the unit itself chose this removal (a
## Land action) — false for natural expiry or any other forced removal
## (Incapacitate grounding a flyer). See StatusManager.remove()'s own
## header for the full reasoning; ForceLandOnExpireBehavior is the one
## behavior that currently reads this.
func on_remove(_unit: Unit, _active: ActiveStatus, _voluntary: bool = false) -> void:
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


## Whether this behavior holds the unit where it stands (Webbed): it may
## still act, but not walk. If ANY active status returns true, the unit's
## Move reads 0 and move_to() refuses (see StatusManager.prevents_movement()).
func prevents_movement() -> bool:
	return false


## Called whenever unit takes damage from any source, AFTER the damage is
## applied — lets a behavior react, e.g. RemoveOnDamageBehavior clearing
## the whole status (not just itself) when its owner is hit. critical:
## the hit was a critical one.
func on_damage_taken(_unit: Unit, _amount: int, _active: ActiveStatus, _critical: bool = false) -> void:
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


## Whether this behavior grants flight while active — if ANY active
## status returns true here, Unit.is_flying() reports true (see
## StatusManager.grants_flight(), which UnitMovement.move_to() checks to
## pick ground vs air navigation). Same "any active status contributes"
## pattern as prevents_turn().
func grants_flight() -> bool:
	return false


## Multiplies how far this unit jumps by strength (see
## GroundPointTargeting.jump_multiplier). Multiplied across active statuses.
func jump_distance_multiplier() -> float:
	return 1.0


## Metres of any fall this unit doesn't count. Summed across active
## statuses; see Unit.counted_fall.
func ignored_fall_distance() -> float:
	return 0.0


## The rolled damage of a fall after this behavior has had its say, before
## DR. See Unit.soften_fall.
func soften_fall(_unit: Unit, damage: int) -> int:
	return damage


## Added to the HT roll a unit makes each turn while Downed, the roll that
## decides whether it dies. Summed across active statuses.
func survival_roll_bonus() -> int:
	return 0


## Added to this unit's level in skill. Summed across active statuses; see
## SkillCalculator.get_skill_level.
func skill_bonus(_skill: Skill) -> int:
	return 0


## This behavior as it works at level on a leveled advantage, whose
## numbers are per level. Override where a number should scale; the
## default is the same at every level. Must not change this resource,
## which is shared.
func at_level(_level: int) -> StatusBehavior:
	return self


## Human-readable summary for tooltips. Override in each subclass.
func describe() -> String:
	return ""
