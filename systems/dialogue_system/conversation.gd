class_name Conversation
extends RefCounted
## One conversation: its state, its variables, its dice, and the three
## commands that move it (choose, advance, complete).
##
## WHY AN OBJECT, NOT A GLOBAL. Two autoloads used to each hold one
## conversation (DialogueManager and NegotiationManager), with every choice,
## effect, prerequisite and presenter reaching into whichever one it assumed
## was running. That made a second kind of conversation a second global, and
## made "which manager is active" a pairwise question every starter had to
## ask about every other. Here content is handed the conversation it runs
## in, so nothing names a global, and "is a conversation running" is one
## question Conversations.current answers.
##
## PULL, NOT PUSH. There is exactly one signal, `changed`. Presenters redraw
## from snapshot() and read new transcript entries whenever it fires, so a
## presenter that attaches late, one swapped mid-conversation, and a test
## with no presenter at all are the same case.
##
## THE ENGINE NEVER KNOWS WHAT KIND OF CONVERSATION IT IS. Negotiation is
## content: mood, the pardon and the gold amount are `vars`, set by a root's
## start_effects and read by prerequisites and effects. `presentation` is a
## hint for presenters and GameMode, never read in here. The one policy
## difference between trees, what happens at a dead end, is a plain field a
## start effect sets. Every kind narrates its nodes into the same transcript,
## and where else an entry goes (the combat log, for a negotiation) is an
## observer's business, not this file's.

## The one signal. Fired after every state change a presenter could show:
## a node shown, a transcript entry added, a wait started or finished, the
## end.
signal changed

## Plumbing for show()'s await, not an event for presenters: they learn a
## wait finished from `changed` like everything else.
signal _wait_completed

## Flat bonus a qualifying present companion grants the acting unit's side
## of a skill check — see find_assisting_companion(). BG3-Help-simplified:
## GURPS' own Cooperative Skill Use (B347) stacks helpers up to +4; nothing
## here needs that scope, just "one ally who can also do this makes it a
## little easier."
const ASSIST_BONUS: int = 1

const DIALOGUE_DIR: String = "res://data/dialogue"

## Speaker token ("player", "npc", a companion's name) -> Unit. What a
## DialogueNode.speaker resolves through, and what effects and
## prerequisites read their actor from.
var cast: Dictionary = {}
## This conversation's variables — mood, pardon, gold, anything content
## wants. They die with the conversation, so nothing leaks between
## encounters. Any key can be used as a {token} in authored text.
var vars: Dictionary = {}
## Structured entries, oldest first. No BBCode: presenters style them (see
## DialogueFormat.entry_bbcode). Every entry has speaker (token, "" for an
## aside), name, kind (&"line" or &"aside"), text and node (the id of the
## node being shown when it was recorded); extras such as tag add styling
## hints, and narration is true on a node's own text, so an observer that
## already shows the node (the negotiation panel) can skip it.
var transcript: Array[Dictionary] = []
## This conversation's own dice. Randomly seeded in play; a test pins it
## (see Conversations.next_seed) so both sides of a roll can be reached on
## purpose.
var rng := RandomNumberGenerator.new()

## Presenter hint: &"dialogue" or &"negotiation". Read by presenters to
## decide who shows this conversation and by GameMode to name the mode —
## never read by anything in this file.
var presentation: StringName = &"dialogue"
## Where this tree's node ids resolve. Dialogue and negotiation trees keep
## separate id namespaces, as they always have.
var node_dir: String = DIALOGUE_DIR
## Applied instead of offering "Continue"/"End Conversation" when a node has
## nothing left to choose, when a choice routes to an empty or unknown id,
## or when the acting unit dies mid-choice. Null means the ordinary dialogue
## rules. A negotiation start effect sets it, because every negotiation must
## end with an outcome.
var dead_end_effect: DialogueEffect = null

var current_node: DialogueNode = null
## Counts every node shown, including a revisit of the same node, so a
## presenter can tell "a new beat" from "more happened on this one".
var visit: int = 0
var ended: bool = false
var outcome: StringName = &""
## "node_id:full_index" -> true. A choice's id is this same key, so it is
## stable across revisits and filtering — see choose().
var used_choices: Dictionary = {}

