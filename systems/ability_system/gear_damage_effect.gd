class_name GearDamageEffect
extends AbilityEffect
## Rolls damage from one AttackRow — a line of the held weapon's table,
## or of the body's natural attacks — instead of a fixed bonus baked
## into the ability itself (see StDamageEffect).
##
## Authored with no row, this is the generic "melee" or "ranged" attack
## (basic_attack_melee/ranged.tres): Unit.combat_abilities() turns it
## into one copy per row the unit can actually use, each bound to its
## row, and those copies are what the hotbar and the AI pick from. Used
## directly, unbound, it attacks with the unit's first row of its
## category.
##
## Nothing to attack with: a GURPS punch, thr-1 crushing (B271). That
## includes ranged with no ranged rows, which still punches at range,
## exactly as before rows existed.

enum WeaponCategory { MELEE, RANGED }

@export var category: WeaponCategory = WeaponCategory.MELEE
## Which row this attack is. Null on the generic template — see above.
@export var row: AttackRow
## Bound to the off-hand weapon's row: UnitCombat.to_hit_target takes
## OFF_HAND_PENALTY.
@export var off_hand: bool = false

const PUNCH: AttackRow = preload("res://data/attacks/punch.tres")


func apply(attacker: Unit, target, ability: Ability, is_critical: bool) -> Dictionary:
	if not target is Unit:
		return {}

	var attack: AttackRow = row_for(attacker)
	# Critical hit: ignores DR entirely and deals guaranteed max damage
	# (see UnitCombat.max_damage) — no second roll, staying consistent
	# with this project's fast/not-roll-heavy combat goal.
	var raw_damage: int = attack.roll(attacker, is_critical)
	var applied: int = DamageResolver.injury(raw_damage, target, attack.wound_type, attack.armor_divisor, is_critical, false, attacker.hit_location_for(ability))
	target.take_damage(applied, is_critical)

	return {"raw_damage": raw_damage, "damage": applied}


func kind() -> AttackRow.Kind:
	return AttackRow.Kind.MELEE if category == WeaponCategory.MELEE else AttackRow.Kind.RANGED


## The bound row, else the attacker's first of this category, else a
## punch.
func row_for(attacker: Unit) -> AttackRow:
	if row:
		return row
	var rows: Array[AttackRow] = attacker.attack_rows(kind())
	return rows[0] if not rows.is_empty() else PUNCH


func located_wound_type(attacker: Unit) -> int:
	return row_for(attacker).wound_type


func describe() -> String:
	if row:
		return "%s: %s damage" % [row.label, row.describe_damage()]
	var label := "Melee" if category == WeaponCategory.MELEE else "Ranged"
	return "%s weapon damage" % label


## Mirrors apply() without rolling — see AbilityEffect.expected_damage.
func expected_damage(attacker: Unit, target: Unit = null, location: HitLocation = null) -> float:
	return row_for(attacker).expected_damage(attacker, target, location)
