extends Node
## The ONE place tests/conversation touches the conversation runtime.
##
## These suites pinned what dialogue and negotiation did before both were
## rewritten into one engine (Conversation + the Conversations autoload),
## and the rewrite was judged against them. That only works if the rewrite
## changes this file and nothing else. Every suite here asks the driver to
## start, choose, advance, read the transcript, read mood/pardon/gold, roll
## dice and build content. No suite names Conversation, Conversations, a
## choice class or an effect class itself. When the engine changes,
## re-point these functions. If a suite has to change too, the behaviour it
## pinned changed, and that is a finding, not a port.
##
## What a suite still reaches directly is everything that is NOT the
## conversation runtime: Units and their HP/FP, CurrencyManager gold, the
## DemonRoster, FlagManager, CombatManager, StashManager, SaveManager,
## WorldManager and GameMode. Those are the observable side effects the
## runtime is being held to.
##
## Extends Node and does nothing in _init: the test runner instantiates
## every .gd under tests/ and frees whatever is not an AiTestCase, so this
## file is a suite candidate on every run. Loaded by preload() from each
## suite rather than by class_name, so it needs no editor import to reach
## the class cache.
##
## EVENTS. The engine has one signal, `changed`. The suites were written
## against the old per-manager signals, so this file re-derives the same
## event strings from each change: new transcript entries, a new visit
## (a node shown), and the end. The strings are unchanged so a suite that
## compares them did not have to be rewritten.
##
## RANDOMNESS. Every roll a conversation makes draws from its own
## generator, Conversation.rng: SuccessRoll.roll_vs for skill checks and
## contests, NegotiationOutcomeEffect.roll_success for RECRUIT and HEAL,
## the negotiated gold at start and VolatileMoodEffect. pin() searches for
## a seed under which the caller's own simulation of the next draws comes
## out the way the test needs, then seeds the live conversation with it,
## or, with none live, hands it to Conversations.next_seed for the next
## one to begin. The simulations call the production roll functions
## themselves where they can, so they cannot drift. The rule for callers:
## pin() IMMEDIATELY before the call that rolls, with nothing in between
## that draws from the conversation's dice.

const OVERLAY_SCENE: String = "res://systems/dialogue_system/dialogue_overlay.tscn"
const LOG_SCENE: String = "res://systems/dialogue_system/conversation_log.tscn"
const DICE_SCENE: String = "res://systems/dialogue_system/skill_check_wheel_popup.tscn"
const PANEL_SCENE: String = "res://ui/negotiation_panel.tscn"
const SYNTHETIC_DIR: String = "res://tests/conversation/__synthetic__"

const MOOD_POSITIVE: Color = Color(0.4, 0.75, 0.4)
const MOOD_NEGATIVE: Color = Color(0.8, 0.4, 0.4)
const MOOD_NEUTRAL: Color = Color(0.6, 0.6, 0.6)

## Every conversation event, in arrival order, as short strings a suite
## can compare: "dialogue_started:<id>", "line:<speaker>:<text>",
## "choices:<n>", "dialogue_ended", "negotiation_started:<name>",
## "neg_line:<text>", "neg_choices:<n>", "mood_note:<text>",
## "negotiation_ended:<OUTCOME>", "combat_ended".
var events: Array[String] = []
## Parallel to events: what was true the moment each one fired.
## {dialogue_active, negotiation_active, mode}.
var event_state: Array[Dictionary] = []
## Every dice request seen while hold_dice() is on: {skill, roll}.
var dice_requests: Array[Dictionary] = []

var _log: Array[String] = []
## The latest conversation to begin, kept after it ends, and the latest of
## each presentation, so a "was this used" question can still be asked of
## the negotiation after a dialogue has begun, as it could of two managers.
var _conversation: Conversation = null
var _by_kind: Dictionary = {}
## Progress through _conversation, so each change reports only what is new.
var _seen: int = 0
var _shown_visit: int = -1
var _ended_reported: bool = false
var _holding_dice: bool = false
var _dice_open: int = 0
var _dice_serial: int = -1
var _synthetic: Array[Resource] = []
var _dialogue_ids: Array[String] = []
var _negotiation_ids: Array[String] = []
var _saved: Dictionary = {}
var _attached: bool = false


# --- Lifecycle -----------------------------------------------------

## Start recording and snapshot every global a conversation can touch.
## Pair with finish(). A suite that forgets leaks gold, flags and roster
## entries into every suite after it.
func begin() -> void:
	_saved = {
		"gold": CurrencyManager.gold,
		"flags": FlagManager.save_state(),
		"roster": DemonRoster.save_state(),
		"factions": FactionRelations.save_state(),
		"leader": PartyManager.leader,
		"ai_factions": CombatAi.ai_factions.duplicate(),
	}
	# No AI turns. A demon taking its turn mid-test would move, attack and
	# end turns underneath a suite that is only asking about talking.
	CombatAi.ai_factions = [] as Array[StringName]
	_attach()


func finish() -> void:
	release_dice()
	var live: Conversation = Conversations.current
	if live:
		if live.presentation == &"negotiation":
			NegotiationOutcomeEffect.conclude(live, NegotiationOutcomeEffect.Outcome.FLEE)
		else:
			live.end()
	Conversations.next_seed = -1
	stop_fights()
	_detach()
	_unregister_all()
	if not _saved.is_empty():
		CurrencyManager.gold = _saved["gold"]
		FlagManager.load_state(_saved["flags"])
		DemonRoster.load_state(_saved["roster"])
		FactionRelations.load_state(_saved["factions"])
		PartyManager.leader = _saved["leader"]
		CombatAi.ai_factions = _saved["ai_factions"]
	_saved = {}


