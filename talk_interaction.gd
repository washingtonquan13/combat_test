class_name TalkInteraction
extends InteractionOption
## Right-click "Talk" — available on any non-hostile unit (mirrors
## AttackInteraction's own hostile-only gate, just the opposite side of
## it). Starts a real conversation via DialogueManager when the target
## has one authored (Unit.dialogue_root); falls back to a placeholder
## SystemLog line otherwise, same honest-stub treatment ExamineInteraction
## already got, for any unit nobody's written dialogue for yet.

func is_available(actor: Unit, target) -> bool:
	if not target is Unit:
		return false
	var unit_target: Unit = target
	return not actor.is_hostile_to(unit_target)


func execute(actor: Unit, target) -> void:
	var unit_target: Unit = target
	if unit_target.dialogue_root:
		DialogueManager.start_dialogue(unit_target.dialogue_root, {"player": actor, "npc": unit_target})
	else:
		SystemLog.print("%s has nothing to say yet." % unit_target.name)