## What content asked to have shown before moving on, or {} — see show().
var waiting: Dictionary = {}

var _root: DialogueNode
var _visible: Array[DialogueChoice] = []
## Interjection root id -> true once shown, so a presence-gated reaction
## fires once, not every time its node is re-approached.
var _used_interjections: Dictionary = {}
## Node id -> true once its text has been narrated, so looping back to a hub
## re-offers the choices without replaying the greeting.
var _narrated: Dictionary = {}
## True while a choice is resolving, so a second pick during the dice is
## refused rather than resolved on top of the first.
var _resolving: bool = false
## kind -> Array of presenter instance ids — see attach().
var _presenters: Dictionary = {}
var _wait_serial: int = 0

static var _indexes: Dictionary = {}


func _init(root: DialogueNode = null, conversation_cast: Dictionary = {}) -> void:
	_root = root
	cast = conversation_cast
	rng.randomize()


## Called by Conversations.begin, never directly: begin is what asks
## whether anything else holds the player's attention, and what refuses a
## conversation with no root (see has_root).
func start() -> void:
	for effect in _root.start_effects:
		effect.apply(self)
		if ended:
			return
	_show_node(_resolve_interjection(_root))


## False for a conversation with nothing to show. Conversations.begin
## refuses one, so no starter has to remember to, and a bare begin() with
## no root opens and closes nothing.
func has_root() -> bool:
	return _root != null


# --- commands ---------------------------------------------------------------

## id is a snapshot choice id: "<node_id>:<index>" for an authored choice,
## or &"continue"/&"end" for the built-in one. Refused while a choice is
## still resolving or something is being shown.
func choose(id: StringName) -> void:
	if ended or _resolving or not waiting.is_empty() or current_node == null:
		return
	if id == &"continue" or id == &"end":
		if _builtin_choice() == id:
			advance()
		return

	var choice: DialogueChoice = null
	for candidate in _visible:
		if _choice_id(candidate) == id:
			choice = candidate
			break
	if choice == null:
		return

	used_choices[String(id)] = true
	_resolving = true
	var next_id: String = await choice.resolve(self)
	_resolving = false
	if ended:
		return
	_go_to(next_id)


## The "Continue" affordance: only meaningful when the current node has
## nothing to choose. An empty next_node_id ends the conversation.
func advance() -> void:
	if ended or _resolving or not waiting.is_empty() or current_node == null:
		return
	if not _visible.is_empty():
		return
	if current_node.next_node_id == "":
		end()
		return
	_go_to(current_node.next_node_id)


## The presenter finished showing what this conversation is waiting on.
func complete() -> void:
	if waiting.is_empty():
		return
	waiting = {}
	changed.emit()
	_wait_completed.emit()


## Ends the conversation with an outcome name (&"" for a plain goodbye).
## A second call is ignored, so the first ending stands.
func end(ending: StringName = &"") -> void:
	if ended:
		return
	ended = true
	outcome = ending
	_visible = []
	var was_waiting: bool = not waiting.is_empty()
	waiting = {}
	changed.emit()
	# A coroutine parked in show() must wake up to see the end, or it would
	# hang on a conversation nobody can complete any more.
	if was_waiting:
		_wait_completed.emit()


# --- state ------------------------------------------------------------------

## Everything a presenter needs to draw this conversation right now.
##   line/speaker: the latest spoken line and its token (tokens filled in)
##   node_id/node_text: the node being shown and its own text
##   visit: bumps on every node shown, including a revisit
##   choices: display entries, see describe_choice(); a built-in
##     continue/end entry when the node offers nothing
##   waiting: {kind, data, serial} while content waits on a presenter
##   busy: a choice is resolving
func snapshot() -> Dictionary:
	var line: String = ""
	var speaker: String = ""
	for i in range(transcript.size() - 1, -1, -1):
		if transcript[i].kind == &"line":
			line = transcript[i].text
			speaker = transcript[i].speaker
			break

	var entries: Array[Dictionary] = []
	if not ended and current_node:
		for choice in _visible:
			entries.append(describe_choice(choice))
		var builtin: StringName = _builtin_choice()
		if builtin != &"":
			entries.append({
				"id": builtin,
				"text": "Continue" if builtin == &"continue" else "End Conversation",
				"alignment": "",
				"check": {},
				"costs": PackedStringArray(),
				"builtin": true,
			})

	return {
		"line": line,
		"speaker": speaker,
		"node_id": current_node.id if current_node else "",
		"node_text": format(current_node.text_block) if current_node else "",
		"visit": visit,
		"choices": entries,
		"waiting": waiting.duplicate(),
		"busy": _resolving,
		"ended": ended,
		"outcome": outcome,
	}


