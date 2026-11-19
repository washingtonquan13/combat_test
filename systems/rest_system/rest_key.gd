extends Node
## R takes a short rest (Rest.short_rest), wherever the party is, out of
## combat. A key read here rather than an InputMap action, the same as the
## hotbar's F swap (dock.gd). Part of the rest system; see
## docs/systems/rest.md.


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.ctrl_pressed or event.alt_pressed or event.meta_pressed or event.shift_pressed:
		return
	if (event as InputEventKey).physical_keycode != KEY_R:
		return
	get_viewport().set_input_as_handled()
	Rest.short_rest()
