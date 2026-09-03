extends GameArea
## The Cathedral of Shadows: a room you are IN but do not walk around.
##
## A DIEGETIC MENU. Fusion in the reference happens in a place with a
## presiding figure rather than behind a screen, and the point of making it
## an area rather than a panel is that the player travels there, stands in
## front of the device, and watches the thing they asked for happen in the
## room they are standing in.
##
## spawns_party() is false, which is the whole control story — the same
## hook the overworld uses to hold one avatar instead of four tactical
## Units, here holding none at all. With nobody spawned there is nothing to
## select, nothing to command, and nothing to move, without a single system
## needing to know this area is special.
##
## THE BASE MODE IS FACILITY, which is its own entry in the enum. This was
## EXPLORATION first, on the reasoning that looking around a cathedral is
## harmless — and that was wrong: a pushed UIScreen deliberately does not
## take camera control (see UIScreen's own header), so the menu and a
## free-panning camera would have fought each other. A room whose
## interaction is a LIST needs the camera composed, not flown.

## The demons stand on TOP of the ingredient platforms, not at their
## origins — a proto_block is centred on its transform, so a mark placed at
## the platform's own position would put a demon inside the stone.
@export var device_view: Camera3D


func _ready() -> void:
	# A subclass defining _ready() is the expected shape here: GameArea
	# deliberately has none, precisely so a subclass never has to remember
	# to call super().
	_aim_the_camera()
	_present_the_menu()


func get_base_mode() -> GameMode.Mode:
	return GameMode.Mode.FACILITY


func spawns_party() -> bool:
	return false


## Found by group rather than by path: the menu lives on MainRoot with
## every other screen, and an area should not know MainRoot's layout — the
## same reasoning GameMode uses to find the character-creation screen.
##
## Closing it again is nobody's job here. UIStack.close_all() runs when a
## world is loaded, so leaving the room takes the menu with it.
func _present_the_menu() -> void:
	var found: Node = get_tree().get_first_node_in_group(&"cathedral_menu")
	var menu := found as CathedralMenu
	if menu == null:
		# Loud, permanently. This room has no player character and no other
		# interface — without the menu there is nothing to press and no way
		# out, so failing silently strands the player in a box.
		push_warning("Cathedral: no CathedralMenu found (group had %s). " % (
			"nothing" if found == null else found.get_class()) +
			"The room has no interface and cannot be left.")
		return
	menu.present()
	if OS.is_debug_build():
		print("Cathedral: menu presented (visible=%s)." % str(menu.is_visible_in_tree()))


## Points the camera at the device rather than authoring a basis by hand.
##
## look_at needs the node to be in the tree, which is why this is _ready()
## work and not a value baked into the .tscn — and a hand-computed
## Transform3D for "look from here at there" is exactly the kind of thing
## that is wrong by a sign and nobody notices until the room renders
## backwards.
func _aim_the_camera() -> void:
	var camera: Camera3D = device_view if device_view else get_tactical_camera()
	if camera == null:
		return
	var device: Node3D = find_child(String(FusionCinematic.DEVICE_MARK), true, false) as Node3D
	if device == null:
		return
	camera.look_at_from_position(camera.global_position, device.global_position, Vector3.UP)