func clear_events() -> void:
	events.clear()
	event_state.clear()
	_log.clear()
	dice_requests.clear()


## Starts a fight among `units`. Not conversation runtime; here only so
## every suite builds its fights the same way. Await a frame after it.
func start_fight(units: Array) -> Encounter:
	var typed: Array[Unit] = []
	for unit in units:
		typed.append(unit)
	return CombatManager.start_combat(typed)


## Ends every running fight. Not conversation runtime; here only so every
## suite tears its fights down the same way.
func stop_fights() -> void:
	for encounter in CombatManager.all_encounters():
		if is_instance_valid(encounter) and encounter.is_running:
			encounter.finish(&"")


func _attach() -> void:
	if _attached:
		return
	_attached = true
	Conversations.began.connect(_on_began)
	CombatManager.combat_ended.connect(_on_combat_ended)
	SystemLog.line_logged.connect(_on_log_line)
	SystemLog.log_rebuilt.connect(_on_log_rebuilt)


func _detach() -> void:
	if not _attached:
		return
	_attached = false
	Conversations.began.disconnect(_on_began)
	CombatManager.combat_ended.disconnect(_on_combat_ended)
	SystemLog.line_logged.disconnect(_on_log_line)
	SystemLog.log_rebuilt.disconnect(_on_log_rebuilt)
	_unfollow()


# --- Starting ------------------------------------------------------

## participants is {token: Unit}. "player" and "npc" are the two every
## dialogue has; any other token is a companion who can assist. Goes
## through the same starter the Talk verb uses, so its refusals apply.
func start_dialogue(root: DialogueNode, participants: Dictionary) -> void:
	TalkInteraction.start(root, participants)


func start_negotiation(actor: Unit, demon: Unit) -> void:
	NegotiateInteraction.start(actor, demon)


## Hands a conversation straight to Conversations.begin, past every
## interaction's own guards, so a suite can pin what begin itself refuses
## rather than what a starter happened to check first. Returns whether it
## began.
func begin_bare(root: DialogueNode, participants: Dictionary) -> bool:
	return Conversations.begin(Conversation.new(root, participants))


## The player's own verbs, through the authored interaction options,
## rather than the engine entry points.
func can_talk(actor: Unit, target) -> bool:
	return _talk_option().is_available(actor, target)


func talk(actor: Unit, target: Unit) -> void:
	_talk_option().execute(actor, target)


func can_negotiate(actor: Unit, target) -> bool:
	return _negotiate_option().is_available(actor, target)


func negotiate(actor: Unit, demon: Unit) -> void:
	_negotiate_option().execute(actor, demon)


## Whether a unit carries the talk / negotiate verbs at all.
func offers_talk(unit: Unit) -> bool:
	return _find_option(unit, TalkInteraction) != null


func offers_negotiate(unit: Unit) -> bool:
	return _find_option(unit, NegotiateInteraction) != null


func _talk_option() -> InteractionOption:
	return load("res://data/interactions/talk.tres")


func _negotiate_option() -> InteractionOption:
	return load("res://data/interactions/negotiate.tres")


func _find_option(unit: Unit, kind) -> InteractionOption:
	for option in unit.interactions:
		if is_instance_of(option, kind):
			return option
	return null


# --- Reading state -------------------------------------------------

func dialogue_active() -> bool:
	return _live(&"dialogue") != null


func negotiation_active() -> bool:
	return _live(&"negotiation") != null


## The running conversation if it is presented as `kind`, else null.
func _live(kind: StringName) -> Conversation:
	var c: Conversation = Conversations.current
	return c if c != null and c.presentation == kind else null


func current_node_id() -> String:
	var c: Conversation = Conversations.current
	if c and c.current_node:
		return c.current_node.id
	return ""


## The running conversation's cast; empty once it has ended.
func participants() -> Dictionary:
	var c: Conversation = Conversations.current
	return c.cast if c else {}


## Visible choice texts, in row order, of whichever conversation is live.
## Text is the stable id: authored text is what a player recognises, and
## a rewrite has no reason to change it.
func choices() -> PackedStringArray:
	var out: PackedStringArray = []
	for choice in _live_choices():
		out.append(choice.text)
	return out


func _live_choices() -> Array:
	var c: Conversation = Conversations.current
	return c._visible if c else []


## Whether a choice counts as picked in the current (or just-ended)
## conversation, addressed by node id plus the choice's AUTHORED position
## in the node. That is what the bookkeeping keys on, never the row.
func was_used(node_id: String, authored_index: int, negotiation: bool = false) -> bool:
	var c: Conversation = _latest(negotiation)
	return c != null and c.used_choices.has("%s:%d" % [node_id, authored_index])


func used_count(negotiation: bool = false) -> int:
	var c: Conversation = _latest(negotiation)
	return c.used_choices.size() if c else 0


func _latest(negotiation: bool) -> Conversation:
	return _by_kind.get(&"negotiation" if negotiation else &"dialogue")


## The negotiation's variables, from the latest one to begin.
func mood() -> int:
	return _neg_var("mood", 0)


func pardon_available() -> bool:
	return _neg_var("pardon", 0) > 0


func negotiated_gold() -> int:
	return _neg_var("gold", 0)


func _neg_var(key: String, fallback: int) -> int:
	var c: Conversation = _latest(true)
	return c.vars.get(key, fallback) if c else fallback


## Text as the negotiation shows it, {gold} filled in.
func negotiation_text(raw: String) -> String:
	var c: Conversation = _latest(true)
	return c.format(raw) if c else raw


