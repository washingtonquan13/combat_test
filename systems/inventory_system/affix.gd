class_name Affix
extends Resource
## One rollable line on a magic or rare copy: a prefix ("Sharp Iron
## Sword") or a suffix ("Iron Sword of the Hawk"). What it does is an
## ItemModifier, the same one a rune carries, so a copy's runes and
## affixes reach its attacks and its wearer the same way (see
## ItemInstance.modifiers).
##
## Tiers of the same line ("Sharp" +1 damage, "Keen" +2) are separate
## affixes sharing a group: a copy never carries two from one group, and
## level keeps the higher tiers off low-level drops.

enum Kind { PREFIX, SUFFIX }

## What saves name this affix by — never its path (see ItemDefinition.id).
@export var id: StringName = &""
@export var kind: Kind = Kind.PREFIX
## "Sharp" for a prefix, "of the Hawk" for a suffix.
@export var affix_name: String = ""
## Tiers of one line share a group; a copy holds at most one per group.
@export var group: StringName = &""
## Lowest item level that can roll it.
@export var level: int = 1
## Odds against the other affixes that could roll, not a percentage.
@export var weight: int = 100
@export var on_weapons: bool = false
## Armour, shields and accessories: any gear without attack rows of its
## own (ItemInstance.is_weapon).
@export var on_armor: bool = false
@export var modifier: ItemModifier


func can_roll_on(item: ItemInstance) -> bool:
	if not item.gear_data or item.item_level < level:
		return false
	return on_weapons if item.is_weapon() else on_armor
