extends Button

@export var esc_menu: Control

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		esc_menu.visible = !esc_menu.visible

func _ready() -> void:
	if esc_menu.visible:
		esc_menu.visible = false


func _on_pressed() -> void:
	esc_menu.visible = !esc_menu.visible