func current_actor() -> Unit:
	var c: Conversation = _live(&"negotiation")
	return c.cast.get("player") as Unit if c else null


func current_demon() -> Unit:
	var c: Conversation = _live(&"negotiation")
	return c.cast.get("npc") as Unit if c else null


## Rolls one RECRUIT/HEAL success check exactly as an outcome does, at
## `mood_value`, on dice seeded `seed_value` — a conversation of its own,
## so no live one's dice are spent.
func roll_outcome(mood_value: int, seed_value: int) -> bool:
	var probe := Conversation.new()
	probe.vars["mood"] = mood_value
	probe.rng.seed = seed_value
	return NegotiationOutcomeEffect.roll_success(probe)


func mode() -> String:
	return GameMode.Mode.keys()[GameMode.current_mode()]


## The transcript as plain entries {speaker, text}. speaker is the shown
## name for a spoken line and "" for an aside. Read from the latest
## conversation of either kind: a negotiation keeps a transcript now too.
func transcript() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _conversation:
		for entry in _conversation.transcript:
			out.append({"speaker": entry.name if entry.kind == &"line" else "", "text": entry.text})
	return out


func transcript_texts() -> PackedStringArray:
	var out: PackedStringArray = []
	for entry in transcript():
		out.append(entry.text)
	return out


## The text of the newest transcript entry (or the one `skip` entries
## before it), "" if none.
func last_said(skip: int = 0) -> String:
	var texts: PackedStringArray = transcript_texts()
	var i: int = texts.size() - 1 - skip
	return texts[i] if i >= 0 else ""


## The transcript as the log renders it, formatting included. Only the
## format check reads this; everything else reads transcript().
func transcript_raw() -> Array[String]:
	var out: Array[String] = []
	if _conversation:
		for entry in _conversation.transcript:
			out.append(DialogueFormat.log_bbcode(entry))
	return out


## SystemLog lines printed since begin()/clear_events(), BBCode stripped.
func log_lines() -> PackedStringArray:
	return PackedStringArray(_log)


func log_has(fragment: String) -> bool:
	return log_count(fragment) > 0


func log_count(fragment: String) -> int:
	var n: int = 0
	for line in _log:
		if line.contains(fragment):
			n += 1
	return n


static func plain(bbcode: String) -> String:
	var regex := RegEx.new()
	regex.compile("\\[[^\\]]*\\]")
	return regex.sub(bbcode, "", true)


func event_index(prefix: String) -> int:
	for i in events.size():
		if events[i].begins_with(prefix):
			return i
	return -1


func event_count(prefix: String) -> int:
	var n: int = 0
	for e in events:
		if e.begins_with(prefix):
			n += 1
	return n


func state_at(prefix: String) -> Dictionary:
	var i: int = event_index(prefix)
	return event_state[i] if i >= 0 else {}


# --- Acting --------------------------------------------------------

## Picks the visible choice whose text is `text`. Returns false, having
## done nothing, if no visible choice has it.
func choose(text: String) -> bool:
	var live: Array = _live_choices()
	for i in live.size():
		if live[i].text == text:
			await choose_row(i)
			return true
	return false


## Picks by visible ROW, the way a click on a numbered row does.
func choose_row(row: int) -> void:
	var c: Conversation = Conversations.current
	if c == null:
		return
	await _choose_in(c, row)


## Same as choose_row, but aimed at one presentation even when nothing of
## that kind is running, for the "choosing with nothing open does nothing"
## checks.
func choose_row_in(negotiation: bool, row: int) -> void:
	var c: Conversation = _live(&"negotiation" if negotiation else &"dialogue")
	if c == null:
		return
	await _choose_in(c, row)


## A row is turned into the choice's stable id exactly as a presenter
## does it, from the snapshot, so an out-of-range row picks nothing.
func _choose_in(c: Conversation, row: int) -> void:
	var authored: Array = []
	for entry in c.snapshot().choices:
		if not entry.get("builtin", false):
			authored.append(entry)
	if row < 0 or row >= authored.size():
		return
	await c.choose(authored[row].id)


func advance() -> void:
	var c: Conversation = _live(&"dialogue")
	if c:
		c.advance()


func end_dialogue() -> void:
	var c: Conversation = _live(&"dialogue")
	if c:
		c.end()


## Ends a negotiation from outside, by outcome name ("recruit", "flee",
## "attack", "heal", "continue"). "continue" is not an ending and does
## nothing, as before.
func end_negotiation(outcome: String) -> void:
	var c: Conversation = _live(&"negotiation")
	if c == null or outcome == "continue":
		return
	NegotiationOutcomeEffect.conclude(c, _outcome(outcome))


func shift_mood(amount: int) -> void:
	var c: Conversation = _live(&"negotiation")
	if c:
		ShiftMoodEffect.shift(c, amount)


## Sets the running mood directly, for tests that need a known mood.
func set_mood(value: int) -> void:
	var c: Conversation = _latest(true)
	if c:
		c.vars["mood"] = value


func set_negotiated_gold(value: int) -> void:
	var c: Conversation = _latest(true)
	if c:
		c.vars["gold"] = value


## Spends the pardon if one is left, the way a disliked answer does, and
## says whether there was one. Unlike the answer itself, an empty pardon
## here does not end the negotiation: this asks only about the pardon.
func try_pardon() -> bool:
	var c: Conversation = _live(&"negotiation")
	if c == null or c.vars.get("pardon", 0) <= 0:
		return false
	SpendPardonEffect.new().apply(c)
	return true


# --- Randomness ----------------------------------------------------

