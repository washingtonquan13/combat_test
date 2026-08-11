class_name TalkInteraction
extends InteractionOption
## Right-click "Talk" — available on any non-hostile unit (mirrors
## AttackInteraction's own hostile-only gate, just the opposite side of
## it), same discipline PrerequisiteRule's data-only subclasses already
## established for this project: a verb that's real and author-able now,
## even though the system it should eventually lead into (an actual
## dialogue UI) doesn't exist yet. Unlike those subclasses, this can't
## just inherit the base's push_error stub — it needs to actually show up
## in a player-facing menu and do SOMETHING when clicked, not silently
## refuse to evaluate. execute() is a placeholder in exactly the same
## spirit as ExamineInteraction until a real dialogue system exists to
## call into instead.

func is_available(actor: Unit, target) -> bool:
	if not target is Unit:
		return false
	var unit_target: Unit = target
	return not actor.is_hostile_to(unit_target)


func execute(_actor: Unit, target) -> void:
	var label_text: String = target.name if target is Node else str(target)
	SystemLog.print("%s has nothing to say yet." % label_text)
