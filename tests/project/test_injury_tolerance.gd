extends AiTestCase
## Injury Tolerance (B380) over the body plan: Unliving cuts piercing,
## Homogeneous has no vitals, Diffuse caps a hit except from an area, an
## immunity takes nothing, and the traits merge the same in any order.

const W := DamageResolver.WoundType


func wants_world() -> bool:
	return true


func run() -> void:
	var unliving: InjuryTrait = load("res://data/injury_traits/unliving.tres")
	var homogeneous: InjuryTrait = load("res://data/injury_traits/homogeneous.tres")
	var diffuse: InjuryTrait = load("res://data/injury_traits/diffuse.tres")
	var vitals: HitLocation = load("res://data/hit_locations/vitals.tres")

	var target: Unit = spawn_unit(&"enemy", 10, 10, 30, [melee()], Vector3(1.0, 0.0, 0.0))
	target.injury_traits = [unliving]
	check("unliving: 9 pi does 3", DamageResolver.injury(9, target, W.PIERCING) == 3)

	target.injury_traits = [homogeneous]
	var stab: int = DamageResolver.injury(8, target, W.IMPALING, 1.0, false, false, vitals)
	check("homogeneous: an imp to the vitals is the torso's x1/2", stab == 4, "got %d" % stab)

	target.injury_traits = [diffuse]
	check("diffuse: 20 cutting does 2", DamageResolver.injury(20, target, W.CUTTING) == 2)
	check("diffuse: an area blast is not capped",
		DamageResolver.injury(20, target, W.CRUSHING, 1.0, false, false, null, true) == 20)

	var fireproof := InjuryTrait.new()
	var immune := InjuryRule.new()
	immune.op = InjuryRule.Op.SET
	immune.value = 0.0
	var burning: Array[DamageResolver.WoundType] = [W.BURNING]
	immune.wound_types = burning
	var rules: Array[InjuryRule] = [immune]
	fireproof.rules = rules
	target.injury_traits = [fireproof]
	check("an immunity to burning takes nothing", DamageResolver.injury(20, target, W.BURNING) == 0)

	var forward: Array[InjuryTrait] = [diffuse, homogeneous, fireproof]
	var backward: Array[InjuryTrait] = [fireproof, homogeneous, diffuse]
	var one: InjuryProfile = InjuryProfile.build(BodyPlan.human(), forward)
	var other: InjuryProfile = InjuryProfile.build(BodyPlan.human(), backward)
	var same: bool = true
	for i in one.rows().size():
		for t in W.size():
			var a: BodyRow = one.rows()[i]
			var b: BodyRow = other.rows()[i]
			same = same and not a.differs_from(b, t)
	check("trait order doesn't change the result", same)
	free_spawned()
