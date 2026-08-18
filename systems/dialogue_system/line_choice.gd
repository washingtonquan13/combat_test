class_name LineChoice
extends DialogueChoice
## The plain case — no roll, just moves the conversation to another node.
## Renamed from the old GURPS-project's "DialogueChoice", which collided
## with what should be the ABSTRACT base's own name (see
## dialogue_choice.gd) — that project called the base BaseChoice instead,
## leaving the ordinary concrete case with the generic-sounding name.
## This project's own convention (InteractionOption, not
## InteractionOptionBase) puts the plain name on the base and a
## descriptive one on every concrete case instead.

@export var next_node_id: String = ""
## When true, ignores next_node_id and routes back through target's own
## dialogue_options instead — see DialogueManager.resolve_root_id().
## For a "return to the hub" choice that needs to land on whichever
## phase of the conversation is CURRENTLY correct, not a next_node_id
## hardcoded to one specific hub — a hub that resolves a quest mid-
## conversation should route back to the post-quest hub, not the one
## it started in.
@export var returns_to_root: bool = false


func _resolve_next_node_id(actor: Unit, target: Unit) -> String:
	if returns_to_root:
		return DialogueManager.resolve_root_id(target, actor)
	return next_node_id
