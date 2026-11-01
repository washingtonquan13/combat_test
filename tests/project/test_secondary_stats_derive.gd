extends AiTestCase
## HP, FP, Will, Per and Move derive from the primaries through their
## res://data/stats/ formulas. An authored unit keeps the numbers it had
## before they did, through its bought bonuses, and a raised primary
## carries through.


func wants_world() -> bool:
	return false


func run() -> void:
	var unit: Unit = load("res://systems/unit_system/unit.tscn").instantiate()
	# Authored before derivation as HP 14, FP 14, Will 8, Per 12, Basic
	# Move 5, through its bonus.
	unit.definition = load("res://data/units/demons/beast.tres")
	var before := _derived(unit)
	check("a migrated species keeps its authored secondaries",
		before == [14, 14, 8, 12, 5], "got HP/FP/Will/Per/Move %s" % [before])

	unit.set_base_stat(StatIds.ST, unit.get_base_stat(StatIds.ST) + 2)
	unit.set_base_stat(StatIds.IQ, unit.get_base_stat(StatIds.IQ) + 2)
	unit.set_base_stat(StatIds.HT, unit.get_base_stat(StatIds.HT) + 4)
	var after := _derived(unit)
	check("raising an attribute raises what derives from it",
		after == [16, 18, 10, 14, 6], "got HP/FP/Will/Per/Move %s" % [after])
	unit.free()


func _derived(unit: Unit) -> Array:
	return [StatIds.HP, StatIds.FP, StatIds.WILL, StatIds.PER, StatIds.MOVE].map(
		func(id: StringName) -> int: return int(unit.get_stat(id)))
