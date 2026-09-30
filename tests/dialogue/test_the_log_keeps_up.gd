extends AiTestCase
## The conversation log is meant to be the one fully-working control on the
## new lower-third dialogue layout, which only means something if it
## actually updates while it's open — see conversation_log.gd's own header.
## Before this suite it only ever rebuilt itself on visibility_changed, so
## a line recorded while the panel was already open would silently sit
## missing until the player closed and reopened it.
##
## Instantiates conversation_log.tscn directly rather than through
## MainRoot (not present in the headless runner — see ai_test_case.gd's own
## note on this), and opens it exactly the way production does: through
## UIStack.push(), the call the band's Log chip makes. What is asserted is
## that the log is visible in the tree, not what UIStack believes, so a
## log that UIStack "opens" but nobody can see is red here.
## Lines are recorded through Conversation.record() on a real, begun
## conversation (the real formatting, the real `changed` signal), not by
## hand-appending strings — record() writes the transcript entry BEFORE
## emitting changed, which is the exact ordering conversation_log.gd's
## _on_changed() depends on. The conversation is this suite's own and is
## ended in _cleanup, so no shared state needs saving around it.

var _conversation: Conversation = null
var _log: Control = null
var _text_label: RichTextLabel = null


func run() -> void:
	# An empty cast — record() looks a speaker token up in the cast and
	# falls back to token.capitalize() only when nothing is bound there.
	# Leaving it empty makes that fallback the only path, so the formatting
	# this suite asserts on can't drift. The root's own text is narrated as
	# an aside when the conversation begins, so the transcript opens with
	# that one entry before the lines recorded below.
	var root := DialogueNode.new()
	root.text_block = "The fire crackles."
	_conversation = Conversation.new(root, {})
	check("SETUP: the conversation began",
		Conversations.begin(_conversation),
		"refused — something already holds the player's input")

	# A baseline BEFORE the widget exists at all, so the teardown check at
	# the bottom can assert the connection counts return to exactly this,
	# not just "some number lower than right before freeing."
	var changed_before_widget: int = _conversation.changed.get_connections().size()
	var began_before_widget: int = Conversations.began.get_connections().size()

	_conversation.record("npc", "First line.")
	_conversation.record("player", "Second line.")

	_log = load("res://systems/dialogue_system/conversation_log.tscn").instantiate()
	_root.add_child(_log)
	await get_tree().process_frame
	_text_label = _log.get_node("PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/RichTextLabel")

	check("the widget follows the running conversation on _ready",
		_conversation.changed.get_connections().size() == changed_before_widget + 1,
		"changed connection count is %d, expected %d" % [
			_conversation.changed.get_connections().size(), changed_before_widget + 1])
	check("and listens for the next one to begin",
		Conversations.began.get_connections().size() == began_before_widget + 1,
		"began connection count is %d, expected %d" % [
			Conversations.began.get_connections().size(), began_before_widget + 1])

	# --- opening shows everything already said --------------------------
	check("closed by default", not _log.is_visible_in_tree())
	check("nothing rendered while closed", _text_label.text == "")

	UIStack.push(_log)
	await get_tree().process_frame
	check("opened through UIStack, the log is on screen",
		_log.is_visible_in_tree(),
		"UIStack.push left the log invisible in the tree")

	check("opening the log shows a line already in the transcript before it opened",
		_text_label.text.contains("First line."),
		"text was: %s" % _text_label.text)
	check("and the other one too",
		_text_label.text.contains("Second line."),
		"text was: %s" % _text_label.text)
	check("exactly the narrated opening and the 2 pre-existing lines, not more or fewer",
		_entry_count() == 3 and _text_label.text.contains("The fire crackles."),
		"got %d entries: %s" % [_entry_count(), _text_label.text])

	# --- a line recorded while open appears without reopening -----------
	var count_before_live: int = _entry_count()
	_conversation.record("npc", "Third line.")
	await get_tree().process_frame

	check("a line recorded while the log is open appears without closing/reopening it",
		_text_label.text.contains("Third line."),
		"text was: %s" % _text_label.text)
	check("the entry count grows by exactly one for that one recorded line",
		_entry_count() == count_before_live + 1,
		"was %d entries, now %d" % [count_before_live, _entry_count()])

	# --- growth is exactly 1 per line, checked a second time to rule out
	# a fixed off-by-one rather than a coincidence -----------------------
	var count_before_second: int = _entry_count()
	_conversation.record("player", "Fourth line.")
	await get_tree().process_frame
	check("and again for a second line, same delta",
		_entry_count() == count_before_second + 1,
		"was %d entries, now %d" % [count_before_second, _entry_count()])

	# --- system echo (empty speaker token) is dimmed italic; a spoken
	# line is not ----------------------------------------------------------
	_conversation.record("", "(you feel uneasy)")
	await get_tree().process_frame

	check("a system echo line renders dimmed and italic",
		_text_label.text.contains("[color=#A0A0A0][i](you feel uneasy)[/i][/color]"),
		"text was: %s" % _text_label.text)
	check("a spoken line is NOT wrapped in that same dim/italic treatment",
		not _text_label.text.contains("[color=#A0A0A0][i]First line.[/i][/color]"),
		"the spoken line picked up the echo-line styling — text was: %s" % _text_label.text)
	check("a spoken line instead gets the bold speaker-name treatment",
		_text_label.text.contains("[b]Npc[/b]"),
		"text was: %s" % _text_label.text)

	# --- teardown leaves no connection behind ----------------------------
	var log_id: int = _log.get_instance_id()
	UIStack.pop(_log)
	_log.queue_free()
	_log = null
	await get_tree().process_frame
	await get_tree().process_frame

	# Mirrors tests/combat/test_selection_is_a_node.gd's own dangling-
	# connection check: get_object() on a callable whose target was freed
	# comes back null rather than erroring, which is itself the leak
	# signature — a genuinely-disconnected signal has no entry here at all.
	var leaked: bool = false
	for connection in _conversation.changed.get_connections() + Conversations.began.get_connections():
		var callable: Callable = connection["callable"]
		var target: Object = callable.get_object()
		if target == null or not is_instance_valid(target):
			leaked = true
		elif target.get_instance_id() == log_id:
			leaked = true
	check("no connection targeting the freed widget survives it exiting the tree",
		not leaked,
		"changed or began still holds a callable bound to the freed log widget")
	check("and the connection counts are back to exactly what they were before the widget existed",
		_conversation.changed.get_connections().size() == changed_before_widget
			and Conversations.began.get_connections().size() == began_before_widget,
		"changed %d (expected %d), began %d (expected %d)" % [
			_conversation.changed.get_connections().size(), changed_before_widget,
			Conversations.began.get_connections().size(), began_before_widget])

	_cleanup()


## "\n\n".join(...) is exactly how both the full rebuild and the
## incremental append build this text (see conversation_log.gd), so
## splitting back on the same separator recovers the entry count without
## this suite needing its own notion of what an "entry" looks like.
func _entry_count() -> int:
	if _text_label.text == "":
		return 0
	return _text_label.text.split("\n\n").size()


func _cleanup() -> void:
	if is_instance_valid(_log):
		UIStack.pop(_log)
		_log.queue_free()
	if _conversation:
		_conversation.end()
