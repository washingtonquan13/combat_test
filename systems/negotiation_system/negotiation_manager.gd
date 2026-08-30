extends Node
## Autoload singleton. Register as "NegotiationManager" under
## Project > Project Settings > AutoLoad.
##
## Orchestrates one negotiation at a time — a combat-capable sibling of
## DialogueManager, reusing DialogueNode/DialogueChoice as its content
## model (see NegotiationChoice for why DialogueChoice itself needed a
## sibling override rather than literal reuse) but indexing its own
## separate content folder — negotiation trees are never mixed into the
## real dialogue system's id-namespace. DialogueManager itself can't be
## reused directly as the orchestrator either: it explicitly refuses to
## start during combat (see its own start_dialogue), and negotiation is
## explicitly combat-ONLY by design.
##
## Deliberately dumb about PRESENTATION, same split as DialogueManager
## itself — negotiation_panel.gd just listens to the signals below and
## reacts; this file never touches a Control.

signal negotiation_started(demon: Unit)
signal line_shown(text: String)
signal choices_shown(choices: Array[DialogueChoice])
signal negotiation_ended(outcome: Outcome)
## See current_mood's own doc comment for why this exists alongside
## SystemLog rather than instead of it.
signal mood_note_shown(text: String)

## CONTINUE never reaches negotiation_ended — end_negotiation() refuses
## to be called with it. It only exists as NegotiationOutcomeChoice's
## own default value (Godot's own default for an unset export is
## whichever enum entry is index 0) so an author who forgets to set
## outcome gets flagged by _validate_node_references() below, rather
## than a silent wrong ending with no other sign anything was missed.
enum Outcome { CONTINUE, RECRUIT, FLEE, ATTACK, HEAL_PLAYER }

const CONVERSATIONS_DIR: String = "res://data/negotiation/conversations"

var current_demon: Unit = null
var current_actor: Unit = null
var current_node: DialogueNode = null

## Per-negotiation "how well is this going" counter — authored choices
## read it via MoodPrerequisite and write it via ShiftMoodEffect (see
## both under systems/negotiation_system/ and systems/skill_system/).
## No numeric meter in the UI (this project has no art budget for a new
## reaction-icon indicator — see the portrait-scarcity precedent from
## the SMT race roster), but NOT silent either: shift_mood() narrates
## every change, matching how real modern SMT negotiation (Strange
## Journey's TALK system, not Nocturne's more opaque one) actually
## surfaces mood — no bar, but real text feedback the player can read
## and react to. Goes out through TWO channels, not one: SystemLog (the
## same system-aside channel end_negotiation() already uses for its own
## outcomes — becomes visible the moment tactical_ui reappears, whether
## that's immediately after an outcome closes the panel or much later)
## AND mood_note_shown below, specifically for negotiation_panel.gd to
## surface WHILE the panel is still open and SystemLog itself is hidden
## behind it — a mood shift on a choice that continues the conversation
## (not an immediately-ending outcome) would otherwise go unseen until
## the negotiation was already over.
var current_mood: int = 0
## This encounter's rolled gold amount — computed once per negotiation
## in start_negotiation(), rank-scaled so a Tyrant asks for more than a
## goblin. Used both directions: the player offering gold, or paying a
## demon's own demand (see SacrificeNegotiatedGoldEffect) — same number
## either way, just authored into different choices. Referenced in
## authored text via the {gold} token (see format_text()).
var current_gold_amount: int = 0
## One pardon per negotiation, consumed by try_forgive() — see that
## method's own doc comment. Matches the real, confirmed mechanic: a
## demon may let exactly one "disliked" (never "hated") answer slide
## before the negotiation ends.
var forgiveness_available: bool = true

## "node_id:index" -> true — exact mirror of DialogueManager.used_choices.
var used_choices: Dictionary = {}
## The exact filtered list _show_node() last emitted via choices_shown —
## choose() indexes into THIS, not current_node.choices. See choose()'s
## own doc comment for why: a real, already-fixed bug in DialogueManager
## whose FIX this copies, not just its shape.
var _visible_choices: Array[DialogueChoice] = []

var _index := DialogueNodeIndex.new("NegotiationManager")
## Guards _validate_node_references() specifically — separate from
## _index's own internal "indexed once" tracking, since _ensure_indexed()
## below is called on every node lookup but validation must still only
## ever run the first time.
var _validated: bool = false


func _ready() -> void:
	_ensure_indexed()


func is_active() -> bool:
	return current_demon != null


