extends UIScreen
## blocks_input_below=true is authored on this scene's instance in
## MainRoot.tscn — see UIScreen's own header. hides_hud/closes_on_cancel
## stay at their defaults (false, true): the pause menu doesn't hide the
## gameplay HUD today, and Escape closes it like any other screen.

func _ready() -> void:
	visible = false
	add_to_group("esc_menu")


func _on_exit_to_desktop_pressed() -> void:
	get_tree().quit()


func _on_exit_button_pressed() -> void:
	close()
