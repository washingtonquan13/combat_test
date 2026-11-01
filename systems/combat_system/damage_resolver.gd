class_name DamageResolver
extends RefCounted
## The one place a damage roll becomes injury. Every effect that hurts a
## unit — ability damage, damage over time, a fall — goes through
## injury(), and the AI prices the same hit through expected_injury(), so
## the two can never disagree about what armor does. Armor divisors
## (B378) belong here, once, when they land.

## GURPS damage types (B379). Hit locations are cut, so every hit takes
## the torso's wounding multiplier. Fatigue damage (FP, not HP) is not
## modelled.
enum WoundType {
	CRUSHING,
	CUTTING,
	IMPALING,
	SMALL_PIERCING,
	PIERCING,
	LARGE_PIERCING,
	HUGE_PIERCING,
	BURNING,
	CORROSION,
	TOXIC,
}

const WOUNDING_MULTIPLIER: Dictionary = {
	WoundType.CRUSHING: 1.0,
	WoundType.CUTTING: 1.5,
	WoundType.IMPALING: 2.0,
	WoundType.SMALL_PIERCING: 0.5,
	WoundType.PIERCING: 1.0,
	WoundType.LARGE_PIERCING: 1.5,
	WoundType.HUGE_PIERCING: 2.0,
	WoundType.BURNING: 1.0,
	WoundType.CORROSION: 1.0,
	WoundType.TOXIC: 1.0,
}

## GURPS's own shorthand, for ability and weapon descriptions.
const ABBREVIATION: Dictionary = {
	WoundType.CRUSHING: "cr",
	WoundType.CUTTING: "cut",
	WoundType.IMPALING: "imp",
	WoundType.SMALL_PIERCING: "pi-",
	WoundType.PIERCING: "pi",
	WoundType.LARGE_PIERCING: "pi+",
	WoundType.HUGE_PIERCING: "pi++",
	WoundType.BURNING: "burn",
	WoundType.CORROSION: "cor",
	WoundType.TOXIC: "tox",
}

## Distributions already worked out, "count:sides" -> PackedFloat64Array
## of P(sum = count + i). The AI asks for the same few dice constantly.
static var _distributions: Dictionary = {}


## What a rolled `raw` does to target: DR off (B378), then the wounding
## multiplier, rounded down — but anything that gets through DR does at
## least 1 (B379). A critical hit ignores DR, as does damage that
## bypasses it outright.
static func injury(raw: int, target: Unit, wound_type: WoundType = WoundType.CRUSHING, is_critical: bool = false, ignores_dr: bool = false) -> int:
	var penetrating: int = raw
	if not (is_critical or ignores_dr or target == null):
		penetrating -= floori(target.get_stat(StatIds.DR))
	if penetrating <= 0:
		return 0
	return maxi(floori(penetrating * WOUNDING_MULTIPLIER[wound_type]), 1)


## The mean of injury() over every roll of count d sides + bonus — exact,
## not average-minus-DR: 1d-2 against DR 2 still hurts a third of the
## time. No target is the roll before armor, for "does this ability deal
## damage at all".
static func expected_injury(count: int, sides: int, bonus: int, target: Unit = null, wound_type: WoundType = WoundType.CRUSHING, ignores_dr: bool = false) -> float:
	if count <= 0 or sides <= 0:
		return float(injury(bonus, target, wound_type, false, ignores_dr))
	var distribution: PackedFloat64Array = _distribution(count, sides)
	var expected: float = 0.0
	for i in distribution.size():
		expected += distribution[i] * injury(count + i + bonus, target, wound_type, false, ignores_dr)
	return expected


static func describe(wound_type: WoundType) -> String:
	return ABBREVIATION[wound_type]


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
