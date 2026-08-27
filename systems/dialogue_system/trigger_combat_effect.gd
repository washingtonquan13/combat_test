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
	# Same escalation FactionRelations expects any provoked hostility to
	# go through (see UnitCombat._maybe_trigger_combat) — without this,
	# the two combatants would share a turn_order for this fight but
	# still read as non-hostile everywhere else (is_hostile_to, Attack's
	# own availability, etc.), since nothing else here ever touched
	# faction relations.
	target.attacked_non_hostile_unit.emit(target, actor)
	FactionRelations.escalate_to_temporary_hostile(target.faction, actor.faction)
	CombatManager.start_combat_from_hostile_act(target, actor)
