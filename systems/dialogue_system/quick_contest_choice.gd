class_name QuickContestChoice
extends DialogueChoice
## A response resolved as a GURPS Quick Contest of Skill (Basic Set
## B348) — actor's skill rolled against target's skill, not a fixed
## number. See skill_check_choice.gd's own header, which named this as
## the natural next step once a scene actually needed an NPC to roll
## back — this is that scene.
##
## Conversation.find_assisting_companion()'s bonus applies to the actor's
## side only — an ally helps the player, never the NPC.

@export var skill_name: String = ""
@export var npc_skill_name: String = ""
@export var success_node_id: String = ""
@export var failure_node_id: String = ""
## False hides the skill preview on the response row, same as
## SkillCheckChoice.show_to_player.
@export var show_to_player: bool = true


func _resolve_next_node_id(c: Conversation) -> String:
	var actor: Unit = c.cast.get("player") as Unit
	var npc: Unit = c.cast.get("npc") as Unit
	var check: Dictionary = c.check_target(skill_name)
	var npc_result: SkillCheckResult = SkillCalculator.get_skill_level(npc, npc_skill_name)

	# An NPC with no way to use their side's skill still gets a real
	# roll against target 0 rather than auto-losing — a natural 3 or 4
	# is always a critical success in GURPS regardless of skill (see
	# SuccessRoll), so even an untrained NPC keeps a slim chance.
	var npc_target: int = npc_result.skill_level if npc_result.can_use_skill else 0

	# Both rolls are fully decided here, on the conversation's own dice,
	# same as SkillCheckChoice — only the actor's own dice get shown (an
	# opposed check doesn't reveal the NPC's roll visually any more than an
	# attack roll reveals an enemy's exact defenses; their result still
	# fully counts, just via the text readout below, not the dice).
	var actor_roll: Dictionary = actor.roll_vs(check.target, c.rng)
	var npc_roll: Dictionary = npc.roll_vs(npc_target, c.rng)
	await c.show(&"dice", {"skill": skill_name, "roll": actor_roll})
	if c.ended:
		return ""

	var actor_wins: bool = _wins_contest(actor_roll, npc_roll)
	c.record("", DialogueFormat.contest_result(skill_name, actor_roll, npc_skill_name, npc_roll, actor_wins),
			{"tag": &"check", "success": actor_wins,
			"verdict": "You win the contest" if actor_wins else "You lose the contest",
			"skills": [skill_name, npc_skill_name]})
	return success_node_id if actor_wins else failure_node_id


## Whoever's margin (SuccessRoll's target-minus-roll — positive on a
## success, negative on a failure) is greater wins: the bigger the
## margin of success, the more decisive; the smaller the margin of
## failure, the closer they came. A success margin is always >= 0 and
## a failure margin always < 0, so this same comparison also correctly
## handles "one side succeeds, the other fails" with no special-casing
## needed — succeeding always outranks failing already, for free.
static func _wins_contest(actor_roll: Dictionary, npc_roll: Dictionary) -> bool:
	return actor_roll.margin >= npc_roll.margin
