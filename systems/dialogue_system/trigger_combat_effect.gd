class_name TriggerCombatEffect
extends DialogueEffect
## A conversation turning hostile — the "negotiation fails" case named in
## dialogue_system_bg3_gap_analysis.md. Routes through the exact same
## entry point AttackInteraction already uses (CombatManager
## .start_combat_from_hostile_act), just with target as the instigator
## instead of actor: the NPC is the one breaking the conversation, so
## THEIR first action is what gets skipped (see
## start_combat_from_hostile_act's _skip_first_action_for) — the player
## gets the opening move, same as if they'd seen the betrayal coming.
##
## Doesn't end the conversation itself — pair this on a choice whose
## next_node_id (or LineChoice equivalent) is already "" so the dialogue
## closes as combat starts, rather than baking a forced close in here.
## A future "NPC threatens you but keeps talking" beat shouldn't have to
## fight this effect to stay open.

func apply(actor: Unit, target: Unit) -> void:
	CombatManager.start_combat_from_hostile_act(target, actor)
