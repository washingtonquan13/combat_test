extends PopupPanel

@onready var equip_button: Button = $VBoxContainer/Equip
@onready var drop_button: Button = $VBoxContainer/Drop
@onready var inspect_button: Button = $VBoxContainer/Inspect

var target_item: Item = null

func _ready() -> void:
	equip_button.pressed.connect(_on_equip_pressed)
	drop_button.pressed.connect(_on_drop_pressed)
	inspect_button.pressed.connect(_on_inspect_pressed)
	popup_hide.connect(queue_free)

func setup(item: Item) -> void:
	target_item = item

func _on_equip_pressed() -> void:
	if is_instance_valid(target_item):
		for slot in get_tree().get_nodes_in_group("equip_slots"):
			if slot.accepts_item(target_item):
				target_item.detach_from_current_location()
				slot.equip(target_item)
				break
	hide()

func _on_drop_pressed() -> void:
	# No world-drop system exists yet, so this discards the item outright.
	if is_instance_valid(target_item):
		target_item.detach_from_current_location()
		target_item.queue_free()
	hide()

func _on_inspect_pressed() -> void:
	# No inspect panel exists yet.
	hide()
