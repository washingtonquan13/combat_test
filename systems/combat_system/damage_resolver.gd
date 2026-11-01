class_name DamageResolver
extends RefCounted
## The one place a damage roll becomes injury. Every effect that hurts a
## unit — ability damage, damage over time, a fall — goes through
## injury(), and the AI prices the same hit through expected_injury(), so
## the two can never disagree about what armor does. Wounding multipliers
## and armor divisors (B378-379) belong here, once, when they land.

## Distributions already worked out, "count:sides" -> PackedFloat64Array
## of P(sum = count + i). The AI asks for the same few dice constantly.
static var _distributions: Dictionary = {}


## What a rolled `raw` does to target: DR off (B378), never below 0. A
## critical hit ignores DR, as does damage that bypasses it outright.
static func injury(raw: int, target: Unit, is_critical: bool = false, ignores_dr: bool = false) -> int:
	if is_critical or ignores_dr or target == null:
		return maxi(raw, 0)
	return maxi(raw - floori(target.get_stat(StatIds.DR)), 0)


## The mean of injury() over every roll of count d sides + bonus — exact,
## not average-minus-DR: 1d-2 against DR 2 still hurts a third of the
## time. No target is the raw roll, floored at 0, for "does this ability
## deal damage at all".
static func expected_injury(count: int, sides: int, bonus: int, target: Unit = null, ignores_dr: bool = false) -> float:
	if count <= 0 or sides <= 0:
		return float(injury(bonus, target, false, ignores_dr))
	var distribution: PackedFloat64Array = _distribution(count, sides)
	var expected: float = 0.0
	for i in distribution.size():
		expected += distribution[i] * injury(count + i + bonus, target, false, ignores_dr)
	return expected


static func _distribution(count: int, sides: int) -> PackedFloat64Array:
	var key: String = "%d:%d" % [count, sides]
	if _distributions.has(key):
		return _distributions[key]
	# Sum over dice, one die at a time: index i is a total of (dice so
	# far) + i.
	var distribution := PackedFloat64Array([1.0])
	for _die in count:
		var next := PackedFloat64Array()
		next.resize(distribution.size() + sides - 1)
		for i in distribution.size():
			for face in sides:
				next[i + face] += distribution[i] / sides
		distribution = next
	_distributions[key] = distribution
	return distribution
