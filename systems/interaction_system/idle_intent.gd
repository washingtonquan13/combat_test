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


func handle_left_click(router, hit: ClickHit) -> bool:
	if hit.unit:
		return router.click_unit(hit.unit)
	if hit.interactable:
		return false
	if hit.ground == null:
		return false
	return router.command_move(hit.ground)


func handle_right_click(_router, hit: ClickHit) -> bool:
	if hit.interactable == null:
		return false
	var actor: Unit = PlayerInteractionState.get_active_unit()
	if actor == null:
		return false
	InteractionMenu.open_for(hit.interactable, actor)
	# Only a click that opened something is consumed; open_for no-ops on
	# a target with no available options and the click falls through.
	return InteractionMenu.is_open()


## The path preview, and nothing else. Every aiming overlay stands down
## while nothing is armed — which is what movement_indicator.gd's own
## per-frame "is anything armed?" poll used to say from the other
## direction, once per indicator.
func indicator_ids() -> Array[StringName]:
	return [&"movement"]


func describe() -> String:
	return "idle"
