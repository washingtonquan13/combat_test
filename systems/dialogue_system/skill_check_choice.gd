class_name SkillCheckChoice
extends DialogueChoice
## A response gated behind a skill roll — resolves via the real skill
## system (SkillCalculator + Unit.roll_vs) instead of the old GURPS-
## project version's hardcoded trait dictionary, which was never wired
## to an actual character at all.
##
## No QuickContestChoice sibling (opposed NPC roll) yet — there's no
## opposed-roll primitive anywhere in this project's combat system to
## resolve one against. Add it if a scene actually needs an NPC to roll
## back, rather than building it speculatively now.

@export var skill_name: String = ""
@export var success_node_id: String = ""
@export var failure_node_id: String = ""
## False hides the skill tag on the response button (shows "???"
## instead, see DialogueFormat.choice_label) until picked — matches
## BG3's own treatment of a check the character wouldn't consciously
## know they're attempting.
@export var show_to_player: bool = true


func _resolve_next_node_id(actor: Unit, _target: Unit) -> String:
	var result: SkillCheckResult = SkillCalculator.get_skill_level(actor, skill_name)
	if not result.can_use_skill:
		DialogueManager.record_line("(%s has no way to attempt this.)" % skill_name)
		return failure_node_id

	var roll: Dictionary = actor.roll_vs(result.skill_level)
	DialogueManager.record_line(DialogueFormat.skill_result(skill_name, roll.roll, roll.target, roll.success))
	return success_node_id if roll.success else failure_node_id
