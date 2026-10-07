class_name DemonSheet
extends MarginContainer
## One demon's numbers, for choosing between demons: the fusion menu's
## three tabs are three of these.
##
## Shows a SPECIES, optionally with the individual that owns it. The
## result of a fusion does not exist yet, so it has no current HP — it is
## shown at full, which is what it will be born with. An owned demon shows
## the HP and FP it is carrying right now.
##
## Every bar's range is set on the bar in the .tscn, not here, so "how full
## is a 14 ST" is changed in the inspector.

@onready var _empty: Label = %EmptyLabel
@onready var _details: Control = %Details
@onready var _name: Label = %NameLabel
@onready var _race: Label = %RaceLabel
@onready var _vitals: Label = %VitalsLabel
@onready var _skills: Label = %SkillsLabel
@onready var _attributes: Array = [
	[%StBar, %StValue],
	[%DxBar, %DxValue],
	[%IqBar, %IqValue],
	[%HtBar, %HtValue],
]


## Fills the sheet. A null species shows the empty text instead.
func show_demon(species: UnitDefinition, owned: OwnedDemon = null) -> void:
	_empty.visible = species == null
	_details.visible = species != null
	if species == null:
		return
	_name.text = species.display_name
	var race: String = String(species.order) if species.order != &"" else "No race"
	_race.text = "%s   Rank %d" % [race, species.rank]
	var hp: int = owned.current_hp if owned else species.max_hp
	var fp: int = owned.current_fp if owned else species.max_fp
	_vitals.text = "HP %d/%d   FP %d/%d   DR %d" % [
		hp, species.max_hp, fp, species.max_fp, species.damage_reduction]
	var values: Array[int] = [species.strength, species.dexterity, species.intelligence, species.health]
	for i in _attributes.size():
		(_attributes[i][0] as ProgressBar).value = values[i]
		(_attributes[i][1] as Label).text = str(values[i])
	var names: PackedStringArray = []
	for ability in species.abilities:
		if ability:
			names.append(ability.ability_name)
	_skills.text = ", ".join(names) if not names.is_empty() else "None"
