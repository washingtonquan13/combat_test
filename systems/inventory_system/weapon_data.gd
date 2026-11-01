class_name WeaponData
extends Resource
## Composed onto GearItem only when it's actually a weapon — kept
## separate rather than a pile of weapon-only fields sitting unused on
## every armor/accessory GearItem too, same reasoning StatusBehavior
## already splits "what a status DOES" into small focused pieces
## instead of one class with a field per possible status.
##
## SWING/THRUST read the wielder's own ST-derived damage (see
## UnitCombat.roll_damage, which GearDamageEffect calls with
## damage_bonus as the weapon's contribution) — sw+2/thr+2 in GURPS
## notation. FIXED ignores the wielder's ST entirely and rolls its own
## dice (a wand, say) via the plain count/sides/bonus fields below,
## since this is composed onto a Resource (GearItem), not a scene node.

enum DamageType { SWING, THRUST, FIXED }

@export var damage_type: DamageType = DamageType.SWING
## Added on top of the ST-derived roll for SWING/THRUST — the "+2" in
## sw+2. Unused for FIXED.
@export var damage_bonus: int = 0
## GURPS damage type (B379) — a broadsword's swing is cutting, a spear's
## thrust impaling. Separate from damage_type, which is only which dice
## table the roll reads.
@export var wound_type: DamageResolver.WoundType = DamageResolver.WoundType.CRUSHING
## GURPS armor divisor (B378): the target's DR is divided by it. 1 is
## none; (2), (3), (5), (10) penetrate; (0.5), (0.2), (0.1) are stopped
## more easily than usual.
@export var armor_divisor: float = 1.0

@export_group("Fixed Damage")
## Only read when damage_type == FIXED.
@export var fixed_dice_count: int = 1
@export var fixed_dice_sides: int = 6
@export var fixed_dice_bonus: int = 0
