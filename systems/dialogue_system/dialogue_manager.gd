extends Node
## Autoload singleton. Register as "DialogueManager" under
## Project > Project Settings > AutoLoad.
##
## Orchestrates one conversation at a time: which DialogueNode is
## current, who the participant tokens (see DialogueNode.speaker) resolve
## to, the running transcript (for the conversation log), and moving
## between nodes. Deliberately dumb about PRESENTATION — dialogue_overlay.gd
## and dialogue_camera_rig.gd both just listen to this autoload's signals
## and react; this file never touches a Control or a Camera3D.
##
## Node lookup is indexed once, at _ready(), NOT rescanned per node
## transition. The old GURPS-project DialogueManager walked
## res://data/dialogue with DirAccess on every single node change; this
## is the exact same fix already applied once for SkillDatabase, applied
## again here. Indexing also runs a debug-build validation pass over
## every hand-typed node-id reference — see _validate_node_references().

signal dialogue_started(root: DialogueNode)
## Fired for EVERY line shown — a node's own text_block, and the smaller
## echo lines a DialogueChoice.resolve() produces (alignment message,
## echoed response, skill check result) — so the overlay (display) and
## dialogue_camera_rig (who to frame) both react to one single event
## instead of needing two different ways to find out what was said.
## speaker_token is "" for the small echo lines (see record_line) — no
## camera re-cut for those, a deliberate simplification: only a node's
## own text_block currently drives a shot change.
signal line_shown(text: String, speaker_token: String)
signal choices_shown(choices: Array[DialogueChoice])
signal dialogue_ended()
## Fired by SkillCheckChoice/QuickContestChoice once a roll is fully
## decided (roll is SuccessRoll.roll_vs()'s own Dictionary) — the
## presentation layer (skill_check_dice_popup.gd) plays the dice
## tumbling to that ALREADY-FINAL result, then emits
## dice_roll_finished back. The choice's own resolution awaits that
## signal before revealing the result line, so the log text can never
## appear before the dice do. DialogueManager only ever emits/awaits
## its own signals here — never reaches into the popup directly, same
## presentation split as everywhere else in this file.
signal dice_roll_requested(skill_name: String, roll: Dictionary)
signal dice_roll_finished()

const DIALOGUE_DATA_PATH: String = "res://data/dialogue"
## Flat bonus a qualifying present companion grants the acting unit's
## side of a skill check — see find_assisting_companion(). BG3-Help-
## simplified: GURPS' own Cooperative Skill Use (B347) stacks multiple
## helpers up to +4 and requires skill 15+ or beating the worker's own
## level; nothing here needs that scope yet, just "one ally who can
## also do this makes it a little easier."
const ASSIST_BONUS: int = 1

var current_node: DialogueNode = null
var participants: Dictionary = {}  # String token ("player"/"npc") -> Unit
var used_choices: Dictionary = {}  # "node_id:index" -> true
var transcript: Array[String] = []

## The exact filtered list _show_node() last emitted via choices_shown —
## choose() indexes into THIS, not current_node.choices. They're
## different index spaces the instant any earlier choice is hidden
## (used, or prerequisites-gated): the overlay renders buttons numbered
## by POSITION IN THE FILTERED LIST, but choose() used to index straight
## into the full, unfiltered array. The two only ever agreed by
## coincidence, on a node's first-ever visit before anything was hidden
## — confirmed via a real trace (2026-08-17): on a hub revisit with
## earlier choices already used, clicking the one visible "goodbye"
## choice silently re-triggered the FIRST full-array choice instead.
## Hub-and-spoke is the only structure in this project that revisits a
## node with a partially-used choice list, which is exactly why this
## went unnoticed until now — test_npc's tree is strictly linear and
## never re-shows a node after hiding one of its choices.
var _visible_choices: Array[DialogueChoice] = []

