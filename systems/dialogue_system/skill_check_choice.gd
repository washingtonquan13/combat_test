class_name SkillCheckChoice
extends DialogueChoice
## A response gated behind a skill roll — resolves via the real skill
## system (SkillCalculator + Unit.roll_vs) instead of the old GURPS-
## project version's hardcoded trait dictionary, which was never wired
## to an actual character at all.
##
## See QuickContestChoice for the opposed-NPC-roll sibling.
## Conversation.find_assisting_companion()'s bonus (a present ally who
## can also use this skill) applies here too; both classes take their
## target from the same Conversation.check_target(), which is also what
## the row's preview shows.

@export var skill_name: String = ""
@export var success_node_id: String = ""
@export var failure_node_id: String = ""
## False hides the skill preview on the response row (see
## Conversation.describe_choice, which then carries no number) until
## picked — matches BG3's own treatment of a check the character wouldn't
## consciously know they're attempting.
@export var show_to_player: bool = true


func _resolve_next_node_id(c: Conversation) -> String:
	var actor: Unit = c.cast.get("player") as Unit
	var check: Dictionary = c.check_target(skill_name)
	var result: SkillCheckResult = check.result
	if result == null or not result.can_use_skill:
		c.record("", "(%s has no way to attempt this.)" % skill_name)
		return failure_node_id

	var assistant: Unit = check.assistant
	# The roll is fully decided right here, on the conversation's own dice,
	# before anything is shown — the dice presenter only ever plays back a
	# result that's already final, never determines one.
	var roll: Dictionary = actor.roll_vs(check.target, c.rng)
	await c.show(&"dice", {"skill": skill_name, "roll": roll})
	if c.ended:
		return ""

	c.record("", DialogueFormat.skill_result(skill_name, roll, assistant),
			{"tag": &"check", "success": roll.success, "verdict": DialogueFormat.skill_verdict(roll),
			"skills": [skill_name]})
	return success_node_id if roll.success else failure_node_id
