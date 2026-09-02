class_name SceneCast
extends RefCounted
## Who is playing which role in a scene, resolved when a step asks rather
## than when the scene starts.
##
## LATE, NOT EAGER. "The speaker" changes with every line, so a snapshot
## taken at scene start is wrong by the second one. A role is a question
## put to whoever owns the answer, and nothing is copied, so nothing can
## disagree.
##
## THE RULE IS "NEVER STORE WHAT SOMEONE ELSE OWNS", not "never store".
## The distinction matters and an earlier draft got it wrong by being
## absolute: the fusion cutscene CONSUMES its parent demons partway
## through, so asking DemonRoster for one after that returns nothing and
## late resolution fails worse than a snapshot would. Phase 2 adds held
## roles for exactly that — an actor the scene itself owns for its
## duration. Only tracked roles exist here, because nothing yet needs the
## other kind.

## role -> Callable returning a Unit (or null).
var _tracked: Dictionary = {}


## Binds a role to a question. The Callable is asked every time the role is
## read, so it must be cheap and must tolerate being asked when the answer
## is nothing.
func track(role: StringName, resolver: Callable) -> SceneCast:
	_tracked[role] = resolver
	return self


## Convenience for a role that is simply one unit for the whole scene, and
## whose owner is not going to take it away. Still a question underneath,
## so a freed unit resolves to null rather than to a dangling reference.
func track_unit(role: StringName, unit: Unit) -> SceneCast:
	return track(role, func() -> Unit: return unit if is_instance_valid(unit) else null)


## Who is playing `role` right now, or null.
##
## Null is a normal answer, not an error — a monologue has nobody in the
## listener role, and a step that cannot resolve its subject declines to
## act rather than complaining.
func unit(role: StringName) -> Unit:
	if not _tracked.has(role):
		return null
	var found: Variant = (_tracked[role] as Callable).call()
	return found if found is Unit and is_instance_valid(found) else null


func has(role: StringName) -> bool:
	return _tracked.has(role)
