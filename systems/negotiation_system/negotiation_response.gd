class_name NegotiationResponse
extends Resource
## One entry in the shared, fixed response menu every negotiation offers
## (data/negotiation/responses/*.tres) — content, not per-demon
## architecture. DemonPersonality.tone_favor(tone) is what makes
## different demons react to the SAME response differently, not a
## different response list per demon (see that class's own header).

@export var text: String = ""
@export var tone: StringName = &""
## Whether this response can be picked more than once in the same
## negotiation — mirrors DialogueChoice.is_repeatable exactly (see
## NegotiationManager._used_responses/_visible_responses(), the same
## used-tracking shape as DialogueManager.used_choices).
@export var is_repeatable: bool = true
