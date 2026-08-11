extends Node
## Autoload singleton. Register as "InteractionMenu" under
## Project > Project Settings > AutoLoad.
##
## Owns the single PopupMenu used for every right-click context menu in
## the game — one shared popup, cleared and repopulated per click, rather
## than a new Control per interactable (matches AbilityHotbar/PartyPanel's
## own "one shared component, reused" bias). A PopupMenu is a Window under
## the hood, so it doesn't need placement under main.tscn's CanvasLayer
## the way ordinary UI Controls do — parenting it to this autoload is
## enough for it to work anywhere in the game.
##
## The only caller today is ground_click_target.gd's right-click branch
## (the sole global right-click router — see that file), via open_for().
## Any interactable just needs to implement get_interactions(actor); this
## autoload doesn't know or care whether target is a Unit, a prop, or
## anything future.

var _popup: PopupMenu
var _actor: Unit
var _target: Node
var _options: Array[InteractionOption] = []


func _ready() -> void:
	_popup = PopupMenu.new()
	add_child(_popup)
	_popup.id_pressed.connect(_on_id_pressed)


## No-ops if target doesn't implement get_interactions() at all, or if it
## does but nothing it offers is currently available to actor — either
## way, right-clicking something with nothing to do should show no menu
## rather than an empty one.
func open_for(target: Node, actor: Unit) -> void:
	if not target.has_method("get_interactions"):
		return

	_options = target.get_interactions(actor)
	if _options.is_empty():
		return

	_actor = actor
	_target = target

	_popup.clear()
	for i in _options.size():
		_popup.add_item(_options[i].label, i)

	_popup.position = _get_screen_position(target)
	_popup.popup()


## Whether a menu is currently up — polled per-frame by crpg_camera.gd to
## suspend all camera input for as long as it's open (BG3 does the same:
## the camera can't rotate/pan/zoom out from under an open radial menu).
## Derived straight from the popup's own visibility rather than a
## separately-tracked bool, so it can never drift out of sync with
## whether a menu is actually on screen — true regardless of HOW it
## closes (an option picked, clicked outside, Escape), since all of
## those already resolve to Godot's own Window.hide() under the hood.
func is_open() -> bool:
	return _popup.visible


## Anchors the menu to target's own on-screen position — BG3-style ("the
## menu appears where the object is"), not an OS-context-menu-style
## cursor anchor. target is only ever reached via a 3D raycast (see
## ground_click_target.gd._get_hovered_interactable), so it's always a
## Node3D and always actually on-screen at the moment of the click — no
## is_position_behind guard needed the way drag_select_box.gd's
## iterate-every-unit version requires.
##
## Viewport-local coordinates (get_viewport().get_mouse_position()/
## Camera3D.unproject_position()), NOT DisplayServer.mouse_get_position()
## (OS screen coordinates) — this project embeds its subwindows (Godot's
## own default, project.godot has no override), so PopupMenu.position is
## relative to the game's own viewport, not the OS desktop.
func _get_screen_position(target: Node) -> Vector2:
	var node_3d := target as Node3D
	var camera: Camera3D = get_viewport().get_camera_3d()
	if not node_3d or not camera:
		return get_viewport().get_mouse_position()
	return camera.unproject_position(node_3d.global_position)


func _on_id_pressed(id: int) -> void:
	if id < 0 or id >= _options.size():
		return
	_options[id].execute(_actor, _target)
