extends Node
## Autoload singleton. Register as "NegotiationManager" under
## Project > Project Settings > AutoLoad.
##
## Orchestrates one negotiation at a time — a lighter, COMBAT-ONLY
## sibling to DialogueManager, not built on top of it: SMT-style
## negotiation is a fixed response list plus personality-weighted
## outcome rolling, not a branching node graph, and this project's own
## design pass explicitly scoped it as "a different, lighter interaction
## flow," not a reskin of the full conversation system. Deliberately
## dumb about PRESENTATION, same split as DialogueManager itself —
## negotiation_panel.gd just listens to the signals below and reacts;
## this file never touches a Control.
##
## Resolution: every response you pick shifts a running favor score
## (tone match), then rolls the demon's personality weights (adjusted by
## that favor) against each other to see whether THIS round ends things
## — nothing is fully certain, matching real SMT negotiation's own
## any-exchange-can-end-it feel. A round that rolls toward FLEE/ATTACK
## gives the player one last chance to sweeten the deal with a real
## sacrifice (see make_offer) before it locks in.

signal negotiation_started(demon: Unit)
signal responses_shown(responses: Array[NegotiationResponse])
signal offer_requested()
signal negotiation_ended(outcome: Outcome)

## CONTINUE never reaches negotiation_ended — it only ever lives inside
## _roll_outcome()/_advance_round(), meaning "keep talking, no resolution
## yet." Kept in the same enum as the real outcomes (rather than a
## separate internal-only enum) so _roll_outcome()'s weighted-pick table
## and end_negotiation()'s match can both key off ONE set of values that
## can never drift out of sync with each other.
enum Outcome { CONTINUE, RECRUIT, FLEE, ATTACK, HEAL_PLAYER }

## ITEM/MONEY exist as real cases so content and UI can reference them
## by name, but make_offer() below only actually implements HP/FP —
## this project has no currency system, and an item offer needs a real
## picker (matching StashPanel's reparent-into-a-slot idiom); neither is
## built here. See this project's own demon-system plan for the same
## explicit descope.
enum OfferType { HP, FP, ITEM, MONEY }

const RESPONSES_DIR: String = "res://data/negotiation/responses/"

var current_demon: Unit = null
var current_actor: Unit = null
var current_favor: int = 0
var current_round: int = 0

var _responses: Array[NegotiationResponse] = []
## Response -> true once chosen this negotiation — mirrors
## DialogueManager.used_choices exactly, same reason: a non-repeatable
## response should stop being offered after its first use.
var _used_responses: Dictionary = {}
## The FLEE/ATTACK result a bad roll landed on, held while offer_requested
## is out for the player's decision — decline_offer() locks this in
## as-is; make_offer() re-rolls instead of using it, but a fresh bad
## roll overwrites it the same way.
var _pending_outcome: Outcome = Outcome.CONTINUE


func is_active() -> bool:
	return current_demon != null


## Mutual exclusion with DialogueManager/StashManager mirrors how
## DialogueManager.start_dialogue() itself refuses to start over either
## of those — same reasoning here, just the opposite combat condition:
## negotiation is explicitly COMBAT-ONLY (dialogue is explicitly
## combat-EXCLUDED), so a hostile demon Unit is never accidentally both
## "in a conversation" and "being negotiated with" at once.
func start_negotiation(actor: Unit, demon: Unit) -> void:
	if not CombatManager.in_combat or is_active() or DialogueManager.is_active() or StashManager.is_active():
		return
	if not demon.negotiable or not demon.is_alive() or not demon.negotiation_species:
		return

	current_actor = actor
	current_demon = demon
	current_favor = 0
	current_round = 0
	_pending_outcome = Outcome.CONTINUE
	_used_responses.clear()
	if _responses.is_empty():
		_load_responses()

	negotiation_started.emit(demon)
	responses_shown.emit(_visible_responses())


## Async since Unit.use_ability() (see end_negotiation's ATTACK branch)
## is a coroutine — matches how every other fire-and-forget caller of
## use_ability elsewhere in this project already handles that, never
## awaiting its result.
func choose_response(response: NegotiationResponse) -> void:
	if not is_active():
		return
	_used_responses[response] = true
	var personality: DemonPersonality = _current_personality()
	if personality:
		current_favor += personality.tone_favor(response.tone)
	_advance_round()


## HP sacrifice goes through the REAL take_damage() path — genuine
## stakes, not a cosmetic number, per this feature's own design (see
## demon_negotiation_fusion_system.md). Self-limiting on its own: an
## actor who keeps offering HP can actually die from it, which is why
## this checks is_alive() immediately after and bails the negotiation
## out safely rather than letting a dead actor keep "negotiating."
func make_offer(offer_type: OfferType, amount: int) -> void:
	if not is_active() or amount <= 0:
		return
	match offer_type:
		OfferType.HP:
			current_actor.take_damage(amount)
			if not current_actor.is_alive():
				end_negotiation(Outcome.FLEE)
				return
			current_favor += amount
		OfferType.FP:
			current_actor.current_fp = maxi(current_actor.current_fp - amount, 0)
			current_favor += amount
		OfferType.ITEM, OfferType.MONEY:
			return
	_advance_round()