## See the header. consume(rng) draws from rng exactly as the code under
## test is about to draw from the conversation's dice, and returns whether
## that draw is the one wanted. Seeds the running conversation, or the
## next one to begin when none is running. Returns the seed used, or -1 if
## none of the first 20000 seeds works.
func pin(consume: Callable) -> int:
	for s in range(1, 20001):
		var rng := RandomNumberGenerator.new()
		rng.seed = s
		if consume.call(rng):
			seed_rng(s)
			return s
	return -1


## Pins the dice of the running conversation, or of the next to begin.
func seed_rng(value: int) -> void:
	if Conversations.current:
		Conversations.current.rng.seed = value
	else:
		Conversations.next_seed = value


## The seed still waiting for the next conversation to begin, -1 if none.
func pending_seed() -> int:
	return Conversations.next_seed


## The next RECRUIT/HEAL roll at the CURRENT mood comes out `success`.
func pin_outcome_roll(success: bool) -> int:
	var mood_now: int = mood()
	return pin(func(rng: RandomNumberGenerator) -> bool:
		var probe := Conversation.new()
		probe.vars["mood"] = mood_now
		probe.rng = rng
		return NegotiationOutcomeEffect.roll_success(probe) == success)


## The next skill check against `target` comes out `success`.
func pin_skill_roll(target: int, success: bool) -> int:
	return pin(func(rng: RandomNumberGenerator) -> bool:
		return SuccessRoll.roll_vs(target, rng).success == success)


## The next contest (actor rolls first, then the NPC) comes out with the
## actor winning or not; want_tie asks for equal margins instead.
func pin_contest(actor_target: int, npc_target: int, actor_wins: bool, want_tie: bool = false) -> int:
	return pin(func(rng: RandomNumberGenerator) -> bool:
		var a: Dictionary = SuccessRoll.roll_vs(actor_target, rng)
		var n: Dictionary = SuccessRoll.roll_vs(npc_target, rng)
		if want_tie:
			return a.margin == n.margin
		return (a.margin >= n.margin) == actor_wins)


## The negotiated gold rolled at the next start comes out `amount`.
func pin_negotiated_gold(rank: int, amount: int) -> int:
	return pin(func(rng: RandomNumberGenerator) -> bool:
		return rng.randi_range(rank * 10, rank * 20) == amount)


## The next volatile mood shift in [lo, hi] comes out `amount`.
func pin_volatile(lo: int, hi: int, amount: int) -> int:
	return pin(func(rng: RandomNumberGenerator) -> bool:
		return rng.randi_range(lo, hi) == amount)


## What a skill check would roll against, before assist.
func skill_target(unit: Unit, skill_name: String) -> int:
	return SkillCalculator.get_skill_level(unit, skill_name).skill_level


func can_attempt(unit: Unit, skill_name: String) -> bool:
	return SkillCalculator.get_skill_level(unit, skill_name).can_use_skill


# --- Dice ----------------------------------------------------------

## Stands in for a dice presenter. While held, a check PAUSES at its dice
## until finish_dice(), the way it does in the game with the popup up.
## With nothing attached, a check resolves at once.
func hold_dice() -> void:
	if _holding_dice:
		return
	_holding_dice = true
	if Conversations.current:
		Conversations.current.attach(&"dice", self)


func release_dice() -> void:
	if not _holding_dice:
		return
	_holding_dice = false
	if Conversations.current:
		Conversations.current.detach(&"dice", self)


## Lets a paused check continue, as the popup's Continue button does.
func finish_dice() -> void:
	_dice_open = maxi(_dice_open - 1, 0)
	if Conversations.current:
		Conversations.current.complete()


func dice_waiting() -> bool:
	return _dice_open > 0


## The companion a check would take the assist bonus from, or null.
func assistant_for(skill_name: String) -> Unit:
	var c: Conversation = Conversations.current
	return c.find_assisting_companion(skill_name) if c else null


func assist_bonus() -> int:
	return Conversation.ASSIST_BONUS


# --- Content -------------------------------------------------------
##
## Builders for synthetic trees. A suite says WHAT a node offers; which
## classes carry it is this file's business. Options, all optional:
##   repeatable: bool      stays visible after being picked
##   flag: String          set when picked
##   alignment: String     "Lawful"/"Chaotic"/"Light"/"Dark" tag
##   spoken: String        the player's spoken line when picked
##   effects: Array        from the effect builders below
##   requires: prereq      from the prerequisite builders below

func node(id: String, text: String, choices: Array = [], speaker: String = "npc", next_id: String = "") -> DialogueNode:
	var n := DialogueNode.new()
	n.id = id
	n.text_block = text
	n.speaker = speaker
	n.next_node_id = next_id
	var typed: Array[DialogueChoice] = []
	for c in choices:
		typed.append(c)
	n.choices = typed
	return n


## An interjection: when `into` is reached and `prereq` holds (null means
## always), `interjection` is shown instead, at most once per conversation.
func interject(into: DialogueNode, interjection: DialogueNode, prereq: PrerequisiteRule = null) -> void:
	var option := DialogueRootOption.new()
	option.root = interjection
	option.prerequisite = prereq
	into.interjection_options.append(option)


func line(text: String, next_id: String = "", opts: Dictionary = {}) -> DialogueChoice:
	var c := LineChoice.new()
	c.next_node_id = next_id
	c.returns_to_root = opts.get("to_root", false)
	return _dress(c, text, opts)


func skill_check(text: String, skill: String, success_id: String, failure_id: String, opts: Dictionary = {}) -> DialogueChoice:
	var c := SkillCheckChoice.new()
	c.skill_name = skill
	c.success_node_id = success_id
	c.failure_node_id = failure_id
	return _dress(c, text, opts)