## Interjection root DialogueNode.id -> true, once shown — see
## _resolve_interjection(). Without this, an interjection whose
## next_node_id routes back to the very node it preempted would refire
## every single time that node is re-approached (a presence-gated
## interjection has no natural way to "expire" on its own — the
## companion doesn't stop being present just because they already
## reacted once), which on a hub the player can cycle back through
## would show the same reaction forever instead of once.
var _used_interjections: Dictionary = {}

## DialogueNode.id -> true, once its text_block has been narrated this
## conversation — see _show_node(). Without this, looping back to a
## hub node (any topic that routes back to it) replayed the NPC's full
## opening line every single time, which no comparable game actually
## does — a hub you've already heard greet you once shouldn't greet you
## again in the same sitting, just re-offer the choice list. Cleared in
## start_dialogue() alongside used_choices/_used_interjections: a FRESH
## conversation should still open with a real greeting, this is only
## about not repeating it within one.
var _narrated_node_ids: Dictionary = {}

var _index := DialogueNodeIndex.new("DialogueManager")
## Guards _validate_node_references() specifically — separate from
## _index's own internal "indexed once" tracking, since _ensure_indexed()
## below is called on every node lookup but validation must still only
## ever run the first time.
var _validated: bool = false


## Forces indexing (and its debug-build reference validation) at boot
## rather than waiting for the first real dialogue lookup — otherwise a
## broken cross-reference would stay silent for an entire playthrough
## that never happens to reach that specific branch.
func _ready() -> void:
	_ensure_indexed()


func is_active() -> bool:
	return current_node != null


## Which DialogueNode.id npc's dialogue_options currently resolves to
## for actor — see Unit.resolve_dialogue_root(). Used by
## LineChoice.returns_to_root (an in-conversation "return to hub" that
## needs to land on whichever phase is current, not a hardcoded ID) and
## by talk_interaction.gd's own initial Talk click — the same
## resolution, just triggered from two different places, so neither can
## ever disagree about which conversation phase is current. "" if
## nothing currently applies — the same sentinel next_node_id already
## uses for "end the conversation" (see _load_node_by_id), so an NPC
## who's run out of anything to say ends things cleanly instead of
## erroring on a lookup for a null id.
func resolve_root_id(npc: Unit, actor: Unit) -> String:
	var root: DialogueNode = npc.resolve_dialogue_root(actor)
	return root.id if root else ""


## Present companion (or null) who can use skill_name — the "assist"
## half of a skill check, checked by SkillCheckChoice/QuickContestChoice
## and previewed by DialogueFormat. "player"/"npc" tokens are excluded;
## those are the actor and the one being talked to, not an ally
## offering to help. First qualifying companion wins — ASSIST_BONUS
## doesn't stack across multiple present companions (see that constant).
func find_assisting_companion(skill_name: String) -> Unit:
	for token in participants:
		if token == "player" or token == "npc":
			continue
		var companion: Unit = participants[token]
		if SkillCalculator.get_skill_level(companion, skill_name).can_use_skill:
			return companion
	return null


## participants maps DialogueNode.speaker tokens to actual Units for
## THIS conversation — {"player": actor, "npc": target} for the common
## 1-on-1 case (see talk_interaction.gd), more tokens for a future group
## scene. Blocked during combat — a full-screen conversation has no
## defined interaction with the turn/initiative state machine yet, and
## nothing about talking to an ally requires it to work mid-fight.
func start_dialogue(root: DialogueNode, conversation_participants: Dictionary) -> void:
	if not root or StashManager.is_active():
		return

	# THE SPEAKER, not the world. Asked as CombatManager.in_combat, a
	# battle anywhere silenced everyone everywhere — so a group standing
	# in a quiet area could not talk to anybody while another group was
	# fighting two areas away. The reason to refuse is that a full-screen
	# conversation has no defined interaction with a turn/initiative state
	# machine, and that reason is about the people in the conversation.
	for participant in conversation_participants.values():
		if participant is Unit and (participant as Unit).in_combat():
			return

	transcript.clear()
	used_choices.clear()
	_used_interjections.clear()
	_narrated_node_ids.clear()
	participants = conversation_participants
	# No mode to push: GameMode reads current_node through is_active(), and
	# _show_node() below is what sets it. The mode therefore turns DIALOGUE
	# one line after dialogue_started rather than one line before it —
	# checked, and no listener of that signal reads the mode.
	dialogue_started.emit(root)
	_show_node(_resolve_interjection(root))


