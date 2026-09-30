class_name VolatileMoodEffect
extends DialogueEffect
## ShiftMoodEffect's counterpart for the Moody personality — a random
## amount within an authored range instead of one fixed number, so the
## SAME answer can swing the mood either way from one negotiation to the
## next. Reuses ShiftMoodEffect.shift() for the actual state change and
## narration; the amount is rolled on the conversation's own dice.

@export var min_amount: int = -2
@export var max_amount: int = 2


func apply(c: Conversation) -> void:
	ShiftMoodEffect.shift(c, c.rng.randi_range(min_amount, max_amount))
