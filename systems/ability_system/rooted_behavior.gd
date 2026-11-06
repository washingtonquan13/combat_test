class_name RootedBehavior
extends StatusBehavior
## Holds the unit where it stands — Webbed. Unlike IncapacitateBehavior
## it may still attack and cast; it just can't walk, in combat or out
## (see Unit.is_rooted(), which zeroes Move and makes move_to() refuse).
##
## Caught mid-walk — stepping into a web — it stops on the spot and the
## rest of this turn's move is gone, not kept for after it breaks free.
##
## Breaking free on its own turn gives that turn's move back: the budget
## is set before statuses tick at turn start, while Move still read 0, so
## a web that runs out (or is shrugged off with ST) as the turn begins
## would otherwise still cost the whole turn's walk.


func on_apply(unit: Unit, _active: ActiveStatus) -> void:
	if unit.is_moving():
		unit.stop_moving()
	unit.spend_move(unit.move_remaining)


func on_remove(unit: Unit, _active: ActiveStatus, _voluntary: bool = false) -> void:
	if unit.in_combat() and unit.is_my_turn() and not unit.is_rooted():
		unit.move_remaining = unit.move_per_turn()


func prevents_movement() -> bool:
	return true


func describe() -> String:
	return "Can't move"
