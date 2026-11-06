@tool
class_name SocketOverlay
extends Control
## Draws an item's sockets over its art, one per cell in reading order.
## An axis with no full line is centred: if no row of sockets spans the
## item's width they are centred across it, and if no column spans its
## height they are centred down it. A full line pins that axis to the
## cells, short last row included. A copy never has more sockets than
## cells (ItemInstance.max_sockets), so they always fit. A filled socket
## shows its rune. The look is socket.tscn's, authored at 42 px and
## scaled to the cell here, so the bag and the tooltip's 2x art share
## one design.

## Fraction of a cell a socket spans.
const SOCKET_SPAN := 0.66

@export var socket_scene: PackedScene = preload("res://systems/inventory_system/socket.tscn")


func show_sockets(item: ItemInstance, cell: float) -> void:
	for socket in get_children():
		socket.queue_free()
	if not item or item.sockets == 0:
		return
	var width: int = item.definition.width
	var height: int = item.definition.height
	var rows: int = ceili(float(item.sockets) / width)
	# Cells to shift the whole group by, per axis.
	var shift := Vector2(
		(width - item.sockets) / 2.0 if item.sockets < width else 0.0,
		(height - rows) / 2.0 if rows < height else 0.0)
	for i in item.sockets:
		var socket: Control = socket_scene.instantiate()
		var side := cell * SOCKET_SPAN
		socket.scale = Vector2.ONE * side / socket.custom_minimum_size.x
		var center := (Vector2(i % width, i / width) + shift + Vector2(0.5, 0.5)) * cell
		socket.position = center - Vector2.ONE * side / 2
		if i < item.runes.size():
			socket.get_node("Rune").texture = item.runes[i].icon
		add_child(socket)
