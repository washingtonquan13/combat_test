class_name DialogueChoice
extends Resource
## Base for one dialogue response option. Same discipline as this
## project's AbilityTargeting/PrerequisiteRule/InteractionOption: the
## data (a subclass's own @export fields) and the logic that interprets
## it live together on the same resource, not split across a data
## resource and a manager-side type-switch — the old GURPS-project
## version resolved every choice type inside DialogueManager.choose()'s
## own if/elif chain (three near-identical copies of the same alignment/
## dialogue_line bookkeeping), which is exactly what this replaces.
##
## resolve() is NOT virtual — it's the bookkeeping every choice type
## needs regardless of what it does (echo the alignment as a transcript
## line, echo dialogue_line as the player's spoken response), done once
## here instead of per-subclass. _resolve_next_node_id is the only thing
## a subclass actually overrides — the part that genuinely differs
## between "just move on" and "roll a skill check first."

@export var text: String
@export var alignment_name: String = ""
@export var is_repeatable: bool = false
@export var dialogue_line: String = ""
## Set on FlagManager the instant this choice is picked — the write
## half of dialogue's flag/state support. "" means this choice doesn't
## touch a flag, the common case.
@export var sets_flag: String = ""
## Optional gate on whether this choice is even offered — see
## DialogueManager._show_node, which filters on this the same way it
## already filters on used_choices. Unlike used_choices (which only
## suppresses a choice within ONE conversation, and resets on the next),
## a FlagPrerequisite persists across separate conversations entirely,
## since it reads FlagManager rather than DialogueManager's own
## per-conversation state. An AlignmentPrerequisite works the same way,
## gating on the acting unit's alignment/tendency category instead.
@export var prerequisites: PrerequisiteRule = null
## What this choice does to the world beyond the flag/alignment
## bookkeeping above — give an item, start a fight, anything a future
## DialogueEffect subclass adds. Applied in array order, after the
## bookkeeping below so a flag this same choice sets is already visible
## to an effect that might care.
@export var effects: Array[DialogueEffect] = []


## actor is whichever Unit is speaking THIS response (the player-
## controlled participant), target is who they're speaking to — same
## actor/target shape as InteractionOption.execute, passed straight
## through from DialogueManager.choose().
func resolve(actor: Unit, target: Unit) -> String:
	if alignment_name != "":
		actor.apply_alignment_tag(alignment_name)
		DialogueManager.record_line("You performed an action that was %s." % DialogueFormat.alignment_tag(alignment_name))
	if sets_flag != "":
		FlagManager.set_flag(sets_flag)
	for effect in effects:
		effect.apply(actor, target)
	if dialogue_line != "":
		# "player" specifically (not empty) — this is the response actor
		# just spoke aloud, not a system aside, so the log should
		# attribute it to them the same way a node's own text_block gets
		# attributed to its speaker.
		DialogueManager.record_line(dialogue_line, "player")
	return _resolve_next_node_id(actor, target)


func _resolve_next_node_id(_actor: Unit, _target: Unit) -> String:
	push_error("%s doesn't implement _resolve_next_node_id() yet" % get_script().resource_path)
	return ""
