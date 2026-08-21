class_name ExamineInteraction
extends InteractionOption
## Right-click "Examine" — always available, no combat/faction gating.
## Deliberately trivial (a single SystemLog line, the same autoload
## unit/ability code already reports events through) — this exists to
## prove a verb list can mix a real action with a placeholder one, not to
## be a real inspection UI yet.

func is_available(_actor: Unit, _target) -> bool:
	return true


func execute(_actor: Unit, target) -> void:
	var label_text: String
	if target is Unit:
		label_text = target.get_display_name()
	elif target is Node:
		label_text = target.name
	else:
		label_text = str(target)
	SystemLog.print("Examined %s." % label_text)
