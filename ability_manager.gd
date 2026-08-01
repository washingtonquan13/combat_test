extends Node
## Autoload singleton. Register as "AbilityManager" under
## Project > Project Settings > AutoLoad.
##
## Tracks which ability is currently "armed" for click-to-target — this
## is the hook the upcoming ability hotbar will drive (arm an ability by
## clicking its hotbar slot, then click a target). Until the hotbar
## exists, nothing calls arm() yet, so armed_ability stays null and click
## routing (Unit._on_input_event) falls back to whichever unit is acting
## and uses ITS OWN default ability — basic attacks keep working today
## without waiting on hotbar UI to exist.

signal ability_armed(ability: Ability)

var armed_ability: Ability = null


func arm(ability: Ability) -> void:
	armed_ability = ability
	ability_armed.emit(ability)


func disarm() -> void:
	if armed_ability == null:
		return
	armed_ability = null
	ability_armed.emit(null)
