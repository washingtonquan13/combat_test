class_name NegotiationChoice
extends DialogueChoice
## Negotiation's own sibling to DialogueChoice — reuses DialogueNode
## directly (that class is pure data, zero coupling to anything) but NOT
## DialogueChoice.resolve() as written, since that method hardcodes
## DialogueManager.record_line() calls for its alignment/dialogue_line
## bookkeeping, even though it's the SHARED, non-virtual base method
## every subclass gets for free. Overriding resolve() itself (not just
## _resolve_next_node_id) is the only way to keep the same bookkeeping
## SHAPE without actually writing into the real dialogue transcript —
## negotiation has no transcript of its own, so SystemLog is the right
## target instead, matching how every other negotiation action already
## logs (see NegotiationManager.end_negotiation).
##
## Extending DialogueChoice (not a fresh base) is what lets
## NegotiationLineChoice/NegotiationOutcomeChoice slot directly into
## DialogueNode.choices: Array[DialogueChoice] with no changes to that
## class at all — text/alignment_name/is_repeatable/dialogue_line/
## sets_flag/prerequisites/effects are all inherited unchanged.

func resolve(actor: Unit, target: Unit) -> String:
	if alignment_name != "":
		actor.apply_alignment_tag(alignment_name)
		SystemLog.print("You performed an action that was %s." % DialogueFormat.alignment_tag(alignment_name))
	if sets_flag != "":
		FlagManager.set_flag(sets_flag)
	for effect in effects:
		effect.apply(actor, target)
		# Checked INSIDE the loop, per effect — a killing effect (see
		# SacrificeHpEffect) isn't guaranteed to be the last one in the
		# array, and there's no next line of dialogue to show an actor
		# who just died mid-negotiation. take_damage() is fully
		# synchronous, so is_alive() already reflects the real outcome
		# here with no await needed.
		if not actor.is_alive():
			NegotiationManager.end_negotiation(NegotiationManager.Outcome.FLEE)
			return ""
	if dialogue_line != "":
		SystemLog.print(DialogueFormat.speaker_line(actor.get_display_name(), dialogue_line))
	return await _resolve_next_node_id(actor, target)
