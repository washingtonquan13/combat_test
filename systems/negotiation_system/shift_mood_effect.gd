class_name ShiftMoodEffect
extends DialogueEffect
## Raises or lowers the current negotiation's hidden mood — see
## NegotiationManager.current_mood/shift_mood(). Negotiation-specific by
## nature (reads/writes NegotiationManager directly, meaningless outside
## an active negotiation), which is why this lives alongside
## NegotiationChoice rather than with the generic Sacrifice*Effect
## family in systems/dialogue_system/.

@export var amount: int = 0


func apply(_actor: Unit, _target: Unit) -> void:
	NegotiationManager.shift_mood(amount)
