class_name SurvivalBonusBehavior
extends StatusBehavior
## A bonus to the HT roll made each turn while Downed, the roll that decides
## death. Not to the roll for staying on your feet.

@export var amount: int = 1


func at_level(level: int) -> StatusBehavior:
	if level == 1:
		return self
	var scaled: SurvivalBonusBehavior = duplicate()
	scaled.amount = amount * level
	return scaled


func survival_roll_bonus() -> int:
	return amount


func describe() -> String:
	return "%+d HT to survive while Downed" % amount
