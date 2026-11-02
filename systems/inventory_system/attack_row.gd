class_name AttackRow
extends Resource
## One way to attack with something — one line of a GURPS weapon table
## (B271): a broadsword has a swing row and a thrust row, a spear a
## one-handed and a two-handed thrust. A weapon lists its rows
## (WeaponData.attacks); a creature lists its natural ones (claws,
## teeth — UnitDefinition.natural_attacks). Each row becomes its own
## pickable attack on the hotbar: see Unit.combat_abilities(), which
## binds a row to a copy of the generic melee/ranged attack ability.
##
## Every row rolls against Basic Attack, the one attack skill — rows
## differ in damage and reach, not in which skill they test.

enum Kind { MELEE, RANGED }
## Which dice table the roll reads. SWING/THRUST are the wielder's own
## ST-derived damage (UnitCombat.roll_damage) plus damage_bonus — sw+2,
## thr-1 in GURPS notation. FIXED ignores ST and rolls its own dice (a
## wand, a crossbow).
enum DamageBase { SWING, THRUST, FIXED }

## Shown on the hotbar: "Swing", "Thrust", "Claws".
@export var label: String = "Attack"
@export var kind: Kind = Kind.MELEE
@export var damage_base: DamageBase = DamageBase.THRUST
## Added to the SWING/THRUST roll. Unused for FIXED.
@export var damage_bonus: int = 0
## GURPS damage type (B379) — a broadsword's swing cuts, its thrust
## impales.
@export var wound_type: DamageResolver.WoundType = DamageResolver.WoundType.CRUSHING
## GURPS armor divisor (B378): the target's DR is divided by it. 1 is
## none; (2), (3), (5), (10) penetrate; (0.5), (0.2), (0.1) are stopped
## more easily than usual.
@export var armor_divisor: float = 1.0
## Melee only: how far this row reaches, edge to edge, in the same
## units as MeleeEnemyTargeting.melee_range (1.0 is the plain attack's
## reach).
@export var reach: float = 1.0

@export_group("Fixed Damage")
## Only read when damage_base == FIXED.
@export var fixed_dice_count: int = 1
@export var fixed_dice_sides: int = 6
@export var fixed_dice_bonus: int = 0


func roll(attacker: Unit, is_critical: bool) -> int:
	match damage_base:
		DamageBase.FIXED:
			if is_critical:
				return fixed_dice_count * fixed_dice_sides + fixed_dice_bonus
			var total: int = 0
			for _i in fixed_dice_count:
				total += randi_range(1, fixed_dice_sides)
			return total + fixed_dice_bonus
		_:
			var st_type := _st_type()
			return attacker.max_damage(st_type, damage_bonus) if is_critical \
				else attacker.roll_damage(st_type, damage_bonus)


## Mirrors roll() without rolling — see AbilityEffect.expected_damage.
func expected_damage(attacker: Unit, target: Unit = null, location: HitLocation = null) -> float:
	if damage_base == DamageBase.FIXED:
		return DamageResolver.expected_injury(fixed_dice_count, fixed_dice_sides, fixed_dice_bonus, target, wound_type, armor_divisor, false, location)
	return attacker.expected_damage(_st_type(), damage_bonus, target, wound_type, armor_divisor, location)


## "sw+2 cutting" / "1d6+0 crushing", for tooltips.
func describe_damage(attacker: Unit = null) -> String:
	var dice: String
	if damage_base == DamageBase.FIXED:
		dice = "%dd%d" % [fixed_dice_count, fixed_dice_sides]
		if fixed_dice_bonus != 0:
			dice += "%+d" % fixed_dice_bonus
	elif attacker:
		dice = attacker.describe_damage(_st_type(), damage_bonus)
	else:
		dice = ("sw" if damage_base == DamageBase.SWING else "thr") + ("%+d" % damage_bonus if damage_bonus != 0 else "")
	return "%s %s" % [dice, DamageResolver.describe(wound_type, armor_divisor)]


## DamageBase's SWING/THRUST share UnitCombat.DamageType's values. Naming
## that enum here would make loading any row .tres compile unit_combat.gd,
## whose const .tres preloads then cycle back through status_behavior.gd.
func _st_type() -> int:
	return damage_base
