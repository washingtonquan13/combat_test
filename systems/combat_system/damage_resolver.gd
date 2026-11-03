class_name DamageResolver
extends RefCounted
## The one place a damage roll becomes injury. Every effect that hurts a
## unit — ability damage, damage over time, a fall — goes through
## injury(), and the AI prices the same hit through expected_injury(), so
## the two can never disagree about what armor does.

## GURPS damage types (B379). What each does is the target's body plan
## (InjuryProfile): its torso row, or the row of the HitLocation the hit
## was aimed at. Fatigue damage (FP, not HP) is not modelled.
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


## DR as an attack with this armor divisor meets it (B378): divided,
## rounded down. A fractional divisor — (0.5), (0.2), (0.1) — is armor
## working better than usual, so it multiplies DR instead.
static func effective_dr(dr: float, armor_divisor: float = 1.0) -> int:
	if armor_divisor <= 0.0:
		return floori(dr)
	# The epsilon keeps 3 / 0.1 from landing a hair under 30.
	return floori(dr / armor_divisor + 1e-6)


## What a rolled `raw` does to target, read from the target's injury
## profile at location (null is the torso):
## 1. DR off (B378): the target's, plus the location's for this type.
##    A critical hit ignores DR, as does damage that bypasses it outright.
##    (GURPS crits roll on a table instead; skipping DR is ours.)
## 2. The wounding multiplier, rounded down, but anything that gets
##    through DR does at least 1 (B379). A multiplier of 0 is immunity.
## 3. The location's injury cap (Diffuse, B380), which an area attack
##    ignores.
## 4. The target's injury_divisor (Damage Reduction, Powers 52), after
##    the cap, rounded down, still at least 1.
static func injury(raw: int, target: Unit, wound_type: WoundType = WoundType.CRUSHING, armor_divisor: float = 1.0, is_critical: bool = false, ignores_dr: bool = false, location: HitLocation = null, is_area: bool = false) -> int:
	var profile: InjuryProfile = target.injury_profile() if target else null
	var row: BodyRow = profile.row(location) if profile else BodyPlan.human().row(location)
	var penetrating: int = raw
	if not (is_critical or ignores_dr or target == null):
		var dr: float = target.get_stat(StatIds.DR) + row.dr[wound_type]
		penetrating -= effective_dr(dr, armor_divisor)
	var multiplier: float = row.multipliers[wound_type]
	if penetrating <= 0 or multiplier <= 0.0:
		return 0
	# The epsilon keeps a stored 1/3 (float32) from flooring 9 x 1/3 to 2.
	var amount: int = maxi(floori(penetrating * multiplier + 0.0001), 1)
	var cap: int = row.max_injury[wound_type]
	if cap > 0 and not is_area:
		amount = mini(amount, cap)
	if target and target.injury_divisor > 1.0:
		amount = maxi(floori(amount / target.injury_divisor + 0.0001), 1)
	return amount


## The mean of injury() over every roll of count d sides + bonus — exact,
## not average-minus-DR: 1d-2 against DR 2 still hurts a third of the
## time. No target is the roll before armor, for "does this ability deal
## damage at all".
static func expected_injury(count: int, sides: int, bonus: int, target: Unit = null, wound_type: WoundType = WoundType.CRUSHING, armor_divisor: float = 1.0, ignores_dr: bool = false, location: HitLocation = null, is_area: bool = false) -> float:
	if count <= 0 or sides <= 0:
		return float(injury(bonus, target, wound_type, armor_divisor, false, ignores_dr, location, is_area))
	var distribution: PackedFloat64Array = _distribution(count, sides)
	var expected: float = 0.0
	for i in distribution.size():
		expected += distribution[i] * injury(count + i + bonus, target, wound_type, armor_divisor, false, ignores_dr, location, is_area)
	return expected


## "cut", or "imp (2)" with an armor divisor — GURPS's own notation.
static func describe(wound_type: WoundType, armor_divisor: float = 1.0) -> String:
	if is_equal_approx(armor_divisor, 1.0):
		return ABBREVIATION[wound_type]
	return "%s (%s)" % [ABBREVIATION[wound_type], String.num(armor_divisor)]


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
