class_name Advantage
extends Resource
## One trait a character can have, as data: what it changes (behaviors,
## the same pieces a status effect is built from) and what it grants
## (abilities). A new advantage is a .tres in res://data/advantages/.
##
## Who has one, and at what level, is per-unit: see AdvantageInstance and
## UnitAdvantages. The numbers on behaviors are per level; see
## StatusBehavior.at_level.

@export var id: StringName = &""
@export var advantage_name: String = ""
@export_multiline var description: String = ""
## 1 means you have it or you don't.
@export var max_level: int = 1
@export var behaviors: Array[StatusBehavior] = []
@export var abilities: Array[Ability] = []


## Whether a second level changes anything. One behavior scaling is enough:
## a fixed rider beside a scaling number is legal.
func scales() -> bool:
	for behavior in behaviors:
		if behavior.at_level(2) != behavior:
			return true
	return false
