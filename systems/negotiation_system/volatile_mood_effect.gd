class_name VolatileMoodEffect
extends DialogueEffect
## ShiftMoodEffect's counterpart for the Moody personality — a random
## amount within an authored range instead of one fixed number, so the
## SAME answer can swing the mood either way from one negotiation to the
## next. Reuses NegotiationManager.shift_mood() for the actual state
## change and narration, same as ShiftMoodEffect — the only difference
## is where the amount comes from.

@export var min_amount: int = -2
@export var max_amount: int = 2


func apply(_actor: Unit, _target: Unit) -> void:
	NegotiationManager.shift_mood(randi_range(min_amount, max_amount))
