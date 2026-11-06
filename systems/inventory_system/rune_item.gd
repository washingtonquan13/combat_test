class_name RuneItem
extends ItemDefinition
## A rune: dragged onto an item with a free socket, it fills that socket
## for good — no removing it, no socketing over it. What it does depends
## on what it went into, the way Path of Exile 2's runes read one line on
## a weapon and another on armour: on_weapon for anything with attack
## rows (a shield counts as armour), on_armor for the rest.

@export var on_weapon: ItemModifier
@export var on_armor: ItemModifier


## The half that applies to target, or null when this rune does nothing
## there.
func modifier_for(target: ItemInstance) -> ItemModifier:
	return on_weapon if target.is_weapon() else on_armor


func can_apply_to(target: ItemInstance) -> bool:
	return target.free_sockets() > 0 and modifier_for(target) != null


func apply_to(target: ItemInstance) -> void:
	target.insert_rune(self)
