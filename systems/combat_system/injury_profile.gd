@tool
class_name InjuryProfile
extends RefCounted
## One unit's body plan with its traits merged in, which is what
## DamageResolver reads. Derived and never saved: Unit.injury_profile()
## rebuilds it when the unit's traits change.

var plan: BodyPlan
var traits: Array[InjuryTrait] = []
var torso: BodyRow
var _rows: Dictionary[HitLocation, BodyRow] = {}
## "row index:field:wound type" -> names of the traits that changed that
## cell, for the editor preview. Filled only when build() is asked to.
var sources: Dictionary[String, PackedStringArray] = {}


## body_plan with injury_traits applied, rule by rule in
## InjuryRule.ORDER.
static func build(body_plan: BodyPlan, injury_traits: Array[InjuryTrait], record_sources: bool = false) -> InjuryProfile:
	var profile := InjuryProfile.new()
	profile.plan = body_plan
	profile.traits = injury_traits
	var rows: Array[BodyRow] = []
	for source in body_plan.rows():
		rows.append(source.duplicate())
	profile.torso = rows[0]
	for op in InjuryRule.ORDER:
		for injury_trait in injury_traits:
			if injury_trait == null:
				continue
			for rule in injury_trait.rules:
				if rule == null or rule.op != op:
					continue
				for index in rows.size():
					var row: BodyRow = rows[index]
					if not rule.applies_to(row):
						continue
					if op == InjuryRule.Op.COPY_TORSO:
						row.copy_torso = true
						continue
					for wound_type in rule.types():
						rule.apply(row, wound_type)
						if record_sources:
							profile._record(index, rule.field, wound_type, injury_trait.display_name)
	for index in rows.size():
		var row: BodyRow = rows[index]
		if index > 0 and row.copy_torso:
			row.copy_values(profile.torso)
			if record_sources:
				for field in InjuryRule.Field.size():
					for wound_type in DamageResolver.WoundType.size():
						profile._record(index, field, wound_type, "copies the torso")
		if row.location:
			profile._rows[row.location] = row
	return profile


## location's row; the torso for null or for a location this body lacks.
func row(location: HitLocation) -> BodyRow:
	if location == null:
		return torso
	return _rows.get(location, torso)


## Every row, torso first, in the plan's order.
func rows() -> Array[BodyRow]:
	var out: Array[BodyRow] = [torso]
	for source in plan.locations:
		out.append(_rows.get(source.location, torso))
	return out


func _record(index: int, field: int, wound_type: int, trait_name: String) -> void:
	var key: String = "%d:%d:%d" % [index, field, wound_type]
	var names: PackedStringArray = sources.get(key, PackedStringArray())
	if not names.has(trait_name):
		names.append(trait_name)
	sources[key] = names
