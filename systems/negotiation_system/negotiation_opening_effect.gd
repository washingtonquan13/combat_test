class_name NegotiationOpeningEffect
extends DialogueEffect
## Sets up a negotiation's own variables — authored as a start effect on
## every negotiation greeting (see DialogueNode.start_effects), so the
## conversation engine never learns what a negotiation is. Everything the
## old negotiation manager did when a negotiation began, as content:
##   mood   — how well this is going, read by MoodPrerequisite and moved
##            by ShiftMoodEffect/VolatileMoodEffect
##   gold   — this encounter's price, spent by SacrificeNegotiatedGoldEffect
##            and shown in text through the {gold} token
##   pardon — how many disliked answers the demon will still let slide
##            (see SpendPardonEffect)
## and a dead end that fails safe to FLEE, because a negotiation must
## always end SOMEHOW — there is no neutral "just stop talking" the way
## ordinary dialogue has.


## Alignment/tendency mismatch nudges the starting mood down instead of a
## flat 0 — the closest cheap equivalent to the real eligibility check's
## "opposite-alignment demons start out with a worse attitude" rule,
## reusing Unit.alignment_category()/tendency_category() exactly as
## AlignmentPrerequisite and the party overview's alignment grid do.
## Gold is a rank-scaled random range, not a flat authored number — a
## Fiend should plausibly ask for more than a goblin, and repeat
## encounters with the same species shouldn't always demand the same
## amount. The roll is on the conversation's own dice, so a pinned seed
## pins the price.
func apply(c: Conversation) -> void:
	var actor: Unit = c.cast.get("player") as Unit
	var demon: Unit = c.cast.get("npc") as Unit
	var mismatch: int = absi(actor.alignment_category() - demon.alignment_category()) \
			+ absi(actor.tendency_category() - demon.tendency_category())
	c.vars["mood"] = -mismatch
	var rank: int = demon.definition.rank if demon.definition else 1
	c.vars["gold"] = c.rng.randi_range(rank * 10, rank * 20)
	c.vars["pardon"] = 1

	var flee := NegotiationOutcomeEffect.new()
	flee.outcome = NegotiationOutcomeEffect.Outcome.FLEE
	c.dead_end_effect = flee
