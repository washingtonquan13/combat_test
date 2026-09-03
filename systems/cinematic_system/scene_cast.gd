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
## late resolution fails worse than a snapshot would.
##
##   TRACKED  ask the authority every time. The speaker, the party leader.
##            Changes freely, nothing is copied, nothing can disagree.
##   HELD     the scene owns this actor for its duration. A demon still on
##            screen after the roster released it; a result that did not
##            exist when the scene started.
##
## HELD WINS over tracked for the same role, deliberately. A scene that has
## taken ownership of an actor is the authority on it until it lets go —
## that is what taking ownership means, and a fallthrough to the old owner
## would resurrect exactly the bug held roles exist to prevent.

## Marks are looked up by name in this group, so an area declares its
## staging by adding nodes rather than by any scene knowing about it.
const MARK_GROUP: StringName = &"scene_marks"

## role -> Callable returning a Unit (or null).
var _tracked: Dictionary = {}
## role -> Unit, owned by the scene rather than by anyone else.
var _held: Dictionary = {}
## Set by CinematicDirector when a scene starts. Steps are Resources with
## no tree presence of their own, and the cast is already the thing they
## are handed — the same reasoning that makes VfxEffect pass a `context`
## node down to every VfxStep.
var tree: SceneTree = null


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


## Takes ownership of `unit` for this role. It stays resolvable until
## release_role(), whatever any other system does to it in the meantime.
func hold(role: StringName, unit: Unit) -> SceneCast:
	_held[role] = unit
	return self


## Gives the role back. The actor itself is untouched — a scene that also
## wants it gone from the world uses DespawnActorStep.
func release_role(role: StringName) -> void:
	_held.erase(role)


func is_held(role: StringName) -> bool:
	return _held.has(role)


## Who is playing `role` right now, or null.
##
## Null is a normal answer, not an error — a monologue has nobody in the
## listener role, and a step that cannot resolve its subject declines to
## act rather than complaining.
func unit(role: StringName) -> Unit:
	if _held.has(role):
		var kept: Variant = _held[role]
		return kept if kept is Unit and is_instance_valid(kept) else null
	if not _tracked.has(role):
		return null
	var found: Variant = (_tracked[role] as Callable).call()
	return found if found is Unit and is_instance_valid(found) else null


func has(role: StringName) -> bool:
	return _held.has(role) or _tracked.has(role)


## A named staging point in the world, or null.
##
## LOUD WHEN MISSING. A scene naming a mark its area does not have is an
## authoring error, and silently falling back to the origin would put
## actors and cameras at the world centre while everything still appeared
## to work — the worst possible failure for staging, because it looks like
## a bad shot rather than a bad reference.
## Whether a mark exists, without complaining that it does not.
##
## mark() is deliberately loud, because a SCENE naming a mark its area
## lacks is an authoring error. ASKING WHETHER STAGING EXISTS AT ALL is a
## different question with a legitimate no — fusing on the overworld is
## allowed, it just has nowhere to show a cutscene — and routing that
## through mark() would fill the log with errors on every correct use.
func has_mark(mark_name: StringName) -> bool:
	if tree == null:
		return false
	for node in tree.get_nodes_in_group(MARK_GROUP):
		if node is Node3D and node.name == mark_name:
			return true
	return false


func mark(mark_name: StringName) -> Node3D:
	if tree == null:
		push_error("SceneCast: asked for mark '%s' before a tree was set." % mark_name)
		return null
	for node in tree.get_nodes_in_group(MARK_GROUP):
		if node is Node3D and node.name == mark_name:
			return node
	push_error("SceneCast: no mark named '%s' in group '%s'." % [mark_name, MARK_GROUP])
	return null
