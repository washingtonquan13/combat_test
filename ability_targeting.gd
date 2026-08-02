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
