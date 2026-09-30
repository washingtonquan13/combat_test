class_name DialogueChoice
extends Resource
## Base for one dialogue response option. Same discipline as this
## project's AbilityTargeting/PrerequisiteRule/InteractionOption: the
## data (a subclass's own @export fields) and the logic that interprets
## it live together on the same resource, not split across a data
## resource and a manager-side type-switch — the old GURPS-project
## version resolved every choice type inside its dialogue manager's own
## if/elif chain (three near-identical copies of the same alignment/
## dialogue_line bookkeeping), which is exactly what this replaces.
##
## resolve() is NOT virtual — it's the bookkeeping every choice type
## needs regardless of what it does (echo the alignment as a transcript
## aside, echo dialogue_line as the player's spoken response), done once
## here instead of per-subclass. _resolve_next_node_id is the only thing
## a subclass actually overrides — the part that genuinely differs
## between "just move on" and "roll a skill check first."
##
## One class for every kind of conversation. Negotiation used to need a
## sibling family (NegotiationChoice and friends) only so resolve() could
## write somewhere other than the dialogue transcript; every conversation
## now keeps one transcript, observers decide where else its entries go
## (see NegotiateInteraction._echo_to_log), and a negotiation's endings are
## effects (NegotiationOutcomeEffect), so an ordinary LineChoice does both
## jobs.

@export var text: String
@export var alignment_name: String = ""
@export var is_repeatable: bool = false
@export var dialogue_line: String = ""
## Set on FlagManager the instant this choice is picked — the write
## half of dialogue's flag/state support. "" means this choice doesn't
## touch a flag, the common case.
@export var sets_flag: String = ""
## Optional gate on whether this choice is even offered — see
## Conversation._show_node, which filters on this the same way it
## already filters on used_choices. Unlike used_choices (which only
## suppresses a choice within ONE conversation, and resets on the next),
## a FlagPrerequisite persists across separate conversations entirely,
## since it reads FlagManager rather than the conversation's own state.
## An AlignmentPrerequisite works the same way, gating on the acting
## unit's alignment/tendency category instead.
@export var prerequisites: PrerequisiteRule = null
## What this choice does to the world beyond the flag/alignment
## bookkeeping above — give an item, start a fight, shift a mood, end a
## negotiation, anything a DialogueEffect subclass adds. Applied in array
## order, after the bookkeeping below so a flag this same choice sets is
## already visible to an effect that might care.
@export var effects: Array[DialogueEffect] = []


## c is the conversation this choice was picked in. The acting unit is
## c.cast.player (the player-controlled participant); the one addressed is
## c.cast.npc. Returns the id of the node to show next, "" for none.
func resolve(c: Conversation) -> String:
	var actor: Unit = c.cast.get("player") as Unit
	if alignment_name != "":
		actor.apply_alignment_tag(alignment_name)
		# Plain text plus a styling hint, not BBCode: the log and the
		# SystemLog echo color the "(Lawful)" part themselves (see
		# DialogueFormat.entry_bbcode).
		c.record("", "You performed an action that was (%s)." % alignment_name,
				{"tag": &"alignment", "alignment": alignment_name})
	if sets_flag != "":
		FlagManager.set_flag(sets_flag)
	for effect in effects:
		effect.apply(c)
		# Checked per effect, not once at the end: an outcome effect ends
		# the conversation, and a killing effect (see SacrificeHpEffect)
		# isn't guaranteed to be the last one in the array. take_damage()
		# is synchronous, so is_alive() already reflects the real result.
		if c.ended:
			return ""
		if c.dead_end_effect != null and is_instance_valid(actor) and not actor.is_alive():
			c.dead_end_effect.apply(c)
			return ""
	if dialogue_line != "":
		# "player" specifically (not empty) — this is the response actor
		# just spoke aloud, not a system aside, so the log should
		# attribute it to them the same way a node's own text_block gets
		# attributed to its speaker.
		c.record("player", dialogue_line)
	return await _resolve_next_node_id(c)


## Aggregates every non-empty DialogueEffect.cost_tag() across effects,
## in array order — presentation metadata for the same fairness gap
## cost_tag() itself documents: a choice that costs HP/FP/gold/an item
## would otherwise show nothing until AFTER it's picked, since resolve()
## above only echoes what happened, never what it will cost. A plain
## LineChoice or one whose effects are all non-cost (GiveItemEffect, mood
## shifts) returns an empty array, not a padded one — nothing to warn
## about.
func cost_tags(c: Conversation) -> PackedStringArray:
	var tags: PackedStringArray = []
	for effect in effects:
		var tag: String = effect.cost_tag(c)
		if tag != "":
			tags.append(tag)
	return tags


## Not actually async on the base class or LineChoice — GDScript
## doesn't require a function to declare await just because SOME
## override (SkillCheckChoice/QuickContestChoice, awaiting the dice via
## Conversation.show) uses it internally. awaiting a plain synchronous
## return value here resolves immediately, so this costs nothing for a
## choice that never rolls anything.
func _resolve_next_node_id(_c: Conversation) -> String:
	push_error("%s doesn't implement _resolve_next_node_id() yet" % get_script().resource_path)
	return ""
