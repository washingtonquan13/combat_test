class_name ContactEvent
extends Resource
## One touch in a paired clip: a blade on a blade, a point in a body.
##
## The single source for everything that happens at an impact. The stage's
## impact dispatcher (CinematicStage.impact) reads it and fires the camera's
## trauma shake, the struck body's reaction, the spark or blood
## and the sound, all from this one record, so they cannot drift apart.
##
## Roles are the pair's own: LEAD and PARTNER of the PairedClip, which a
## PairedActionBeat maps onto the stage's role names.

## LAND is a body meeting the ground (a jump coming down): it shakes by
## strength like a blow, with no reaction. Appended last so
## saved resources keep their kinds.
enum Kind { PARRY, HIT, KILL, GRAB, MISS, LAND }
enum Who { LEAD, PARTNER }
## A hint for the editor (and the stage's cut check): NONE, a cut ON the
## contact frame, or a cut AFTER it, onto the reaction.
enum Cut { NONE, ON, AFTER }

## The point an effector or target names when it is not a bone: the held
## weapon's blade (its closest point to the other side), or its tip.
const BLADE: StringName = &"blade"
const BLADE_TIP: StringName = &"blade_tip"

## Shake decay, in seconds, at strength 0 and 1 (spec 5.1: 0.3 to 0.6 s).
const SHAKE_MIN := 0.3
const SHAKE_MAX := 0.6

## Seconds from the paired clip's start.
@export var time: float = 0.0
@export var kind: Kind = Kind.HIT
## Who strikes, and with what: a bone name, BLADE or BLADE_TIP.
@export var striker: Who = Who.LEAD
@export var effector: StringName = BLADE_TIP
## Who is met, and where: a bone name, BLADE or BLADE_TIP.
@export var target_side: Who = Who.PARTNER
@export var target: StringName = &"Chest"
## 0..1. Scales the shake and the reaction.
@export_range(0.0, 1.0) var strength: float = 0.5
@export var cut: Cut = Cut.NONE


static func make(at: float, what: Kind, how_hard: float, cut_hint: Cut = Cut.NONE) -> ContactEvent:
	var event := ContactEvent.new()
	event.time = at
	event.kind = what
	event.strength = how_hard
	event.cut = cut_hint
	if what == Kind.PARRY:
		event.effector = BLADE
		event.target = BLADE
	return event


## Whether the contact meets something hard enough to shake the camera.
## A miss and a grab do not. There is no hit-stop: cinematics never stop
## time on a contact; the cut and the motion carry the weight.
func shakes() -> bool:
	return kind != Kind.MISS and kind != Kind.GRAB


## The camera's trauma at the contact, 0..1.
func trauma() -> float:
	return lerpf(0.35, 1.0, strength) if shakes() else 0.0


## How long the trauma takes to decay to nothing.
func shake_seconds() -> float:
	return lerpf(SHAKE_MIN, SHAKE_MAX, strength) if shakes() else 0.0


func draws_blood() -> bool:
	return kind == Kind.HIT or kind == Kind.KILL


func describe() -> String:
	return "%s %.3f s (strength %.2f)" % [Kind.keys()[kind].to_lower(), time, strength]
