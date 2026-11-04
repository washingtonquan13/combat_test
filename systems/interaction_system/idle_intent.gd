class_name IdleIntent
extends PlayerIntent
## Nothing armed, nothing pushed, the world accepting orders: a click
## commands whoever is selected.
##
## Left-click priority, unchanged from what the two old owners between
## them did:
##   1. a unit under the cursor — attack it if the acting unit has an
##      ability that routes at it, otherwise select it (additively with
##      select_additive held). This half used to live on Unit itself, in
##      a physics-picked _on_input_event, which is why it needed its own
##      copy of the "is a conversation running" guard and its own copy of
##      the acting-unit rules;
##   2. any other interactable — nothing, and the click is NOT consumed,
##      exactly as before (an InteractableProp has no left-click verb;
##      right-click opens its menu);
##   3. ground — a move order.
##
## Right-click: the context menu for whatever is under the cursor. Empty
## ground does nothing, deliberately (move lives on left-click).

func kind() -> StringName:
	return &"idle"


func handle_left_click(router, cursor: Cursor) -> bool:
	if cursor.unit:
		return router.click_unit(cursor.unit)
	if cursor.interactable:
		return false
	if cursor.ground == null:
		return false
	return router.command_move(cursor.ground)


func handle_right_click(_router, cursor: Cursor) -> bool:
	if cursor.interactable == null:
		return false
	var actor: Unit = PlayerInteractionState.get_active_unit()
	if actor == null:
		return false
	InteractionMenu.open_for(cursor.interactable, actor)
	# Only a click that opened something is consumed; open_for no-ops on
	# a target with no available options and the click falls through.
	return InteractionMenu.is_open()


## Ctrl drags flight altitude while anyone it would apply to flies.
func drags_height(router) -> bool:
	return not flying_units_for_altitude(router.active_unit()).is_empty()


## Every flier the drag applies to takes its height as its target
## altitude, which the move order and the path preview both read
## (Unit.flight_target_altitude). Letting go keeps whatever altitude the
## drag landed on.
func steer(router, cursor: Cursor) -> void:
	if not cursor.dragging_height or cursor.height == null:
		return
	for unit in flying_units_for_altitude(router.active_unit()):
		unit.set_flight_altitude(cursor.height)


## Which units the altitude drag applies to. In combat only the acting
## unit can move at all, so it is just that one, if it flies. Out of
## combat a move order goes to the whole selection (see
## FormationPlanner), so the drag does too: every selected flier shares
## the one dragged altitude. Scoping it to the active unit alone was a
## bug once - a mixed selection whose first unit walked silently ignored
## the drag.
func flying_units_for_altitude(active_unit: Unit) -> Array[Unit]:
	var flying: Array[Unit] = []
	if not active_unit:
		return flying
	# The COMMANDED unit's own situation, not whether a fight exists
	# somewhere: a flier standing outside a battle should still be
	# adjustable along with the rest of the selection.
	if active_unit.in_combat():
		if active_unit.is_flying():
			flying.append(active_unit)
		return flying
	for unit in SelectionManager.selected_units:
		if is_instance_valid(unit) and unit.is_flying():
			flying.append(unit)
	return flying


## The path preview, and nothing else. Every aiming overlay stands down
## while nothing is armed — which is what movement_indicator.gd's own
## per-frame "is anything armed?" poll used to say from the other
## direction, once per indicator.
func indicator_ids() -> Array[StringName]:
	return [&"movement", &"hit_chance"]


func describe() -> String:
	return "idle"
