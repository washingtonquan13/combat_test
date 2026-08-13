class_name AbilityTargeting
extends Resource
## Base class for "how does this ability pick/validate a target." One
## subclass per targeting SHAPE (melee enemy, ranged enemy with line of
## sight, ground point, area — see GroundPointTargeting, AreaTargeting)
## — each carrying only the fields that shape actually needs, instead of
## every targeting rule's fields living together on one shared Ability
## resource where most of them go unused by any given instance.

## Whether target is a legal target for this ability from attacker's
## current position — geometry/range/LoS only. target's type depends on
## the subclass: a Unit for enemy-targeting subclasses, a Vector3 for
## point-targeting ones. Callers are expected to have already checked
## things like hostility/faction before calling this; it only answers
## "is this within range," not "is this an appropriate thing to target
## at all." Override in each subclass.
func is_valid_target(_attacker: Unit, _target) -> bool:
	return false


## Whether this ability expects to be aimed at a UNIT ON THE SAME FACTION
## rather than a hostile one — a heal, a buff. Read by Unit._on_input_event
## to decide whether clicking a friendly unit should cast this ability at
## them instead of just selecting them (the default, and the only
## behavior before this field existed). Lives here rather than as a
## separate MeleeAllyTargeting/RangedAllyTargeting subclass pair because
## MeleeEnemyTargeting/RangedEnemyTargeting's own is_valid_target was
## ALREADY hostility-agnostic (pure geometry — see their own doc
## comments) — the "Enemy" in their names describes the historical
## default use, not an actual constraint the class enforces, so a single
## flag here reuses the exact same range/LoS logic for an ally-facing
## ability instead of duplicating it. Meaningless for point/area
## targeting (GroundPointTargeting, AreaTargeting) since those don't
## target a Unit at all — left false and unused there.
@export var requires_ally: bool = false


func requires_ally_target() -> bool:
	return requires_ally


## Whether this targeting shape needs no click at all — the target is
## already fully known the instant the ability is armed (see
## SelfTargeting). Every other shape waits for further input (a unit
## click, a ground click); this is the one case where arming and using
## should be the same action. Checked by ability_hotbar.gd before it
## arms-and-waits — a polymorphic query for the same reason
## expects_point_target() is one rather than a growing "is SelfTargeting
## or is X or..." chain at each call site.
func resolves_immediately() -> bool:
	return false


## Whether this targeting subclass expects a Vector3 (ground point) as
## its target rather than a Unit. Used by ground_click_target.gd to
## decide whether a ground click should route to ability use instead of
## the normal deselect/move behavior — a polymorphic query rather than a
## growing "is GroundPointTargeting or is AreaTargeting or ..." chain
## that would need editing every time a new point-targeting subclass is
## added. Override to true in each point-targeting subclass.
func expects_point_target() -> bool:
	return false


## Distance CombatAI should try to close to before considering a target
## in range — used for movement/standoff purposes (see CombatAI.
## _standoff_goal). Override in each subclass; base returns 0 (stand
## right next to target) as a safe default for any targeting kind that
## doesn't override this.
func approach_range() -> float:
	return 0.0


## Human-readable summary for tooltips (see hotbar_slot.gd). Override in
## each subclass.
func describe() -> String:
	return ""
