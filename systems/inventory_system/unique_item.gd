class_name UniqueItem
extends Resource
## An authored unique: a base item with its own name and a fixed set of
## modifiers instead of rolled affixes. A dropped copy points at the base
## as its definition and at this as its unique (ItemInstance.unique).

## What saves name this unique by (see ItemDefinition.id).
@export var id: StringName = &""
@export var unique_name: String = ""
@export var base: GearItem
## Lowest item level it can drop at.
@export var level: int = 1
@export var modifiers: Array[ItemModifier] = []
