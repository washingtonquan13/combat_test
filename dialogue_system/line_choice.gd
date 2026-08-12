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


func _resolve_next_node_id(_actor: Unit, _target: Unit) -> String:
	return next_node_id
