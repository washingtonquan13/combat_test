extends Control

func _on_exit_to_desktop_pressed() -> void:
	get_tree().quit()


func _on_exit_button_pressed() -> void:
	visible = !visible
