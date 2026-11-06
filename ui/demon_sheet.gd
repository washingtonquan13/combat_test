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
## Stat id -> [bar, value label].
@onready var _attributes: Dictionary = {
	StatIds.ST: [%StBar, %StValue],
	StatIds.DX: [%DxBar, %DxValue],
	StatIds.IQ: [%IqBar, %IqValue],
	StatIds.HT: [%HtBar, %HtValue],
}


## Fills the sheet. A null species shows the empty text instead.
func show_demon(species: UnitDefinition, owned: OwnedDemon = null) -> void:
	_empty.visible = species == null
	_details.visible = species != null
	if species == null:
		return
	_name.text = species.display_name
	var race: String = String(species.order) if species.order != &"" else "No race"
	_race.text = "%s   Rank %d" % [race, species.rank]
	var max_hp: int = floori(species.stat_value(StatIds.HP))
	var max_fp: int = floori(species.stat_value(StatIds.FP))
	var hp: int = owned.get_pool(StatIds.HP) if owned else max_hp
	var fp: int = owned.get_pool(StatIds.FP) if owned else max_fp
	_vitals.text = "HP %d/%d   FP %d/%d   DR %d" % [
		hp, max_hp, fp, max_fp, species.stat_value(StatIds.DR)]
	for id in _attributes:
		var value: float = species.stat_value(id)
		(_attributes[id][0] as ProgressBar).value = value
		(_attributes[id][1] as Label).text = StatDefinition.format(value)
	var names: PackedStringArray = []
	for ability in species.abilities:
		if ability:
			names.append(ability.ability_name)
	_skills.text = ", ".join(names) if not names.is_empty() else "None"