## One choice as display data. The check preview is computed here with the
## same check_target() the roll uses, so the number on the row can never
## disagree with the number rolled against. A hidden check carries no
## number at all.
func describe_choice(choice: DialogueChoice) -> Dictionary:
	return {
		"id": _choice_id(choice),
		"text": format(choice.text),
		"alignment": choice.alignment_name,
		"check": _check_preview(choice),
		"costs": choice.cost_tags(self),
		"builtin": false,
	}


## Replaces every {key} in text with that variable's value — {gold} is the
## one negotiation uses today. Authored resources are shared between every
## conversation, so text is formatted on the way out, never in place.
func format(text: String) -> String:
	for key in vars:
		text = text.replace("{%s}" % key, str(vars[key]))
	return text


# --- for content ------------------------------------------------------------

## Appends one transcript entry and tells presenters. speaker_token "" is an
## aside (an alignment note, a roll result, a mood note); anything else is a
## line spoken by whoever that token resolves to.
func record(speaker_token: String, text: String, extras: Dictionary = {}) -> void:
	var speaker_name: String = ""
	if speaker_token != "":
		var unit: Unit = cast.get(speaker_token) as Unit
		speaker_name = unit.get_display_name() if is_instance_valid(unit) else speaker_token.capitalize()
	var entry: Dictionary = {
		"speaker": speaker_token,
		"name": speaker_name,
		"kind": &"line" if speaker_token != "" else &"aside",
		"text": format(text),
		"node": current_node.id if current_node else "",
	}
	entry.merge(extras)
	transcript.append(entry)
	changed.emit()


## Asks presenters to show something before the conversation moves on — the
## dice for a check today, a cutscene later — and waits until one calls
## complete(). With no presenter attached for kind it returns at once:
## that is what lets a test, or a stripped scene, run without a UI instead
## of hanging on a wait nobody will ever finish.
func show(kind: StringName, data: Dictionary) -> void:
	if ended or not _has_presenter(kind):
		return
	_wait_serial += 1
	waiting = {"kind": kind, "data": data, "serial": _wait_serial}
	changed.emit()
	await _wait_completed


## A presenter declares it can show waits of this kind. Keyed by instance
## id so a freed presenter never keeps a wait alive: _has_presenter drops
## ids that no longer resolve.
func attach(kind: StringName, presenter: Object) -> void:
	var ids: Array = _presenters.get(kind, [])
	if not ids.has(presenter.get_instance_id()):
		ids.append(presenter.get_instance_id())
	_presenters[kind] = ids


func detach(kind: StringName, presenter: Object) -> void:
	var ids: Array = _presenters.get(kind, [])
	ids.erase(presenter.get_instance_id())
	if not waiting.is_empty() and waiting.kind == kind and not _has_presenter(kind):
		complete()


## Present companion (or null) who can use skill_name — the assist half of
## a skill check. "player"/"npc" are the actor and the one being addressed,
## not an ally offering to help. First qualifying companion wins;
## ASSIST_BONUS doesn't stack.
func find_assisting_companion(skill_name: String) -> Unit:
	for token in cast:
		if token == "player" or token == "npc":
			continue
		var companion: Unit = cast[token] as Unit
		if is_instance_valid(companion) and SkillCalculator.get_skill_level(companion, skill_name).can_use_skill:
			return companion
	return null


## The acting unit's roll target for skill_name, assist included, plus the
## SkillCheckResult and who assisted — shared by the preview and by
## SkillCheckChoice/QuickContestChoice's actual roll.
func check_target(skill_name: String) -> Dictionary:
	var actor: Unit = cast.get("player") as Unit
	if not is_instance_valid(actor):
		return {"result": null, "target": 0, "assistant": null}
	var result: SkillCheckResult = SkillCalculator.get_skill_level(actor, skill_name)
	var assistant: Unit = find_assisting_companion(skill_name)
	return {
		"result": result,
		"target": result.skill_level + (ASSIST_BONUS if assistant else 0),
		"assistant": assistant,
	}


