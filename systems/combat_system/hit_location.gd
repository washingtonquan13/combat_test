class_name HitLocation
extends Resource
## A part of the body an attack can be aimed at instead of the torso
## (GURPS B398-399): its name and to-hit penalty. What a hit there does
## is the target's BodyPlan row for it, so it can differ per creature.
## torso.tres names the torso row; it is never aimed at.

@export var display_name: String = ""
@export var to_hit_penalty: int = 0


## Whether aiming wound_type here can pay: the human plan's row for this
## location takes it differently from the torso. Anything else goes to
## the torso as usual, without the penalty (UnitCombat.hit_location_for).
func allows(wound_type: DamageResolver.WoundType) -> bool:
	var plan: BodyPlan = BodyPlan.human()
	return plan.row(self).differs_from(plan.torso, wound_type)


## "-3 to hit\nx3: imp, pi-, pi, pi+, pi++; anything else hits the torso"
## for a tooltip, from the human plan.
func describe() -> String:
	var plan: BodyPlan = BodyPlan.human()
	var row: BodyRow = plan.row(self)
	# Wound types grouped by what they do here, in enum order.
	var groups: Dictionary[String, PackedStringArray] = {}
	for wound_type in DamageResolver.WoundType.size():
		if not row.differs_from(plan.torso, wound_type):
			continue
		var effect: String = "x%s" % String.num(row.multipliers[wound_type], 2)
		if row.dr[wound_type] > 0:
			effect += ", +%d DR" % row.dr[wound_type]
		if not groups.has(effect):
			groups[effect] = PackedStringArray()
		groups[effect].append(DamageResolver.ABBREVIATION[wound_type])
	var lines: PackedStringArray = ["%+d to hit" % to_hit_penalty]
	for effect in groups:
		lines.append("%s: %s" % [effect, ", ".join(groups[effect])])
	lines.append("Anything else hits the torso")
	return "\n".join(lines)
