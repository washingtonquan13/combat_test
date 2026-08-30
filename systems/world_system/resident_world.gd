class_name ResidentWorld
extends Node
## One loaded world and everything needed to put it on screen: the world
## node itself, the viewport it renders into, and its WorldContext.
##
## Exists because "the world" stopped being a single thing. WorldManager
## used to keep _current_world / _current_view / _context as three parallel
## variables held in step by hand, which works exactly as long as there is
## one of each.
##
## NOT a second WorldContext, and the split is deliberate. WorldContext is
## the WORLD's own state — its fights, its surfaces, its navigation grid —
## and its header lists what does not belong there. This is the HOSTING
## record: where the world is mounted, how it reaches the screen, and
## whether it has earned the right to stay loaded. A world could be
## serialized from its context alone; it could not be shown without this.

## The area this world was loaded from, or null for a world loaded through
## the raw load_world() primitive with no area data. Such a world can never
## be re-focused, because there is no id to find it by — see
## WorldManager._resident_for().
var area: AreaDefinition = null

var world: Node = null
var view: SubViewportContainer = null
var context: WorldContext = null

## Set while something outside this file needs the world kept loaded even
## with nothing running in it. Distinct from is_earned()'s own conditions
## so that "the rule said so" and "someone asked" stay tellable apart —
## the debug focus cycle uses it, and the party will once it can split.
var pinned: bool = false


func viewport() -> SubViewport:
	if not is_instance_valid(view) or view.get_child_count() == 0:
		return null
	return view.get_child(0) as SubViewport


func area_id() -> StringName:
	return area.id if area else &""


## Whether this world has a reason to stay loaded once the player looks
## away.
##
## Residency is EARNED rather than budgeted: there is no cap to tune, and
## the rule is the same as the reason residency exists at all — something
## is still happening here that freeing the world would destroy. A world
## with nothing running in it is not cheaper to keep than to rebuild, and
## AreaState already carries the differences that outlive a reload.
##
## A live fight qualifies. So does a party member left standing here —
## that one IS the point of splitting the party, and it is what stops a
## companion you walked away from being quietly deleted along with the
## area they were waiting in.
func is_earned() -> bool:
	if pinned:
		return true
	if context == null:
		return false

	for encounter in context.encounters:
		if is_instance_valid(encounter) and encounter.is_running:
			return true

	for unit in PartyManager.members:
		if is_instance_valid(unit) and context.contains(unit):
			return true

	return false


## Whether the player is currently looking at this world. Drives rendering
## and the 3D audio listener; NOT processing — an unfocused world keeps
## running, which is the entire point of residency.
func set_focused(focused: bool) -> void:
	if is_instance_valid(view):
		# Hiding the container is what stops the render: the viewport's
		# update mode is WHEN_VISIBLE, so this costs nothing per frame
		# while still leaving every node in it processing.
		view.visible = focused
	var sub: SubViewport = viewport()
	if sub:
		# Two listeners would mix both worlds' 3D audio together.
		sub.audio_listener_enable_3d = focused


## Frees the world and everything mounted with it, then itself. The world
## is the viewport's child, so freeing the view frees the world too — one
## free, not three.
func dispose() -> void:
	if context:
		context.dispose()
		context.queue_free()
		context = null

	if is_instance_valid(view):
		# remove_child() immediately, THEN queue_free() — not queue_free()
		# alone. queue_free() defers the actual removal, so this view would
		# still occupy its name among WorldHost's children at the moment
		# the next one is added, and Godot silently renames the newcomer
		# to avoid the collision.
		if view.get_parent():
			view.get_parent().remove_child(view)
		view.queue_free()

	view = null
	world = null
	area = null
	queue_free()