# --- internals --------------------------------------------------------------

func _show_node(node: DialogueNode) -> void:
	current_node = node
	visit += 1

	var visible_choices: Array[DialogueChoice] = []
	for i in node.choices.size():
		var choice: DialogueChoice = node.choices[i]
		if used_choices.has("%s:%d" % [node.id, i]) and not choice.is_repeatable:
			continue
		if choice.prerequisites and not choice.prerequisites.is_satisfied_in(self):
			continue
		visible_choices.append(choice)
	_visible = visible_choices

	if _visible.is_empty() and dead_end_effect != null:
		push_warning("Conversation: node '%s' has no available choices — applying the tree's dead-end effect." % node.id)
		_dead_end()
		return

	if not _narrated.has(node.id):
		_narrated[node.id] = true
		# record() emits changed, which also carries the new choices.
		record(node.speaker, node.text_block, {"narration": true})
		return
	changed.emit()


func _go_to(id: String) -> void:
	if id == "":
		_dead_end()
		return
	var node: DialogueNode = _find_node(id)
	if node == null:
		push_error("Conversation: no node found for id '%s' in %s" % [id, node_dir])
		_dead_end()
		return
	_show_node(_resolve_interjection(node))


## Every negotiation must end with an outcome, so its dead-end effect
## normally ends the conversation itself; a plain end() is the fallback for
## dialogue, and for an effect that somehow didn't.
func _dead_end() -> void:
	if dead_end_effect != null:
		dead_end_effect.apply(self)
		if ended:
			return
	end()


## First interjection on node whose prerequisite passes and that hasn't
## fired yet, shown INSTEAD of node; node itself otherwise. The
## interjection's own next_node_id is authored to land back on node.
func _resolve_interjection(node: DialogueNode) -> DialogueNode:
	for option in node.interjection_options:
		if _used_interjections.has(option.root.id):
			continue
		if not option.prerequisite or option.prerequisite.is_satisfied_in(self):
			_used_interjections[option.root.id] = true
			return option.root
	return node


func _find_node(id: String) -> DialogueNode:
	return index_for(node_dir).find_node(id)


## A choice is identified by where it is authored on the node being
## shown, so one that is not on that node (a preview asked of
## describe_choice with nothing shown yet) has no id, and nothing can
## choose it.
func _choice_id(choice: DialogueChoice) -> StringName:
	var index: int = current_node.choices.find(choice) if current_node else -1
	if index < 0:
		return &""
	return StringName("%s:%d" % [current_node.id, index])


func _builtin_choice() -> StringName:
	if ended or current_node == null or not _visible.is_empty() or dead_end_effect != null:
		return &""
	return &"continue" if current_node.next_node_id != "" else &"end"


func _check_preview(choice: DialogueChoice) -> Dictionary:
	if not (choice is SkillCheckChoice or choice is QuickContestChoice):
		return {}
	var skill: String = choice.skill_name
	if not choice.show_to_player:
		return {"skill": skill, "hidden": true, "target": 0, "can_use": false,
			"attemptable": false, "is_trained": false, "assistant": ""}
	var check: Dictionary = check_target(skill)
	var result: SkillCheckResult = check.result
	var assistant: Unit = check.assistant
	return {
		"skill": skill,
		"hidden": false,
		"target": check.target,
		"can_use": result.can_use_skill if result else false,
		"attemptable": result.attemptable if result else false,
		"is_trained": result.is_trained if result else false,
		"assistant": assistant.get_display_name() if assistant else "",
	}


func _has_presenter(kind: StringName) -> bool:
	var ids: Array = _presenters.get(kind, [])
	for id in ids.duplicate():
		if not is_instance_id_valid(id):
			ids.erase(id)
	return not ids.is_empty()


## One index per directory, shared by every conversation — indexing walks
## the folder once, not once per conversation or per node.
static func index_for(dir: String) -> DialogueNodeIndex:
	if not _indexes.has(dir):
		var index := DialogueNodeIndex.new("Conversation")
		index.ensure_indexed(dir)
		_indexes[dir] = index
	return _indexes[dir]
