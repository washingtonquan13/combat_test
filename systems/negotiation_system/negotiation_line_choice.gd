class_name NegotiationLineChoice
extends NegotiationChoice
## A response that just moves the conversation to another node — the
## negotiation-side sibling of LineChoice, minus returns_to_root: a
## negotiation tree is linear/branching, not hub-and-spoke, so there's
## no "return to hub" concept to support.

@export var next_node_id: String = ""


func _resolve_next_node_id(_actor: Unit, _target: Unit) -> String:
	return next_node_id
