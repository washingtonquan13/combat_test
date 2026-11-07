class_name IdentifyScroll
extends ItemDefinition
## Crafting currency: dragged onto an unidentified item, reveals it — and
## its affixes start working (see ItemInstance.identified).


func can_apply_to(target: ItemInstance) -> bool:
	return not target.identified


func apply_to(target: ItemInstance) -> void:
	target.identify()
