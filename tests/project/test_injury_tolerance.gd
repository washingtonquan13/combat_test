extends AiTestCase
## Injury Tolerance (B380) over the body plan: Unliving cuts piercing,
## Homogeneous has no vitals, Diffuse caps a hit except from an area, an
## immunity takes nothing, and No Vitals on its own sends a vitals hit to
## the torso.

const W := DamageResolver.WoundType


func wants_world() -> bool:
	return true


func run() -> void:
	var unliving: InjuryPreset = load("res://data/injury_presets/unliving.tres")
	var homogeneous: InjuryPreset = load("res://data/injury_presets/homogeneous.tres")
	var diffuse: InjuryPreset = load("res://data/injury_presets/diffuse.tres")
	var vitals: HitLocation = load("res://data/hit_locations/vitals.tres")

	var target: Unit = spawn_unit(&"enemy", 10, 10, 30, [melee()], Vector3(1.0, 0.0, 0.0))
	target.injury_preset = unliving
	check("unliving: 9 pi does 3", DamageResolver.injury(9, target, W.PIERCING) == 3)

	target.injury_preset = homogeneous
	var stab: int = DamageResolver.injury(8, target, W.IMPALING, 1.0, false, false, vitals)
	check("homogeneous: an imp to the vitals is the torso's x1/2", stab == 4, "got %d" % stab)

	target.injury_preset = diffuse
	check("diffuse: 20 cutting does 2", DamageResolver.injury(20, target, W.CUTTING) == 2)
	check("diffuse: an area blast is not capped",
		DamageResolver.injury(20, target, W.CRUSHING, 1.0, false, false, null, true) == 20)

	var fireproof := InjuryPreset.new()
	var immune := InjuryRule.new()
	immune.value = 0.0
	var burning: Array[DamageResolver.WoundType] = [W.BURNING]
	immune.wound_types = burning
	var rules: Array[InjuryRule] = [immune]
	fireproof.rules = rules
	target.injury_preset = fireproof
	check("an immunity to burning takes nothing", DamageResolver.injury(20, target, W.BURNING) == 0)

	target.injury_preset = null
	var missing: Array[HitLocation] = [vitals]
	target.missing_locations = missing
	check("no vitals: a pi hit to the vitals is the torso's x1",
		DamageResolver.injury(8, target, W.PIERCING, 1.0, false, false, vitals) == 8)
	free_spawned()
