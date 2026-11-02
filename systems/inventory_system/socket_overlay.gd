@tool
class_name SocketOverlay
extends Control
## Draws an item's sockets over its art the way Path of Exile does: one
## socket per grid cell, in reading order, centred in the cell. A copy
## never has more sockets than cells (ItemInstance.max_sockets), so they
## always fit. A filled socket shows its rune. The look is socket.tscn's,
## authored at 42 px and scaled to the cell here, so the bag and the
## tooltip's 2x art share one design.

## Fraction of a cell a socket spans.
const SOCKET_SPAN := 0.66

@export var socket_scene: PackedScene = preload("res://systems/inventory_system/socket.tscn")


func show_sockets(item: ItemInstance, cell: float) -> void:
	for socket in get_children():
		socket.queue_free()
	if not item or item.sockets == 0:
		return
	var columns: int = item.definition.width
	for i in item.sockets:
		var socket: Control = socket_scene.instantiate()
		var side := cell * SOCKET_SPAN
		socket.scale = Vector2.ONE * side / socket.custom_minimum_size.x
		var center := (Vector2(i % columns, i / columns) + Vector2(0.5, 0.5)) * cell
		socket.position = center - Vector2.ONE * side / 2
		if i < item.runes.size():
			socket.get_node("Rune").texture = item.runes[i].icon
		add_child(socket)
