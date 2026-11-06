extends Node
## Autoload singleton ("Conversations"). The one place a conversation is
## started, and the one answer to "is a conversation running".
##
## Holds a reference to the running Conversation and nothing else of its
## state: the conversation owns its node, cast, variables and transcript,
## and presenters subscribe to it directly (via began) rather than to this.
##
## begin() asks GameMode whether anything already holds the player's input,
## instead of asking each other system in turn. That replaces the pairwise
## start checks the two old managers made against each other and the stash:
## a new thing that holds input is added to GameMode once, and every starter
## respects it.
##
## Who may START a conversation is not decided here either. Talk refuses a
## speaker who is fighting and Negotiate requires one who is; those rules
## live with the two starters (TalkInteraction.start, NegotiateInteraction
## .start), because they are about the people involved, not about
## conversations.

signal began(conversation: Conversation)
signal ended(conversation: Conversation)

var current: Conversation = null
## A test pins the next conversation's dice by setting this before begin;
## it is consumed by that one begin. -1 leaves the conversation randomly
## seeded, which is what play always does.
var next_seed: int = -1

## Tree folders already linted, so each is checked once.
var _linted: Dictionary = {}


## Only the engine's own default folder is linted here. A starter that
## keeps its trees elsewhere lints them itself, with its own rules (see
## NegotiateInteraction.start), so this file never learns what kind of
## trees live where.
func _ready() -> void:
	lint(Conversation.DIALOGUE_DIR)


## Starts c, or refuses (returning false) when there is nothing to show or
## something already holds the player's input: another conversation, the
## stash, anything GameMode counts.
##
## A pinned seed is taken BEFORE the refusal checks, so it belongs to this
## one begin whatever happens to it. Taken after, a pin set for a begin that
## was refused would silently seed whichever conversation began next.
func begin(c: Conversation) -> bool:
	var pinned: int = next_seed
	next_seed = -1
	if c == null or not c.has_root() or current != null or GameMode.input_is_taken():
		return false
	if pinned >= 0:
		c.rng.seed = pinned
	current = c
	c.changed.connect(_on_changed)
	began.emit(c)
	c.start()
	return true


## How a presenter follows conversations: on_began is called for every
## conversation that begins while presenter is in the tree, and at once for
## one already running when it enters. So a presenter built late, one
## re-added mid-conversation, and one there from the start are the same
## case, and none of them hears a conversation begin while it is out of the
## tree. The subscription to this autoload's signal is undone when the
## presenter leaves the tree rather than left for the presenter to
## remember, which is the recorded autoload-signal-leak bug class
## (refcounted_component_autoload_signal_leak in project memory).
##
## Called once, from the presenter's _ready: the tree_entered connection
## is what re-subscribes it on any later entry.
func follow(presenter: Node, on_began: Callable) -> void:
	presenter.tree_entered.connect(_subscribe.bind(on_began))
	presenter.tree_exiting.connect(_unsubscribe.bind(on_began))
	if presenter.is_inside_tree():
		_subscribe(on_began)


func _subscribe(on_began: Callable) -> void:
	if not began.is_connected(on_began):
		began.connect(on_began)
	if current:
		on_began.call(current)


func _unsubscribe(on_began: Callable) -> void:
	if began.is_connected(on_began):
		began.disconnect(on_began)


## Only the current conversation is ever connected, so "current has ended"
## is the whole test.
func _on_changed() -> void:
	if current == null or not current.ended:
		return
	var c: Conversation = current
	current = null
	c.changed.disconnect(_on_changed)
	ended.emit(c)


## Debug sanity pass over every hand-typed node-id reference in one tree
## folder. The ids are plain strings with no compile-time checking, so a
## typo would otherwise stay silent for a whole playthrough that never
## reaches that branch. Warns once per folder; problems_in() is the pass
## itself, kept separate so what it finds can be asked for directly.
func lint(dir: String, strict: bool = false) -> void:
	if not OS.is_debug_build() or _linted.has(dir):
		return
	_linted[dir] = true
	for problem in problems_in(dir, strict):
		push_warning("Conversations: %s" % problem)


## Every authoring problem in one tree folder, one line each.
##
## strict is for a tree that must always end through an explicit ending
## effect (DialogueEffect.ends_conversation) rather than by running out:
## there an empty next id outside an ending choice is a mistake, where for
## an ordinary dialogue it is the normal way to finish. Whatever an effect
## itself knows to be wrong with how it was authored, it reports through
## DialogueEffect.authoring_problem, so no kind of effect is named here.
func problems_in(dir: String, strict: bool = false) -> PackedStringArray:
	var problems: PackedStringArray = []
	var index: DialogueNodeIndex = Conversation.index_for(dir)
	for id in index.all_ids():
		var node: DialogueNode = index.find_node(id)
		_check(problems, index, id, "DialogueNode.next_node_id", node.next_node_id, false)
		for choice in node.choices:
			for effect in choice.effects:
				var problem: String = effect.authoring_problem() if effect else ""
				if problem != "":
					problems.append("node '%s': %s" % [id, problem])
			if choice is LineChoice:
				if choice.returns_to_root:
					continue
				_check(problems, index, id, "LineChoice.next_node_id", choice.next_node_id, strict and not _ends(choice))
			elif choice is SkillCheckChoice or choice is QuickContestChoice:
				_check(problems, index, id, "%s.success_node_id" % choice.get_script().get_global_name(), choice.success_node_id, false)
				_check(problems, index, id, "%s.failure_node_id" % choice.get_script().get_global_name(), choice.failure_node_id, false)
	return problems


func _ends(choice: DialogueChoice) -> bool:
	for effect in choice.effects:
		if effect and effect.ends_conversation():
			return true
	return false


func _check(problems: PackedStringArray, index: DialogueNodeIndex, from_id: String, field: String, target_id: String, empty_is_wrong: bool) -> void:
	if target_id == "":
		if empty_is_wrong:
			problems.append("%s on node '%s' is empty — this tree must end through an ending effect, not an empty next id." % [field, from_id])
		return
	if not index.has_id(target_id):
		problems.append("%s on node '%s' references unknown node id '%s'." % [field, from_id, target_id])
