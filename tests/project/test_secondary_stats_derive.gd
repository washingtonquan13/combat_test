extends AiTestCase
## HP, FP, Will, Perception and Move derive from the attributes (see
## DerivedStats). An authored unit keeps the numbers it had before they
## did, through its bonuses, and a raised attribute carries through.


func wants_world() -> bool:
	return false


func run() -> void:
	var unit: Unit = load("res://systems/unit_system/unit.tscn").instantiate()
	# Authored before derivation as HP 14, FP 14, Will 8, Per 12, Move 5.
	unit.definition = load("res://data/units/demons/beast.tres")
	var before := [unit.maximum_hp, unit.maximum_fp, unit.will, unit.perception, unit.move]
	check("a migrated species keeps its authored secondaries",
		before == [14, 14, 8, 12, 5], "got HP/FP/Will/Per/Move %s" % [before])

	unit.strength += 2
	unit.intelligence += 2
	unit.health += 4
	var after := [unit.maximum_hp, unit.maximum_fp, unit.will, unit.perception, unit.move]
	check("raising an attribute raises what derives from it",
		after == [16, 18, 10, 14, 6], "got HP/FP/Will/Per/Move %s" % [after])
	unit.free()