## Mutual exclusion with DialogueManager/StashManager mirrors how
## DialogueManager.start_dialogue() itself refuses to start over either
## of those — same reasoning here, just the opposite combat condition:
## negotiation is explicitly COMBAT-ONLY (dialogue is explicitly
## combat-EXCLUDED), so a hostile demon Unit is never accidentally both
## "in a conversation" and "being negotiated with" at once.
func start_negotiation(actor: Unit, demon: Unit) -> void:
	# The ACTOR's own fight. any_combat_running() asks whether anything is
	# happening anywhere, which was the same question while there was one
	# world — and became "a demon in no fight at all is negotiable, as long
	# as somebody somewhere is fighting".
	if not actor.in_combat() or is_active() or DialogueManager.is_active() or StashManager.is_active():
		return
	if not demon.negotiable or not demon.is_alive() or not demon.definition:
		return
	var root: DialogueNode = demon.definition.resolve_negotiation_root(actor)
	if not root:
		return

	current_actor = actor
	current_demon = demon
	used_choices.clear()
	forgiveness_available = true
	# Alignment/tendency mismatch nudges the starting mood down instead
	# of a flat 0 — the closest cheap equivalent to the real eligibility
	# check's "opposite-alignment demons start out with a worse attitude"
	# rule, reusing Unit.alignment_category()/tendency_category() exactly
	# as AlignmentPrerequisite/the party overview's alignment grid already
	# do, rather than a new threshold system.
	var mismatch: int = absi(actor.alignment_category() - demon.alignment_category()) \
			+ absi(actor.tendency_category() - demon.tendency_category())
	current_mood = -mismatch
	# Rank-scaled random range, not a flat authored number — a Fiend
	# should plausibly ask for more than a goblin, and repeat encounters
	# with the same species shouldn't always demand the exact same
	# amount.
	var rank: int = demon.definition.rank
	current_gold_amount = randi_range(rank * 10, rank * 20)

	GameMode.push_mode(GameMode.Mode.NEGOTIATION)
	negotiation_started.emit(demon)
	_show_node(root)


func shift_mood(amount: int) -> void:
	current_mood += amount

	var note: String = ""
	if amount >= 3:
		note = "The demon's mood brightens considerably."
	elif amount > 0:
		note = "The demon's mood seems to improve."
	elif amount <= -3:
		note = "That visibly sours the demon's mood."
	elif amount < 0:
		note = "The mood turns a bit awkward..."

	if note != "":
		SystemLog.print(note)
		mood_note_shown.emit(note)


## One pardon per negotiation — consumed on first use, false forever
## after (see PersonalityDislikedChoice, the one caller). "Hated"
## answers never call this — see PersonalityHatedChoice, which is never
## forgivable by design.
func try_forgive() -> bool:
	if not forgiveness_available:
		return false
	forgiveness_available = false
	SystemLog.print("The demon lets that one slide... this time.")
	return true


## Semi-deterministic, not a guarantee — mood shifts the odds heavily,
## but even a maximally-charmed demon has SOME chance of still declining,
## and even a badly-soured one has some chance of still coming around.
## Confirmed against real reference material (Strange Journey's TALK
## system): good responses "improve success chances," they don't lock in
## success — see NegotiationOutcomeChoice._resolve_next_node_id, the one
## caller, for how a failed roll on RECRUIT/HEAL_PLAYER falls back to
## FLEE rather than the demon turning hostile — a failed pitch reads as
## "no thanks," not a betrayal, matching how the reference material's own
## failure state played out (the demon just left).
func roll_success() -> bool:
	var chance: float = clampf(0.5 + current_mood * 0.1, 0.05, 0.95)
	return randf() < chance


## Substitutes the {gold} token with this encounter's own rolled amount
## — the one dynamic value negotiation text ever needs to show, so a
## single fixed token beats building a general templating engine nothing
## else in the dialogue system has any need for. Choice/node resources
## are loaded once and SHARED across every negotiation with that
## species, so this can't mutate .text in place — that would corrupt the
## authored data for every future encounter. negotiation_panel.gd calls
## this on whatever text it's about to render instead.
func format_text(text: String) -> String:
	return text.replace("{gold}", str(current_gold_amount))


## index is a position in the FILTERED list negotiation_panel.gd
## actually rendered — find() recovers the choice's stable position in
## the full node.choices array, which is what used_choices' key format
## depends on. This is NOT optional polish: DialogueManager had a real,
## confirmed bug (see that file's own header) where indexing the raw
## click position straight into node.choices broke the instant a node
## was revisited with an earlier choice already hidden, silently firing
## the wrong one instead. Nothing here prevents an authored
## next_node_id from looping back to an earlier node, so this is
## defended against from the start rather than discovered the hard way
## a second time.
func choose(index: int) -> void:
	if not is_active() or not current_node or index < 0 or index >= _visible_choices.size():
		return

	var choice: DialogueChoice = _visible_choices[index]
	var full_index: int = current_node.choices.find(choice)
	used_choices["%s:%d" % [current_node.id, full_index]] = true

	var next_id: String = await choice.resolve(current_actor, current_demon)
	if not is_active():
		# A NegotiationOutcomeChoice (or a lethal SacrificeHpEffect) may
		# have already concluded things from inside resolve() itself —
		# same "reach into the orchestrator from within a choice's own
		# resolution" pattern SkillCheckChoice already uses on
		# DialogueManager.
		return
	_load_node_by_id(next_id)


## The one place every negotiation actually concludes — never called
## with Outcome.CONTINUE (see that enum's own doc comment).
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
			DemonRoster.recruit(demon.definition)
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
	current_node = null
	_visible_choices = []
	GameMode.pop_mode()
	negotiation_ended.emit(outcome)


