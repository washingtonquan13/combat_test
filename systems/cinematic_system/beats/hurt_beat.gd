@tool
class_name HurtBeat
extends BeatNode
## Leaves an actor wounded or dead, as the scene says they end up: the
## lookout an arrow took, the defender the paired kill was not for. The
## fight after the scene starts from it.
##
## STATE, NOT A PICTURE. It sets the unit's HP, or kills it, and shows
## nothing. The arrow, the stagger and the fall are ClipBeats and
## EffectBeats on the same key.
##
## WHERE THE DEAD LIE. A unit that dies plays its own death clip. One the
## scene has already shown falling names that clip in `lies_in`: it dies on
## the clip's last frame instead, as it fell, not falling a second time.
##
## WOUNDED is a set HP, not damage: damage rolls to stay up at every
## threshold it crosses, and a scene's outcome is written, not rolled.
##
## Skipped, the same: the dead are dead and the wounded wounded whether
## the player watched or not.

enum Outcome { WOUNDED, DEAD }

@export var role: StringName = &"":
	set(value):
		role = value
		_changed()
@export var outcome: Outcome = Outcome.WOUNDED
## The part of their maximum HP a wounded actor is left with.
@export_range(0.05, 1.0, 0.05) var hp_left: float = 0.4
## DEAD only: the clip the body was shown falling in ("Scene/Fall_Wall"), to
## lie as it left them. Empty = the unit's own death clip.
@export var lies_in: String = ""


func _validate_property(property: Dictionary) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage and property.name == "role":
		_suggest_names(property, owner_stage.role_names())


func _fire(owner_stage: CinematicStage) -> void:
	_apply(owner_stage)


func _skip(owner_stage: CinematicStage) -> void:
	_apply(owner_stage)


func _apply(owner_stage: CinematicStage) -> void:
	var unit: Unit = owner_stage.actor(role)
	if unit == null or not unit.is_alive():
		return
	if outcome == Outcome.DEAD:
		kill(unit, lies_in)
		return
	unit.set_pool(StatIds.HP, maxi(1, roundi(unit.get_stat(StatIds.HP) * hp_left)))


## Kills `unit` lying as `clip` leaves them, on its last frame, when the
## body has that clip; otherwise in its own death clip.
static func kill(unit: Unit, clip: String) -> void:
	var animator: UnitAnimator = unit.animator()
	var lies: bool = clip != "" and animator != null and animator.animation_player != null \
			and animator.animation_player.has_animation(clip)
	if lies:
		animator.death_animation = clip
	unit.die()
	if lies and animator.playback:
		animator.playback.seek(animator.animation_player.get_animation(clip).length, true)


func _beat_warnings(owner_stage: CinematicStage) -> PackedStringArray:
	var warnings := PackedStringArray()
	_check_role(warnings, owner_stage, "role", role)
	return warnings
