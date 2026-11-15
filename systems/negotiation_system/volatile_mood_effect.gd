class_name VolatileMoodEffect
extends DialogueEffect
## ShiftMoodEffect's counterpart for the Moody personality — a random
## amount within an authored range instead of one fixed number, so the
## SAME answer can swing the mood either way from one negotiation to the
## next. Reuses ShiftMoodEffect.shift() for the actual state change and
## narration; the amount is rolled on the conversation's own dice.

## What this is called in a dialogue file (see DialogueScript).
const SCRIPT_WORDS: PackedStringArray = ["mood_swing"]

@export var min_amount: int = -2
@export var max_amount: int = 2


func apply(c: Conversation) -> void:
	ShiftMoodEffect.shift(c, c.rng.randi_range(min_amount, max_amount))


## "mood_swing -2 +2": the least and the most it can move.
func read_script(_word: String, args: PackedStringArray, _where: String) -> String:
	if args.size() != 2 or not args[0].is_valid_int() or not args[1].is_valid_int():
		return "'mood_swing' is followed by two whole numbers, like 'mood_swing -2 +2'."
	min_amount = args[0].to_int()
	max_amount = args[1].to_int()
	return ""
