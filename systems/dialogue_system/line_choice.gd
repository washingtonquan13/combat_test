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
##
## Also every negotiation response: an answer the demon dislikes carries a
## SpendPardonEffect, one it hates or one that closes the deal carries a
## NegotiationOutcomeEffect, and otherwise it moves on like any line.

@export var next_node_id: String = ""
## When true, ignores next_node_id and routes back through the addressed
## unit's own dialogue_options instead — see Unit.resolve_dialogue_root().
## For a "return to the hub" choice that needs to land on whichever
## phase of the conversation is CURRENTLY correct, not a next_node_id
## hardcoded to one specific hub — a hub that resolves a quest mid-
## conversation should route back to the post-quest hub, not the one
## it started in.
@export var returns_to_root: bool = false


func _resolve_next_node_id(c: Conversation) -> String:
	if returns_to_root:
		var npc: Unit = c.cast.get("npc") as Unit
		var root: DialogueNode = npc.resolve_dialogue_root(c) if is_instance_valid(npc) else null
		return root.id if root else ""
	return next_node_id
