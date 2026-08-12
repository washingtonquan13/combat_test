class_name Chest
extends InteractableProp
## A lootable world container — InteractableProp plus a persistent
## Inventory child that holds this chest's actual contents for the life
## of the running scene. Opening a chest REPARENTS this Inventory node
## into the loot UI rather than copying/serializing its contents (see
## stash_manager.gd/stash_panel.gd) — same idiom Item/EquipSlot already
## use to move an item between containers.

@export var display_name: String = "Chest"

@onready var inventory: Inventory = $Inventory