## Async since DialogueChoice.resolve() is — a skill-check-backed
## choice awaits DialogueManager's own dice_roll_finished signal
## before its result is known (see dice_roll_requested above). A
## caller that doesn't await this (dialogue_overlay.gd's click handler
## doesn't need to) just lets it run as a detached coroutine; every
## state change it makes still lands via the usual signals whenever it
## actually finishes.
## Shows the dice for an already-decided roll and waits for the
## presentation to finish. Returns immediately when nothing is listening.
##
## THE GUARD IS THE POINT. The dice popup is the only listener for
## dice_roll_requested AND the only emitter of dice_roll_finished, so with
## no popup in the tree — a test scene, a stripped export, a frame before
## it is ready — an unguarded `await dice_roll_finished` never returns and
## the conversation hangs forever with no timeout. Both callers used to
## emit and await directly, which is exactly that hazard; this is the one
## place that knows the pair can be unattended.
##
## The roll is already final before this is called. Nothing here decides
## anything; the dice only ever play back a result.
func present_dice_roll(skill_name: String, roll: Dictionary) -> void:
	if dice_roll_requested.get_connections().is_empty():
		return
	dice_roll_requested.emit(skill_name, roll)
	await dice_roll_finished


func choose(index: int) -> void:
	if not current_node or index < 0 or index >= _visible_choices.size():
		return

	# index is a position in the FILTERED list the overlay actually
	# rendered — find() recovers the choice's stable position in the
	# full node.choices array, which is what used_choices' key format
	# (and any future revisit of this same node) depends on.
	var choice: DialogueChoice = _visible_choices[index]
	var full_index: int = current_node.choices.find(choice)
	var key: String = "%s:%d" % [current_node.id, full_index]
	used_choices[key] = true

	var next_id: String = await choice.resolve(participants.get("player"), participants.get("npc"))
	_load_node_by_id(next_id)


## Only meaningful when current_node.choices is empty (see
## DialogueNode.next_node_id) — the "Continue" affordance rather than a
## real branch.
func advance() -> void:
	if not current_node or not current_node.choices.is_empty():
		return
	if current_node.next_node_id == "":
		end_dialogue()
		return
	_load_node_by_id(current_node.next_node_id)


func end_dialogue() -> void:
	current_node = null
	participants = {}
	_visible_choices = []
	dialogue_ended.emit()


## Appends one line to the running transcript (conversation_log.gd reads
## this directly) and tells whatever's listening to show it as the
## current line right now. The single path every line goes through,
## called both by _show_node (a node's own text) and by
## DialogueChoice.resolve/SkillCheckChoice (the smaller echo lines).
##
## The transcript entry and the emitted signal carry the speaker
## DIFFERENTLY on purpose: line_shown keeps passing the bare text plus
## the raw token, since dialogue_overlay.gd builds its own copy of the
## "who said this" string via DialogueFormat.speaker_line (same helper,
## called separately, so the current line and the transcript entry are
## never required to be the literal same string in memory). What
## actually gets stored in transcript is already fully formatted — a
## real speaker_token becomes DialogueFormat.speaker_line's bold-name-
## then-text, an empty one (the alignment message / skill check result
## echoes — narration about what just happened, not something a
## character says) becomes a dimmed italic aside instead, matching the
## old GURPS-project DialogueBox's own system-message styling.
func record_line(text: String, speaker_token: String = "") -> void:
	if speaker_token != "":
		var unit: Unit = participants.get(speaker_token)
		var speaker_name: String = unit.get_display_name() if unit else speaker_token.capitalize()
		transcript.append(DialogueFormat.speaker_line(speaker_name, text))
	else:
		transcript.append("[color=#A0A0A0][i]%s[/i][/color]" % text)

	line_shown.emit(text, speaker_token)


