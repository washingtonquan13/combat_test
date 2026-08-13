class_name StatModifierBehavior
extends StatusBehavior
## Contributes `amount` to `stat_name` (one of Unit.get_stat()'s names —
## "ST", "DR", "Move", ...) for as long as this status is active. One
## reusable behavior instead of a separate class per stat — Shield (DR,
## positive), Weaken (DR, negative), and Slow (Move, negative) are all
## just this with different stat_name/amount/icon, the same "small
## reusable piece, many .tres variations" reasoning DamageOverTimeBehavior
## already established for Bleeding/Burning/Poison.
##
## Pure data — no on_apply/on_remove. StatusManager.stat_modifier() sums
## `amount` across every active status matching stat_name fresh each time
## Unit.get_stat() is called, the same query-at-read-time shape
## modify_incoming_attack_to_hit already uses for to-hit, rather than
## mutating and reverting a field. This is also what lets a future
## equipment modifier reuse this exact class unchanged — it only ever
## needs to be summed by whichever aggregator is asking, never told to
## apply or revert itself.

@export var stat_name: String = "DR"
@export var amount: int = 0


func describe() -> String:
	return "%s%d %s" % ["+" if amount >= 0 else "", amount, stat_name]