func contest(text: String, skill: String, npc_skill: String, success_id: String, failure_id: String, opts: Dictionary = {}) -> DialogueChoice:
	var c := QuickContestChoice.new()
	c.skill_name = skill
	c.npc_skill_name = npc_skill
	c.success_node_id = success_id
	c.failure_node_id = failure_id
	return _dress(c, text, opts)


## A plain line in a negotiation: the same class as a dialogue line. What
## makes it a negotiation is the effects it carries, never its class.
func neg_line(text: String, next_id: String = "", opts: Dictionary = {}) -> DialogueChoice:
	var c := LineChoice.new()
	c.next_node_id = next_id
	return _dress(c, text, opts)


## outcome: "recruit", "flee", "attack", "heal", or "continue" (unset).
## The ending is an effect appended after the choice's own, as the
## authored trees carry it.
func neg_outcome(text: String, outcome: String, opts: Dictionary = {}) -> DialogueChoice:
	var c := _dress(LineChoice.new(), text, opts)
	var ending := NegotiationOutcomeEffect.new()
	ending.outcome = _outcome(outcome)
	c.effects.append(ending)
	return c


## The answer the demon's personality dislikes: pardoned once.
func disliked(text: String, next_id: String, opts: Dictionary = {}) -> DialogueChoice:
	var c := LineChoice.new()
	c.next_node_id = next_id
	_dress(c, text, opts)
	c.effects.append(SpendPardonEffect.new())
	return c


## The answer the demon's personality hates: always a fight.
func hated(text: String, opts: Dictionary = {}) -> DialogueChoice:
	return neg_outcome(text, "attack", opts)


func _dress(c: DialogueChoice, text: String, opts: Dictionary) -> DialogueChoice:
	c.text = text
	c.is_repeatable = opts.get("repeatable", false)
	c.sets_flag = opts.get("flag", "")
	c.alignment_name = opts.get("alignment", "")
	c.dialogue_line = opts.get("spoken", "")
	c.prerequisites = opts.get("requires", null)
	var effects: Array[DialogueEffect] = []
	for e in opts.get("effects", []):
		effects.append(e)
	c.effects = effects
	return c


func mood_effect(amount: int) -> DialogueEffect:
	var e := ShiftMoodEffect.new()
	e.amount = amount
	return e


func volatile_mood_effect(lo: int, hi: int) -> DialogueEffect:
	var e := VolatileMoodEffect.new()
	e.min_amount = lo
	e.max_amount = hi
	return e


func gold_cost(amount: int) -> DialogueEffect:
	var e := SacrificeGoldEffect.new()
	e.amount = amount
	return e


func hp_cost(amount: int) -> DialogueEffect:
	var e := SacrificeHpEffect.new()
	e.amount = amount
	return e


func fp_cost(amount: int) -> DialogueEffect:
	var e := SacrificeFpEffect.new()
	e.amount = amount
	return e


## Pays whatever gold this negotiation settled on.
func negotiated_gold_cost() -> DialogueEffect:
	return SacrificeNegotiatedGoldEffect.new()


func starts_fight() -> DialogueEffect:
	return TriggerCombatEffect.new()


## An effect that appends `label` to `into` when applied, so a suite can
## see where in a choice's resolution effects run.
func marker_effect(into: Array, label: String) -> DialogueEffect:
	var e := _MarkerEffect.new()
	e.into = into
	e.label = label
	return e


## An effect that ends the running conversation mid-resolution.
func ending_effect() -> DialogueEffect:
	return _EndingEffect.new()


## The cost tags an effect list would show on a choice row, priced in
## the latest negotiation (a blank conversation when there is none).
func cost_tags_of(effects: Array) -> PackedStringArray:
	var c: Conversation = _latest(true)
	return _dress(LineChoice.new(), "", {"effects": effects}).cost_tags(c if c else Conversation.new())


func needs_flag(flag_name: String, absent: bool = false) -> PrerequisiteRule:
	var p := FlagPrerequisite.new()
	p.flag_name = flag_name
	p.requires_absent = absent
	return p


func needs_mood(minimum: int) -> PrerequisiteRule:
	var p := MoodPrerequisite.new()
	p.minimum_mood = minimum
	return p


func needs_negotiated_gold() -> PrerequisiteRule:
	return NegotiatedGoldPrerequisite.new()


func needs_participant(token: String) -> PrerequisiteRule:
	var p := ParticipantPresentPrerequisite.new()
	p.participant_token = token
	return p


## Asked the way a choice's gate asks it: inside the running conversation,
## or, with none running, inside an empty one whose only member is `unit`
## as the player.
func satisfied(prereq: PrerequisiteRule, unit: Unit) -> bool:
	var c: Conversation = Conversations.current
	if c == null:
		c = Conversation.new(null, {"player": unit})
	return prereq.is_satisfied_in(c)


## Makes synthetic nodes reachable by id, so a choice's next id can name
## them: planted in the shared node index for that folder under a path the
## resource cache answers for. finish() undoes it.
func register_dialogue(nodes: Array) -> void:
	var index: DialogueNodeIndex = Conversation.index_for(Conversation.DIALOGUE_DIR)
	for n in nodes:
		index._id_to_path[n.id] = _plant(n, "dlg")
		_dialogue_ids.append(n.id)


