class_name TravelInteraction
extends InteractionOption
## Right-click "Travel" — available on anything carrying an AreaExit
## child (see area_exit.gd), the context-menu counterpart to
## overworld_door.gd's walk-in trigger. Same division of responsibility
## LootInteraction/StashComponent already use: this only decides WHETHER
## and starts it, AreaExit.travel() owns the actual resolve-and-load.

func is_available(_actor: Unit, target) -> bool:
	return target is Node and AreaExit.find_on(target) != null


func execute(_actor: Unit, target) -> void:
	var exit: AreaExit = AreaExit.find_on(target)
	if not exit:
		return
	# Must close BEFORE travel() fires — WorldManager.can_load() refuses
	# a load for as long as InteractionMenu.is_open() is true, and
	# _on_id_pressed dispatches this execute() without closing first.
	InteractionMenu.close()
	exit.travel()
