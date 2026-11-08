class_name ProgressionTable
extends Resource
## The numbers of progression, as data: how much XP each level costs,
## what a level grants, and what a fight is worth. Every value here is a
## placeholder to be tuned against real content (the quarry), not a
## balance decision.
##
## A level grants the same bundle to every party member: points for the
## attribute and skill point-buys plus a number of ability picks, spent in
## character creation's level-up mode (see character_creation.gd). Unspent
## points carry over.

## Total XP needed to REACH each level, from level 2 up: index 0 is level
## 2, index 1 is level 3, and so on. Past the end there is no next level.
@export var xp_to_reach: Array[int] = [100, 250, 450, 700, 1000, 1400, 1900, 2500, 3200]

@export_group("Per level")
@export var attribute_points: int = 3
@export var skill_points: int = 3
@export var ability_picks: int = 1

@export_group("Encounters")
## XP for each foe defeated, times that foe's UnitDefinition.level.
@export var xp_per_foe_level: int = 25

@export_group("Learnable")
## Abilities that never appear on the level-up list: the ones every unit
## is born with, the ones weapons and summons grant, and the ones only a
## demon's body can do. Everything else in data/abilities is buyable,
## with no prerequisites.
@export var not_learnable: Array[Ability] = []


## The level a party with `xp` has reached. Level 1 needs nothing.
func level_for(xp: int) -> int:
	var level: int = 1
	for threshold in xp_to_reach:
		if xp < threshold:
			break
		level += 1
	return level


## Total XP to reach the level after `level`, or -1 at the cap.
func xp_for_next(level: int) -> int:
	var index: int = level - 1
	if index < 0 or index >= xp_to_reach.size():
		return -1
	return xp_to_reach[index]


## Total XP that reached `level` (0 for level 1).
func xp_for(level: int) -> int:
	if level <= 1:
		return 0
	return xp_to_reach[mini(level - 2, xp_to_reach.size() - 1)]


func is_learnable(ability: Ability) -> bool:
	if ability == null:
		return false
	for excluded in not_learnable:
		if excluded != null and excluded.ability_name == ability.ability_name:
			return false
	return true