## A negotiation node also gets the opening every authored greeting
## carries (NegotiationOpeningEffect), so whichever of them a species opens
## on sets up mood, gold and pardon the way the real trees do. Only a root
## ever runs its start effects, so it is harmless on the rest.
func register_negotiation(nodes: Array) -> void:
	var index: DialogueNodeIndex = Conversation.index_for(NegotiateInteraction.CONVERSATIONS_DIR)
	for n in nodes:
		_give_opening(n)
		index._id_to_path[n.id] = _plant(n, "neg")
		_negotiation_ids.append(n.id)


func _give_opening(n: DialogueNode) -> void:
	for effect in n.start_effects:
		if effect is NegotiationOpeningEffect:
			return
	n.start_effects.append(NegotiationOpeningEffect.new())


func _plant(n: DialogueNode, kind: String) -> String:
	var path: String = "%s/%s_%s.tres" % [SYNTHETIC_DIR, kind, n.id]
	n.take_over_path(path)
	_synthetic.append(n)
	return path


func _unregister_all() -> void:
	var dialogue: DialogueNodeIndex = Conversation.index_for(Conversation.DIALOGUE_DIR)
	var negotiation: DialogueNodeIndex = Conversation.index_for(NegotiateInteraction.CONVERSATIONS_DIR)
	for id in _dialogue_ids:
		dialogue._id_to_path.erase(id)
	for id in _negotiation_ids:
		negotiation._id_to_path.erase(id)
	_dialogue_ids.clear()
	_negotiation_ids.clear()
	_synthetic.clear()


## What the authoring pass (Conversations.lint) finds in the dialogue or
## negotiation folder, synthetic nodes included. strict is the rule a
## negotiation folder is linted under: every branch ends through an ending
## effect.
func authoring_problems(negotiation: bool, strict: bool) -> PackedStringArray:
	var dir: String = NegotiateInteraction.CONVERSATIONS_DIR if negotiation else Conversation.DIALOGUE_DIR
	return Conversations.problems_in(dir, strict)


## Whether an id resolves in the dialogue / negotiation node namespace.
func dialogue_knows(id: String) -> bool:
	return Conversation.index_for(Conversation.DIALOGUE_DIR).has_id(id)


func negotiation_knows(id: String) -> bool:
	return Conversation.index_for(NegotiateInteraction.CONVERSATIONS_DIR).has_id(id)


## Gives a unit something to say: `root` becomes its only dialogue entry.
func give_dialogue(unit: Unit, root: DialogueNode, prereq: PrerequisiteRule = null) -> void:
	var option := DialogueRootOption.new()
	option.root = root
	option.prerequisite = prereq
	var options: Array[DialogueRootOption] = [option]
	unit.dialogue_options = options


## Gives a unit several dialogue entries, tried in order, each
## [root, prereq-or-null]: the shape of an NPC with a first meeting and a
## later one, where which entry opens depends on the conversation.
func give_dialogues(unit: Unit, pairs: Array) -> void:
	var options: Array[DialogueRootOption] = []
	for pair in pairs:
		var option := DialogueRootOption.new()
		option.root = pair[0]
		option.prerequisite = pair[1]
		options.append(option)
	unit.dialogue_options = options


func silence(unit: Unit) -> void:
	var none: Array[DialogueRootOption] = []
	unit.dialogue_options = none


## A copy of a species whose negotiation opens on `roots`, tried in order,
## each [node, prereq-or-null]. A copy, never the shared cached species:
## mutating that would leak into every later suite and the game's own
## data for the rest of the run. Each root gets the opening an authored
## greeting carries (see register_negotiation).
func species_with_roots(species_id: String, roots: Array) -> UnitDefinition:
	var def: UnitDefinition = load("res://data/units/demons/%s.tres" % species_id).duplicate()
	var options: Array[DialogueRootOption] = []
	for pair in roots:
		var option := DialogueRootOption.new()
		option.root = pair[0]
		option.prerequisite = pair[1]
		if option.root:
			_give_opening(option.root)
		options.append(option)
	def.negotiation_options = options
	return def


func species(species_id: String) -> UnitDefinition:
	return load("res://data/units/demons/%s.tres" % species_id)


## The id of the node a species' negotiation would open on for `actor`.
func species_root_id(def: UnitDefinition, actor: Unit) -> String:
	var root: DialogueNode = def.resolve_negotiation_root(Conversation.new(null, {"player": actor}))
	return root.id if root else ""


## Spawns a unit of `def` into a suite's battlefield and registers it for
## the suite's own cleanup. Definition before add_child, as always.
func spawn_species(case: AiTestCase, def: UnitDefinition, position: Vector3) -> Unit:
	var unit: Unit = def.unit_scene.instantiate()
	unit.definition = def
	case._spawn_parent().add_child(unit)
	unit.faction = &"enemy"
	unit.global_position = position
	unit.reset_turn_actions()
	case._spawned.append(unit)
	return unit


