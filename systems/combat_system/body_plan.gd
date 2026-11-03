@tool
class_name BodyPlan
extends Resource
## A creature's anatomy for injury: a torso row that every unaimed hit
## takes, plus a row per location an attack can be aimed at. Most
## creatures share human.tres and differ only by InjuryTraits; a
## different body shape (no head) is a different plan.

const HUMAN_PATH := "res://data/body_plans/human.tres"

@export var torso: BodyRow
@export var locations: Array[BodyRow] = []

static var _human: BodyPlan


## The plan a unit has when nothing says otherwise.
static func human() -> BodyPlan:
	if _human == null:
		_human = load(HUMAN_PATH)
	return _human


## location's row; the torso for null or for a location this body
## doesn't have.
func row(location: HitLocation) -> BodyRow:
	if location:
		for candidate in locations:
			if candidate.location == location:
				return candidate
	return torso


## Every row, torso first.
func rows() -> Array[BodyRow]:
	var out: Array[BodyRow] = [torso]
	out.append_array(locations)
	return out
