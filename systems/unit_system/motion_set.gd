class_name MotionSet
extends Resource
## What one body does for each motion key.
##
## Callers never name a clip. An ability, attack row, weapon or status names
## a motion key, such as &"attack.swing" or &"cast.charged", and the body's
## MotionSet turns that key into its own animation. A humanoid answers
## &"attack.claw" with an arm swipe; a dragon answers it with its own claw
## clip; a fairy with no entry answers nothing, and the action still runs.
##
## Keys are dotted, from general to specific. A lookup that misses drops the
## last part and tries again: "attack.shoot.bow" -> "attack.shoot" ->
## "attack" -> nothing. So a body can cover a whole family with one entry,
## and override only the members it animates differently.
##
## "Nothing" is a supported answer, not an error. A sequence that resolves to
## null means the action releases at once with no motion; an empty clip means
## the pose is skipped.

## Motion key -> the phased sequence that plays it (casts, attacks, jumps,
## reloads). These carry the release/impact moments.
@export var sequences: Dictionary[StringName, AnimationSequence] = {}

## Motion key -> one clip on this body's AnimationPlayer (stances, the
## knockdown and get-up poses, the armed enter/hold/exit loop, gestures).
@export var clips: Dictionary[StringName, String] = {}


## The sequence this body plays for `motion`, or null when it has none,
## after falling back through the key's categories.
func sequence_for(motion: StringName) -> AnimationSequence:
	var key: String = motion
	while key != "":
		var found: AnimationSequence = sequences.get(StringName(key))
		if found:
			return found
		key = _parent(key)
	return null


## The clip this body plays for `motion`, or "" when it has none, after
## falling back through the key's categories.
func clip_for(motion: StringName) -> String:
	var key: String = motion
	while key != "":
		var found: String = clips.get(StringName(key), "")
		if found != "":
			return found
		key = _parent(key)
	return ""


static func _parent(key: String) -> String:
	var dot: int = key.rfind(".")
	return key.substr(0, dot) if dot >= 0 else ""
