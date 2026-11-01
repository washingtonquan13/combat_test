class_name NegotiationOutcomeEffect
extends DialogueEffect
## Ends a negotiation with a specific outcome — a tree's actual, explicit
## ending, carried by an ordinary LineChoice. The one place a negotiation
## concludes: the consequences in conclude(), then Conversation.end() with
## the outcome's name, which is what a caller (or a test) reads back as
## Conversation.outcome.
##
## outcome defaults to UNSET (enum index 0, Godot's own default for an
## unset export) if an author forgets to set it — authoring_problem()
## makes Conversations.lint warn about this specifically, since it would
## otherwise silently fall back to FLEE with no other sign anything was
## wrong.
##
## RECRUIT/HEAL are semi-deterministic, not guaranteed — see
## roll_success(). FLEE/ATTACK stay fully authored: those already read as
## "the negotiation went badly" or "this demon just wants to be left
## alone," neither of which needs added suspense the way "will they
## actually join me" does.

enum Outcome { UNSET, RECRUIT, FLEE, ATTACK, HEAL }

@export var outcome: Outcome = Outcome.UNSET


func ends_conversation() -> bool:
	return true


func authoring_problem() -> String:
	if outcome == Outcome.UNSET:
		return "an outcome is left unset — it will resolve as FLEE."
	return ""


func apply(c: Conversation) -> void:
	var resolved: Outcome = outcome
	if resolved == Outcome.UNSET:
		push_warning("NegotiationOutcomeEffect: outcome left unset — resolving as FLEE.")
		resolved = Outcome.FLEE
	var is_chance_gated: bool = resolved == Outcome.RECRUIT or resolved == Outcome.HEAL
	if is_chance_gated and not roll_success(c):
		SystemLog.print("Despite everything, the demon hesitates and backs away.")
		resolved = Outcome.FLEE
	conclude(c, resolved)


## Semi-deterministic, not a guarantee — mood shifts the odds heavily, but
## even a maximally-charmed demon has SOME chance of still declining, and
## even a badly-soured one has some chance of still coming around.
## Confirmed against real reference material (Strange Journey's TALK
## system): good responses "improve success chances," they don't lock in
## success. A failed roll falls back to FLEE rather than the demon turning
## hostile — a failed pitch reads as "no thanks," not a betrayal. Rolled
## on the conversation's own dice, so a pinned seed pins the verdict.
static func roll_success(c: Conversation) -> bool:
	var chance: float = clampf(0.5 + int(c.vars.get("mood", 0)) * 0.1, 0.05, 0.95)
	return c.rng.randf() < chance


## RECRUIT/HEAL/FLEE all remove the negotiated Unit from combat via
## expire() (same cleanup DespawnOnExpireBehavior's timed-summon expiry
## uses) — ATTACK is the one outcome that leaves it fighting normally
## afterward, per design. Static so SpendPardonEffect and the dead-end
## fallback conclude through exactly the same consequences.
static func conclude(c: Conversation, resolved: Outcome) -> void:
	if c.ended:
		return
	var demon: Unit = c.cast.get("npc") as Unit
	var actor: Unit = c.cast.get("player") as Unit

	match resolved:
		Outcome.RECRUIT:
			DemonRoster.recruit(demon.definition)
			SystemLog.print("%s joins your demon roster." % LogFormat.unit_name(demon))
			demon.expire()
		Outcome.FLEE:
			SystemLog.print("%s breaks off and flees." % LogFormat.unit_name(demon))
			demon.expire()
		Outcome.HEAL:
			actor.set_pool(StatIds.HP, floori(actor.get_stat(StatIds.HP)))
			SystemLog.print("%s heals %s and departs peacefully." % [LogFormat.unit_name(demon), LogFormat.unit_name(actor)])
			demon.expire()
		Outcome.ATTACK:
			SystemLog.print("%s was a trick — it attacks!" % LogFormat.unit_name(demon))
			# Same null-guard AttackInteraction.is_available() uses before
			# calling default_ability() — a negotiable unit with no
			# abilities authored shouldn't crash the outcome, just skip the
			# free strike and remain hostile.
			if demon.default_ability():
				demon.use_ability(demon.default_ability(), actor)

	c.end(ending_name(resolved))


## The outcome's name as Conversation.outcome carries it — the engine
## stores a StringName, not this enum, because it has no idea what a
## negotiation is.
static func ending_name(resolved: Outcome) -> StringName:
	match resolved:
		Outcome.RECRUIT:
			return &"recruit"
		Outcome.ATTACK:
			return &"attack"
		Outcome.HEAL:
			return &"heal"
	return &"flee"
