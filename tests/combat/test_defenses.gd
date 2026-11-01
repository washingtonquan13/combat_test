extends AiTestCase
## Parry and Block: the defender rolls the highest defense it has; Parry
## loses 4 per parry, Block works once and needs a shield, and both come
## back on the defender's own turn.

const ITEM_SCENE: PackedScene = preload("res://systems/inventory_system/item.tscn")


func wants_world() -> bool:
	return true


func run() -> void:
	var attacker: Unit = spawn_unit(&"player", 10, 10, 10, [melee(), ranged()], Vector3.ZERO)
	# DX 12: Basic Attack 12, Parry 9 against Dodge 8.
	var defender: Unit = spawn_unit(&"enemy", 10, 12, 10, [melee()], Vector3(1.5, 0.0, 0.0))
	check("a melee hit is parried at 3 + half Basic Attack",
		defender.best_defense(attacker, melee()) == {"kind": &"parry", "target": 9})
	check("a ranged hit is not parried",
		defender.best_defense(attacker, ranged()).kind == &"dodge")

	defender.spend_defense(&"parry")
	check("a second parry is at -4, so Dodge is better",
		defender.best_defense(attacker, melee()).kind == &"dodge")
	defender.reset_turn_actions()
	check("parries come back on the defender's turn",
		defender.best_defense(attacker, melee()).target == 9)

	var shield: Item = ITEM_SCENE.instantiate()
	shield.definition = load("res://data/items/wooden_shield.tres")
	defender.equip_item(EquipSlot.Slot.MELEE_OFF_HAND, shield)
	check("a shield's DB raises Dodge too", defender._combat.dodge_target() == 10)
	check("a shield blocks a ranged hit",
		defender.best_defense(attacker, ranged()) == {"kind": &"block", "target": 11})
	defender.spend_defense(&"block")
	check("only once per turn",
		defender.best_defense(attacker, ranged()) == {"kind": &"dodge", "target": 10})
	defender.unequip_item(EquipSlot.Slot.MELEE_OFF_HAND).free()
	free_spawned()
