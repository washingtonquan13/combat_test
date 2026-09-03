class_name SkillCheckChoice
extends DialogueChoice
## A response gated behind a skill roll — resolves via the real skill
## system (SkillCalculator + Unit.roll_vs) instead of the old GURPS-
## project version's hardcoded trait dictionary, which was never wired
## to an actual character at all.
##
## See QuickContestChoice for the opposed-NPC-roll sibling this file's
## own header used to say didn't exist yet — this scene needed one.
## DialogueManager.find_assisting_companion()'s bonus (a present ally
## who can also use this skill) applies here too; both classes share
## the exact same assist logic.

@export var skill_name: String = ""
@export var success_node_id: String = ""
@export var failure_node_id: String = ""
## False hides the skill tag/DC preview on the response button (shows
## "???" instead, see DialogueFormat.choice_label) until picked —
## matches BG3's own treatment of a check the character wouldn't
## consciously know they're attempting.
@export var show_to_player: bool = true


func _resolve_next_node_id(actor: Unit, _target: Unit) -> String:
	var result: SkillCheckResult = SkillCalculator.get_skill_level(actor, skill_name)
	if not result.can_use_skill:
		DialogueManager.record_line("(%s has no way to attempt this.)" % skill_name)
		return failure_node_id

	var assistant: Unit = DialogueManager.find_assisting_companion(skill_name)
	var target: int = result.skill_level + (DialogueManager.ASSIST_BONUS if assistant else 0)
	# The roll is fully decided right here, before the dice ever show
	# anything — dice_roll_requested only ever plays back a result
	# that's already final, never determines one.
	var roll: Dictionary = actor.roll_vs(target)
	await DialogueManager.present_dice_roll(skill_name, roll)

	DialogueManager.record_line(DialogueFormat.skill_result(skill_name, roll, assistant))
	return success_node_id if roll.success else failure_node_id