func decline_offer() -> void:
	if not is_active():
		return
	end_negotiation(_pending_outcome)


## The one place every negotiation actually concludes — never called
## with Outcome.CONTINUE (see this file's own Outcome doc comment).
## RECRUIT/HEAL_PLAYER/FLEE all remove the negotiated Unit from combat
## via expire() (same cleanup DespawnOnExpireBehavior's timed-summon
## expiry already uses) — ATTACK is the one outcome that leaves it
## fighting normally afterward, per design.
func end_negotiation(outcome: Outcome) -> void:
	if not is_active() or outcome == Outcome.CONTINUE:
		return

	var demon: Unit = current_demon
	var actor: Unit = current_actor

	match outcome:
		Outcome.RECRUIT:
			DemonRoster.recruit(demon.negotiation_species)
			SystemLog.print("%s joins your demon roster." % LogFormat.unit_name(demon))
			demon.expire()
		Outcome.FLEE:
			SystemLog.print("%s breaks off and flees." % LogFormat.unit_name(demon))
			demon.expire()
		Outcome.HEAL_PLAYER:
			actor.current_hp = actor.maximum_hp
			SystemLog.print("%s heals %s and departs peacefully." % [LogFormat.unit_name(demon), LogFormat.unit_name(actor)])
			demon.expire()
		Outcome.ATTACK:
			SystemLog.print("%s was a trick — it attacks!" % LogFormat.unit_name(demon))
			# Same null-guard AttackInteraction.is_available() already uses
			# before calling default_ability() — a negotiable unit with no
			# abilities authored shouldn't crash the outcome, just skip the
			# free strike and remain hostile.
			if demon.default_ability():
				demon.use_ability(demon.default_ability(), actor)

	current_demon = null
	current_actor = null
	_pending_outcome = Outcome.CONTINUE
	negotiation_ended.emit(outcome)


func _advance_round() -> void:
	current_round += 1
	var result: Outcome = _roll_outcome()
	if result == Outcome.CONTINUE:
		responses_shown.emit(_visible_responses())
		return
	if result == Outcome.FLEE or result == Outcome.ATTACK:
		_pending_outcome = result
		offer_requested.emit()
		return
	end_negotiation(result)


## Weighted random pick across CONTINUE plus the four real outcomes.
## CONTINUE starts high and decays each round (floored, never reaching
## zero) so early rounds favor more back-and-forth and later ones are
## more likely to resolve, without a hard round cap — matches the
## "nothing guaranteed, real roll" resolution this was explicitly built
## around rather than a deterministic threshold.
func _roll_outcome() -> Outcome:
	var personality: DemonPersonality = _current_personality()
	if not personality:
		# No personality authored on this content yet — treat as simply
		# uninterested rather than crashing on a null dereference.
		return Outcome.FLEE

	var weights: Dictionary[Outcome, float] = {
		Outcome.CONTINUE: maxf(3.0 - current_round, 0.5),
		Outcome.RECRUIT: maxf(personality.recruit_weight + current_favor, 0.0),
		Outcome.FLEE: maxf(personality.flee_weight - current_favor * 0.5, 0.0),
		Outcome.ATTACK: maxf(personality.attack_weight - current_favor, 0.0),
		Outcome.HEAL_PLAYER: maxf(personality.heal_weight + maxf(current_favor, 0.0) * 0.5, 0.0),
	}
	if not personality.alignment_acceptable(current_demon, current_actor) or not personality.tendency_acceptable(current_demon, current_actor):
		weights[Outcome.RECRUIT] = 0.0

	var total: float = 0.0
	for w in weights.values():
		total += w
	if total <= 0.0:
		return Outcome.CONTINUE

	var roll: float = randf() * total
	var accumulated: float = 0.0
	for result in weights:
		accumulated += weights[result]
		if roll < accumulated:
			return result
	return Outcome.CONTINUE


func _current_personality() -> DemonPersonality:
	if not current_demon or not current_demon.negotiation_species:
		return null
	return current_demon.negotiation_species.personality


func _visible_responses() -> Array[NegotiationResponse]:
	var result: Array[NegotiationResponse] = []
	for response in _responses:
		if response.is_repeatable or not _used_responses.has(response):
			result.append(response)
	return result


func _load_responses() -> void:
	for file_name in DirAccess.get_files_at(RESPONSES_DIR):
		if not file_name.ends_with(".tres"):
			continue
		var response := load(RESPONSES_DIR + file_name) as NegotiationResponse
		if response:
			_responses.append(response)