## Filters node.choices by used_choices/is_repeatable and by
## prerequisites — the SAME two conditions DialogueManager._show_node
## already applies, evaluated against current_actor (the negotiating
## player unit), matching how DialogueManager always evaluates a
## choice's prerequisites against its own "player" participant rather
## than the NPC/demon being spoken to.
##
## An empty filtered result is ALWAYS an authoring gap here, unlike
## regular dialogue (where empty choices + empty next_node_id is a
## valid, intentional way to end a conversation) — a negotiation tree
## must always end via an explicit NegotiationOutcomeChoice, so
## DialogueNode.next_node_id is authored-but-never-read for negotiation
## content. Reaching a dead end fails safe to FLEE with a warning rather
## than leaving the panel showing no way to respond at all.
func _show_node(node: DialogueNode) -> void:
	current_node = node
	line_shown.emit(node.text_block)

	var visible: Array[DialogueChoice] = []
	for i in node.choices.size():
		var choice: DialogueChoice = node.choices[i]
		var key: String = "%s:%d" % [node.id, i]
		if used_choices.has(key) and not choice.is_repeatable:
			continue
		if choice.prerequisites and not choice.prerequisites.is_satisfied(current_actor):
			continue
		visible.append(choice)
	_visible_choices = visible

	if visible.is_empty():
		push_warning("NegotiationManager: node '%s' has no available choices — negotiation trees must always end via an explicit NegotiationOutcomeChoice. Falling back to FLEE." % node.id)
		end_negotiation(Outcome.FLEE)
		return

	choices_shown.emit(visible)


func _load_node_by_id(id: String) -> void:
	if id == "":
		# There's no neutral "just end" for a negotiation the way
		# DialogueManager.end_dialogue() has for a normal conversation —
		# SOME outcome must always occur, so an empty id (most likely a
		# NegotiationLineChoice with next_node_id left unset) fails safe
		# the same way an unresolvable one does below.
		end_negotiation(Outcome.FLEE)
		return

	var node: DialogueNode = _find_node(id)
	if not node:
		push_error("NegotiationManager: no node found for id '%s'" % id)
		end_negotiation(Outcome.FLEE)
		return

	_show_node(node)


func _find_node(id: String) -> DialogueNode:
	_ensure_indexed()
	return _index.find_node(id)


func _ensure_indexed() -> void:
	_index.ensure_indexed(CONVERSATIONS_DIR)
	if OS.is_debug_build() and not _validated:
		_validated = true
		_validate_node_references()


## Debug-build-only sanity pass over every hand-typed node-id reference
## and choice-type assumption — mirrors DialogueManager's own
## _validate_node_references()/_check_reference(), for the same reason:
## next_node_id/outcome are authored strings/enums with zero compile-time
## checking, and a wrong one here resolves as a plausible-looking but
## WRONG outcome rather than an obvious crash — a strictly easier way to
## ship a bug unnoticed than dialogue's own equivalent typo.
func _validate_node_references() -> void:
	for id in _index.all_ids():
		var node: DialogueNode = _index.find_node(id)
		for choice in node.choices:
			if choice is NegotiationLineChoice:
				_check_reference(id, "NegotiationLineChoice.next_node_id", choice.next_node_id)
			elif choice is NegotiationOutcomeChoice:
				if choice.outcome == Outcome.CONTINUE:
					push_warning("NegotiationManager: node '%s' has a NegotiationOutcomeChoice with outcome left unset (CONTINUE) — will silently resolve as FLEE." % id)
			elif choice is PersonalityDislikedChoice:
				_check_reference(id, "PersonalityDislikedChoice.next_node_id", choice.next_node_id)
			elif choice is PersonalityHatedChoice:
				pass  # No reference to validate — always resolves ATTACK unconditionally.
			elif choice is NegotiationChoice:
				pass  # A real NegotiationChoice subclass this validator doesn't know the specific shape of yet — nothing wrong, just nothing more to check.
			else:
				push_warning("NegotiationManager: node '%s' has a choice of type '%s', not a NegotiationChoice subclass — it will call the real DialogueManager instead of this system." % [id, choice.get_script().resource_path])


## Deliberately diverges from DialogueManager._check_reference()'s own
## version, which treats an empty target as always valid (a real,
## intentional way to end normal dialogue). Empty is NEVER a valid
## ending here — see _load_node_by_id, which treats "" as "fail safe to
## FLEE," not "end normally" — so an empty next_node_id gets its own
## warning instead of a silent pass.
func _check_reference(from_id: String, field_name: String, target_id: String) -> void:
	if target_id == "":
		push_warning("NegotiationManager: %s on node '%s' is empty — a negotiation tree should always end via an explicit NegotiationOutcomeChoice, not an empty next_node_id." % [field_name, from_id])
	elif not _index.has_id(target_id):
		push_warning("NegotiationManager: %s on node '%s' references unknown node id '%s'." % [field_name, from_id, target_id])