## One authored negotiation node, in engine-neutral terms:
## {id, text, choices: [{kind, text, next, outcome, mood, mood_range,
## pays_negotiated_gold, gated_by_negotiated_gold, extras}]}. extras is
## true when a choice authors a flag, alignment, spoken line or
## repeatable, none of which negotiation content uses. kind is "line",
## "outcome", "disliked" or "other" — read from the effects a choice
## carries, since every negotiation choice is now the same LineChoice. A
## hated answer is an ATTACK outcome, so it reads as "outcome"/"attack".
func negotiation_node(id: String) -> Dictionary:
	var n: DialogueNode = Conversation.index_for(NegotiateInteraction.CONVERSATIONS_DIR).find_node(id)
	if n == null:
		return {}
	var out: Array[Dictionary] = []
	for c in n.choices:
		var d: Dictionary = {"text": c.text, "next": "", "outcome": "", "mood": 0,
			"mood_range": [], "pays_negotiated_gold": false,
			"gated_by_negotiated_gold": c.prerequisites is NegotiatedGoldPrerequisite}
		var ending: NegotiationOutcomeEffect = null
		var pardoned: bool = false
		for e in c.effects:
			if e is ShiftMoodEffect:
				d.mood += e.amount
			elif e is VolatileMoodEffect:
				d.mood_range = [e.min_amount, e.max_amount]
			elif e is SacrificeNegotiatedGoldEffect:
				d.pays_negotiated_gold = true
			elif e is NegotiationOutcomeEffect:
				ending = e
			elif e is SpendPardonEffect:
				pardoned = true
		if not c is LineChoice:
			d.kind = "other"
		elif ending != null:
			d.kind = "outcome"
			d.outcome = _outcome_name(ending.outcome)
		elif pardoned:
			d.kind = "disliked"
			d.next = c.next_node_id
		else:
			d.kind = "line"
			d.next = c.next_node_id
		d.extras = c.sets_flag != "" or c.alignment_name != "" or c.dialogue_line != "" or c.is_repeatable
		out.append(d)
	return {"id": n.id, "text": n.text_block, "choices": out}


## Every species definition under data/units/demons, by file id.
func all_species_ids() -> PackedStringArray:
	var ids: PackedStringArray = []
	for f in DirAccess.get_files_at("res://data/units/demons"):
		if f.ends_with(".tres"):
			ids.append(f.get_basename())
	return ids


## A species' authored negotiation roots: [{root_id, conditioned}].
func species_root_options(def: UnitDefinition) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for option in def.negotiation_options:
		out.append({"root_id": option.root.id if option.root else "", "conditioned": option.prerequisite != null})
	return out


func _outcome(name: String) -> NegotiationOutcomeEffect.Outcome:
	match name:
		"recruit": return NegotiationOutcomeEffect.Outcome.RECRUIT
		"flee": return NegotiationOutcomeEffect.Outcome.FLEE
		"attack": return NegotiationOutcomeEffect.Outcome.ATTACK
		"heal": return NegotiationOutcomeEffect.Outcome.HEAL
	return NegotiationOutcomeEffect.Outcome.UNSET


static func _outcome_name(outcome: int) -> String:
	match outcome:
		NegotiationOutcomeEffect.Outcome.RECRUIT: return "recruit"
		NegotiationOutcomeEffect.Outcome.FLEE: return "flee"
		NegotiationOutcomeEffect.Outcome.ATTACK: return "attack"
		NegotiationOutcomeEffect.Outcome.HEAL: return "heal"
	return "continue"


# --- Presenters ----------------------------------------------------
##
## The screens a player sees. Suites instance them through here and read
## them through view dictionaries, so a presenter rebuilt on the new
## engine only has to keep answering the same questions.

func make_overlay(parent: Node) -> UIScreen:
	var overlay: UIScreen = load(OVERLAY_SCENE).instantiate()
	parent.add_child(overlay)
	return overlay


func make_log(parent: Node) -> UIScreen:
	var log_screen: UIScreen = load(LOG_SCENE).instantiate()
	parent.add_child(log_screen)
	return log_screen


func make_dice_popup(parent: Node) -> Control:
	var popup: Control = load(DICE_SCENE).instantiate()
	parent.add_child(popup)
	return popup


func make_panel(parent: Node) -> UIScreen:
	var panel: UIScreen = load(PANEL_SCENE).instantiate()
	parent.add_child(panel)
	return panel


## {visible, aside, speaker, speaker_color, line, rows: [{index, text, tags,
## focused, disabled, visible}], continue_visible, continue_text,
## continue_disabled, continue_focused}.
func overlay_view(overlay: UIScreen) -> Dictionary:
	var rows: Array[Dictionary] = []
	for row in overlay._choice_rows:
		if is_instance_valid(row) and not row.is_queued_for_deletion():
			rows.append({"index": row._index_label.text, "text": row._text_label.text,
				"tags": plain(row._tags_label.text), "focused": row.has_focus(),
				"disabled": row.disabled, "visible": row.is_visible_in_tree()})
	var speaker: Label = overlay._speaker_name_label
	return {
		"visible": overlay.is_visible_in_tree(),
		"aside": overlay._aside_label.text,
		"speaker": speaker.text,
		"speaker_color": speaker.get_theme_color("font_color"),
		"line": overlay._line_label.text,
		"rows": rows,
		"continue_visible": overlay._continue_button.is_visible_in_tree(),
		"continue_text": overlay._continue_button.text,
		"continue_disabled": overlay._continue_button.disabled,
		"continue_focused": overlay._continue_button.has_focus(),
	}


## A real left click on a visible row, through the row's own input path.
func overlay_click_row(overlay: UIScreen, row: int) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	overlay._choice_rows[row]._on_gui_input(event)


func overlay_press_continue(overlay: UIScreen) -> void:
	overlay._continue_button.pressed.emit()


func overlay_press_log(overlay: UIScreen) -> void:
	overlay._log_chip.pressed.emit()


## {visible, label, button_visible, button_text}.
func dice_view(popup: Control) -> Dictionary:
	return {
		"visible": popup.is_visible_in_tree(),
		"label": popup._result_label.text,
		"button_visible": popup._continue_button.visible,
		"button_text": popup._continue_button.text,
	}


func dice_press(popup: Control) -> void:
	popup._continue_button.pressed.emit()


## Whether a presenter is listening for the next conversation to begin.
## A presenter out of the tree must not be: it would attach to a
## conversation it can never show.
func hears_began(presenter: Node) -> bool:
	for connection in Conversations.began.get_connections():
		if connection.callable.get_object() == presenter:
			return true
	return false


