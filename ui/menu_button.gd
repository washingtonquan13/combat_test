extends Button
## Escape handling for the esc menu now lives centrally in UIStack (see
## that autoload's own _unhandled_input) — this button just toggles the
## same screen UIStack would fall back to opening on Escape, found the
## same way (the "esc_menu" group), rather than holding its own
## NodePath export to it.

func _on_pressed() -> void:
	var esc_menu: UIScreen = get_tree().get_first_node_in_group("esc_menu")
	if not esc_menu:
		return
	if UIStack.is_open(esc_menu):
		UIStack.pop(esc_menu)
	else:
		UIStack.push(esc_menu)
