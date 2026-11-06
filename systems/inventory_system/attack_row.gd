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
## wand, a crossbow, a gun).
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
## GURPS minimum ST (B270): -1 to hit per point the wielder's ST falls
## short (UnitCombat.to_hit_target). 0 for none. Per row, as in the
## tables — a spear can need more ST one-handed than two.
@export var min_st: int = 0
## Takes no off-hand penalty from the off hand: a shield bash, which
## GURPS rolls on Shield skill, where the -4 doesn't apply. Its hotbar
## attack then has no "(off hand)" suffix either.
@export var off_hand_ok: bool = false
## Added to hit with this row: a rune's or an affix's, never authored on
## a base weapon (UnitCombat._hands_modifier).
@export var to_hit_bonus: int = 0

@export_group("Ranged")
## GURPS Accuracy (B269): added to hit when the shooter has aimed —
## here, stood still all turn (UnitCombat._aim_bonus). 0 for none.
@export var acc: int = 0
## GURPS ½D: past this edge-to-edge distance the damage roll is halved
## (B378). 0 for no falloff. Ranges are in move units, compressed from
## the GURPS yards so a bow fits a battle map.
@export var half_damage_range: float = 0.0
## GURPS Max: the farthest this row can be fired. 0 keeps the generic
## ranged attack's own range.
@export var max_range: float = 0.0
## A muscle-powered weapon's own ST (a bow's draw weight, B270): SWING/
## THRUST dice come from this instead of the wielder's ST. 0 is the
## wielder's own — a thrown axe, a sling.
@export var weapon_st: int = 0
## GURPS RoF (B373): shots per attack. Each shot past the first hits for
## every full `recoil` the to-hit roll succeeded by.
@export var rof: int = 1
## GURPS Rcl. Only read when rof > 1.
@export var recoil: int = 1

@export_group("Fixed Damage")
## Only read when damage_base == FIXED.
@export var fixed_dice_count: int = 1
@export var fixed_dice_sides: int = 6
@export var fixed_dice_bonus: int = 0

@export_group("Presentation")
## The attacker's clip for this row: a swing, a thrust, a bow draw. Its
## Call Method keys mark the release and the impact (see
## CharacterModel.moment). Empty keeps the attack template's own.
@export var animation: AnimationSequence
## What flies or flashes once the attack releases: an arrow, a tracer
## and muzzle flash, a spinning axe. Ends with an ImpactSignalStep for a
## ranged row, whose hit lands on it. Empty keeps the template's own.
@export var cast_vfx: VfxEffect


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
			return attacker.max_damage(st_type, damage_bonus, weapon_st) if is_critical \
				else attacker.roll_damage(st_type, damage_bonus, weapon_st)


## Mirrors roll() without rolling — see AbilityEffect.expected_damage.
func expected_damage(attacker: Unit, target: Unit = null, location: HitLocation = null) -> float:
	if damage_base == DamageBase.FIXED:
		return DamageResolver.expected_injury(fixed_dice_count, fixed_dice_sides, fixed_dice_bonus, target, wound_type, armor_divisor, false, location)
	return attacker.expected_damage(_st_type(), damage_bonus, target, wound_type, armor_divisor, location, weapon_st)


## "sw+2 cutting" / "1d6+0 crushing", for tooltips.
func describe_damage(attacker: Unit = null) -> String:
	var dice: String
	if damage_base == DamageBase.FIXED:
		dice = "%dd%d" % [fixed_dice_count, fixed_dice_sides]
		if fixed_dice_bonus != 0:
			dice += "%+d" % fixed_dice_bonus
	elif attacker:
		dice = attacker.describe_damage(_st_type(), damage_bonus, weapon_st)
	else:
		dice = ("sw" if damage_base == DamageBase.SWING else "thr") + ("%+d" % damage_bonus if damage_bonus != 0 else "")
	return "%s %s" % [dice, DamageResolver.describe(wound_type, armor_divisor)]


## Ranged and past ½D from target: GURPS halves the damage roll.
func is_past_half_damage(attacker: Unit, target) -> bool:
	return kind == Kind.RANGED and half_damage_range > 0.0 and target is Unit \
		and attacker.edge_distance_to(target) > half_damage_range


## DamageBase's SWING/THRUST share UnitCombat.DamageType's values. Naming
## that enum here would make loading any row .tres compile unit_combat.gd,
## whose const .tres preloads then cycle back through status_behavior.gd.
func _st_type() -> int:
	return damage_base
