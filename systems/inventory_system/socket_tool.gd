class_name SocketTool
extends ItemDefinition
## Crafting currency: dragged onto an item, adds one empty socket, up to
## the item's maximum (ItemInstance.max_sockets).


func can_apply_to(target: ItemInstance) -> bool:
	return target.sockets < target.max_sockets()


func apply_to(target: ItemInstance) -> void:
	target.add_socket()