func _show_node(node: DialogueNode) -> void:
	current_node = node
	if not _narrated_node_ids.has(node.id):
		_narrated_node_ids[node.id] = true
		record_line(node.text_block, node.speaker)

	var visible_choices: Array[DialogueChoice] = []
	for i in node.choices.size():
		var choice: DialogueChoice = node.choices[i]
		var key: String = "%s:%d" % [node.id, i]
		if used_choices.has(key) and not choice.is_repeatable:
			continue
		if choice.prerequisites and not choice.prerequisites.is_satisfied(participants.get("player")):
			continue
		visible_choices.append(choice)
	_visible_choices = visible_choices
	choices_shown.emit(visible_choices)


func _load_node_by_id(id: String) -> void:
	if id == "":
		end_dialogue()
		return

	var node: DialogueNode = _find_node(id)
	if not node:
		push_error("DialogueManager: no node found for id '%s'" % id)
		end_dialogue()
		return

	_show_node(_resolve_interjection(node))


## First node.interjection_options entry whose prerequisite is
## satisfied (or has none) AND hasn't already fired this conversation,
## returned INSTEAD of node — node itself if nothing qualifies, the
## common case. Runs once per navigation, on whatever node is ABOUT to
## be shown next; the interjection node's own next_node_id (authored to
## point back at node.id) is what actually lands the conversation back
## here afterward, not any special-casing in here.
func _resolve_interjection(node: DialogueNode) -> DialogueNode:
	for option in node.interjection_options:
		if _used_interjections.has(option.root.id):
			continue
		if not option.prerequisite or option.prerequisite.is_satisfied(participants.get("player")):
			_used_interjections[option.root.id] = true
			return option.root
	return node


func _find_node(id: String) -> DialogueNode:
	_ensure_indexed()
	return _index.find_node(id)


func _ensure_indexed() -> void:
	_index.ensure_indexed(DIALOGUE_DATA_PATH)
	if OS.is_debug_build() and not _validated:
		_validated = true
		_validate_node_references()


## Debug-build-only sanity pass over every hand-typed node-id reference
## (next_node_id, success/failure_node_id) — these are plain strings
## with zero compile-time checking, previously only caught by manually
## grepping a freshly-authored tree before trusting it. Runs once,
## right after indexing (which _ready() now forces eagerly rather than
## waiting for the first real lookup), so a typo surfaces at boot even
## on a playthrough that never actually reaches the broken branch —
## cheap, since load() below just returns each already-indexed resource
## from cache, not a second disk read.
func _validate_node_references() -> void:
	for id in _index.all_ids():
		var node: DialogueNode = _index.find_node(id)
		_check_reference(id, "DialogueNode.next_node_id", node.next_node_id)
		for choice in node.choices:
			_check_choice_references(id, choice)


func _check_choice_references(from_id: String, choice: DialogueChoice) -> void:
	if choice is LineChoice:
		# next_node_id is meaningless (and often deliberately empty) when
		# returns_to_root routes through resolve_dialogue_root() instead.
		if not choice.returns_to_root:
			_check_reference(from_id, "LineChoice.next_node_id", choice.next_node_id)
	elif choice is SkillCheckChoice:
		_check_reference(from_id, "SkillCheckChoice.success_node_id", choice.success_node_id)
		_check_reference(from_id, "SkillCheckChoice.failure_node_id", choice.failure_node_id)
	elif choice is QuickContestChoice:
		_check_reference(from_id, "QuickContestChoice.success_node_id", choice.success_node_id)
		_check_reference(from_id, "QuickContestChoice.failure_node_id", choice.failure_node_id)


## "" is always a valid, meaningful value here (it means "end the
## conversation" — see _load_node_by_id), never a mistake, so only a
## non-empty target that doesn't resolve gets flagged.
func _check_reference(from_id: String, field_name: String, target_id: String) -> void:
	if target_id != "" and not _index.has_id(target_id):
		push_warning("DialogueManager: %s on node '%s' references unknown node id '%s'." % [field_name, from_id, target_id])
