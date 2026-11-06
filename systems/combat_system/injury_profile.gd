@tool
class_name InjuryProfile
extends RefCounted
## One unit's body plan with its preset applied, which is what
## DamageResolver reads. Derived and never saved: Unit.injury_profile()
## rebuilds it when the plan, preset or missing locations change.

var plan: BodyPlan
var preset: InjuryPreset
var torso: BodyRow
## Damage Reduction (Powers 52): divides injury after the multiplier and
## the cap. 1 is none.
var divisor: float = 1.0
var _rows: Dictionary[HitLocation, BodyRow] = {}
## "row index:field:wound type" -> what changed that cell, for the editor
## preview. Filled only when build() is asked to.
var sources: Dictionary[String, String] = {}


## body_plan, then injury_preset's rules in order, then every location in
## missing (and the preset's own) set to the torso's final numbers.
static func build(body_plan: BodyPlan, injury_preset: InjuryPreset = null, missing: Array[HitLocation] = [], injury_divisor: float = 1.0, record_sources: bool = false) -> InjuryProfile:
	var profile := InjuryProfile.new()
	profile.plan = body_plan
	profile.preset = injury_preset
	profile.divisor = maxf(injury_divisor, 1.0)
	var rows: Array[BodyRow] = []
	for source in body_plan.rows():
		rows.append(source.duplicate())
	profile.torso = rows[0]
	var lacks: Array[HitLocation] = missing.duplicate()
	if injury_preset:
		lacks.append_array(injury_preset.missing_locations)
		for rule in injury_preset.rules:
			if rule == null:
				continue
			for index in rows.size():
				if not rule.applies_to(rows[index]):
					continue
				for wound_type in rule.types():
					rule.apply(rows[index], wound_type)
					if record_sources:
						profile.sources["%d:%d:%d" % [index, rule.field, wound_type]] = injury_preset.display_name
	for index in rows.size():
		var row: BodyRow = rows[index]
		if index > 0 and lacks.has(row.location):
			row.copy_values(profile.torso)
			if record_sources:
				for field in InjuryRule.Field.size():
					for wound_type in DamageResolver.WoundType.size():
						profile.sources["%d:%d:%d" % [index, field, wound_type]] = "No " + (row.location.display_name if row.location else "?")
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
