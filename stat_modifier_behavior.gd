class_name StatModifierBehavior
extends StatusBehavior
## Temporarily adds `amount` to `stat_name` (a plain Unit property name —
## damage_reduction, move, strength, ...) for as long as this status is
## active, reverting the exact same amount on removal. One reusable
## behavior instead of a separate class per stat — Shield (damage_reduction,
## positive), Weaken (damage_reduction, negative), and Slow (move,
## negative) are all just this with different stat_name/amount/icon, the
## same "small reusable piece, many .tres variations" reasoning
## DamageOverTimeBehavior already established for Bleeding/Burning/Poison.
##
## Uses Object.set()/get() (Unit is a Node, a plain Object underneath) to
## reach an arbitrary property by name rather than needing a dedicated
## field-and-branch per stat. Only meaningful for numeric @export stats
## that are read fresh where they're used (damage_reduction is read live
## every hit; move is read fresh into move_remaining at reset_turn_actions
## each turn) — reverting the SAME delta back on_remove is what keeps this
## safe even if the stat was also changed by something else while active,
## as long as that something else doesn't ALSO revert relative to a stale
## snapshot; two simultaneous StatModifierBehaviors on the same stat both
## add/revert their own delta independently and compose correctly.

@export var stat_name: String = "damage_reduction"
@export var amount: int = 0


func on_apply(unit: Unit, _active: ActiveStatus) -> void:
	unit.set(stat_name, unit.get(stat_name) + amount)


func on_remove(unit: Unit, _active: ActiveStatus) -> void:
	unit.set(stat_name, unit.get(stat_name) - amount)


func describe() -> String:
	return "%s%d %s" % ["+" if amount >= 0 else "", amount, stat_name]
