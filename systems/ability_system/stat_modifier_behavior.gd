@tool
class_name StatModifierBehavior
extends StatusBehavior
## Contributes `amount` to `stat_name` (a StatDefinition id — "ST",
## "DR", "Move", ...; the Inspector suggests the ids in res://data/stats/) for as long as this status is active. One
## reusable behavior instead of a separate class per stat — Shield (DR,
## positive), Weaken (DR, negative), and Slow (Move, negative) are all
## just this with different stat_name/amount/icon, the same "small
## reusable piece, many .tres variations" reasoning DamageOverTimeBehavior
## already established for Bleeding/Burning/Poison.
##
## Pure data — no on_apply/on_remove. The stat's StatInstance sums
## `amount` across every registered modifier fresh each time
## Unit.get_stat() is called, the same query-at-read-time shape
## modify_incoming_attack_to_hit already uses for to-hit, rather than
## mutating and reverting a field. This is also what lets a future
## equipment modifier reuse this exact class unchanged — it only ever
## needs to be summed by whichever aggregator is asking, never told to
## apply or revert itself.
##
## @tool only for the stat-id suggestions (_validate_property).

@export var stat_name: StringName = &"DR"
@export var amount: int = 0
## Scales the finished stat, after every amount is added — 0.5 halves
## it, as Bloodied and Exhausted halve Move and Dodge. The result is
## rounded up, as GURPS rounds a halving. Multipliers do not compound:
## only the strongest one on a stat applies, so two halvings are still a
## half.
@export var multiplier: float = 1.0


func _validate_property(property: Dictionary) -> void:
	if property.name == "stat_name":
		StatDatabase.suggest_ids(property)


func describe() -> String:
	if amount == 0 and multiplier != 1.0:
		return "x%s %s" % [String.num(multiplier), stat_name]
	return "%s%d %s" % ["+" if amount >= 0 else "", amount, stat_name]