## {visible, header, line, choices, mood_color}. The header is plain
## text; line and choices are as authored for the label, BBCode included,
## because the mood note's styling and the [url] rows are what is pinned.
func panel_view(panel: UIScreen) -> Dictionary:
	return {
		"visible": panel.is_visible_in_tree(),
		"header": plain(panel._demon_label.text),
		"line": panel._line_text.text,
		"choices": panel._choices_text.text,
		"mood_color": panel._mood_indicator.color,
	}


## A click on the row-th choice link, as RichTextLabel reports it.
func panel_click(panel: UIScreen, row: int) -> void:
	panel._choices_text.meta_clicked.emit(str(row))


## A screen's UIStack flags as MainRoot.tscn authors them (instance
## overrides, with the UIScreen defaults otherwise): {found, hides_hud,
## blocks_input_below, keeps_party_visible, closes_on_cancel}.
func authored_screen_flags(node_name: String) -> Dictionary:
	var state: SceneState = load("res://MainRoot.tscn").get_state()
	var flags: Dictionary = {"hides_hud": false, "blocks_input_below": false,
		"keeps_party_visible": false, "closes_on_cancel": true, "found": false}
	for i in state.get_node_count():
		if state.get_node_name(i) != node_name:
			continue
		flags.found = true
		for p in state.get_node_property_count(i):
			var prop: String = state.get_node_property_name(i, p)
			if flags.has(prop):
				flags[prop] = state.get_node_property_value(i, p)
	return flags


## The music the game asked for, observed through MusicManager's
## once-per-name missing-music report. The fixture area has no entry in
## the music table, so every request it makes lands there.
func forget_music_requests() -> void:
	MusicManager._reported_missing.clear()


func music_was_requested(moment: String) -> bool:
	var area: AreaDefinition = WorldManager.current_area()
	if area == null:
		return false
	return MusicManager._reported_missing.has(MusicManager.music_area(area.id, StringName(moment)))


# --- Recorders -----------------------------------------------------

func _record(entry: String) -> void:
	events.append(entry)
	event_state.append({
		"dialogue_active": dialogue_active(),
		"negotiation_active": negotiation_active(),
		"mode": mode(),
	})


func _on_began(c: Conversation) -> void:
	_unfollow()
	_conversation = c
	_by_kind[c.presentation] = c
	_seen = 0
	_shown_visit = -1
	_ended_reported = false
	_dice_serial = -1
	c.changed.connect(_on_changed)
	if _holding_dice:
		c.attach(&"dice", self)
	if c.presentation == &"negotiation":
		var demon: Unit = c.cast.get("npc") as Unit
		_record("negotiation_started:%s" % (demon.get_display_name() if is_instance_valid(demon) else ""))
	else:
		_record("dialogue_started:%s" % (c._root.id if c._root else ""))


func _unfollow() -> void:
	if _conversation and _conversation.changed.is_connected(_on_changed):
		_conversation.changed.disconnect(_on_changed)


## Re-derives the old per-manager events from one change: new transcript
## entries first (a dialogue's lines and asides, a negotiation's mood
## notes), then a newly shown node, then the end — the order the old
## signals arrived in.
func _on_changed() -> void:
	var c: Conversation = _conversation
	if c == null:
		return
	var negotiation: bool = c.presentation == &"negotiation"
	while _seen < c.transcript.size():
		var entry: Dictionary = c.transcript[_seen]
		_seen += 1
		if negotiation:
			if entry.get("tag") == &"mood":
				_record("mood_note:%s" % entry.text)
		else:
			_record("line:%s:%s" % [entry.speaker, plain(entry.text)])

	if c.ended:
		if not _ended_reported:
			_ended_reported = true
			_unfollow()
			if negotiation:
				_record("negotiation_ended:%s" % _ending_label(c.outcome))
			else:
				_record("dialogue_ended")
		return

	if c.visit != _shown_visit and c.current_node:
		_shown_visit = c.visit
		if negotiation:
			_record("neg_line:%s" % c.current_node.text_block)
			_record("neg_choices:%d" % c._visible.size())
		else:
			_record("choices:%d" % c._visible.size())

	if _holding_dice and c.waiting.get("kind") == &"dice" and c.waiting.serial != _dice_serial:
		_dice_serial = c.waiting.serial
		_dice_open += 1
		dice_requests.append({"skill": c.waiting.data.skill, "roll": c.waiting.data.roll})


static func _ending_label(outcome: StringName) -> String:
	return "CONTINUE" if outcome == &"" else String(outcome).to_upper()


func _on_combat_ended(_winner: StringName) -> void:
	_record("combat_ended")


func _on_log_line(line_bb: String) -> void:
	_log.append(plain(line_bb))


func _on_log_rebuilt() -> void:
	if not SystemLog.lines.is_empty():
		_log.append(plain(SystemLog.lines.back()))


## Test-only effect: appends "<label>@<transcript size>" when applied, so
## a suite can see where among the recorded lines it ran.
class _MarkerEffect extends DialogueEffect:
	var into: Array
	var label: String

	func apply(c: Conversation) -> void:
		into.append("%s@%d" % [label, c.transcript.size()])


## Test-only effect: ends the conversation it runs in, from inside a
## choice's resolution — a negotiation the way its own ending does.
class _EndingEffect extends DialogueEffect:
	func apply(c: Conversation) -> void:
		if c.presentation == &"negotiation":
			NegotiationOutcomeEffect.conclude(c, NegotiationOutcomeEffect.Outcome.FLEE)
		else:
			c.end()
