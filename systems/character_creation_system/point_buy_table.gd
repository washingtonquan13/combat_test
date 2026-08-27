class_name PointBuyTable
extends Resource
## A value -> cost lookup for point-buy character creation, plus the
## bounds and pool it's played against. One reusable shape for both
## attributes (Bucket A) and skills (Bucket C) — their curves are
## mathematically the same escalating shape (confirmed by direct
## comparison: Bucket A's costs for +1..+8 relative to baseline, 1, 2, 3,
## 5, 7, 10, 13, 17, match Bucket C's table exactly), they just apply to
## a different "value" (an attribute's literal 7-18 score vs. a skill's
## relative -1..+8 level) and a different pool size. Kept as data, not
## hardcoded like FactionRelations' tiers, because both buckets'
## own source material explicitly calls the pool size and (for skills)
## the table's own upper end "campaign power" knobs meant to be tuned,
## not a fixed, closed set of concepts.
##
## Bucket B (secondary attributes — Will/Perception/HP/FP/Move becoming
## derived from primary attributes instead of independent Unit fields)
## is deliberately NOT built here — it needs a real Unit data-model
## change first (those 5 fields are currently independent, hand-authored
## exports, not computed), which is its own follow-up decision, not
## something to fold into this pass. See faction_relation_party_system.md.

## value -> cost. Godot's typed-Dictionary export shows as a real
## Inspector table, not a blob of text to hand-edit blind.
@export var costs: Dictionary[int, int] = {}
@export var min_value: int = 7
@export var max_value: int = 18
## The value a stat starts at before any points are spent — NOT
## necessarily cost 0 in `costs` for every possible table (it always is
## for both buckets today, but nothing here assumes that).
@export var default_value: int = 10
@export var point_pool: int = 20


func cost_for(value: int) -> int:
	return costs.get(value, 0)


func total_cost(values: Dictionary) -> int:
	var total: int = 0
	for key in values:
		total += cost_for(values[key])
	return total


func points_remaining(values: Dictionary) -> int:
	return point_pool - total_cost(values)


## "All points must be spent" (both buckets' own stated rule) means
## exactly zero remaining, not merely non-negative — <= 0 would silently
## accept underspending as valid too.
func is_valid(values: Dictionary) -> bool:
	for key in values:
		var value: int = values[key]
		if value < min_value or value > max_value:
			return false
	return points_remaining(values) == 0
