extends AiTestCase
## The conversation log is meant to be the one fully-working control on the
## new lower-third dialogue layout, which only means something if it
## actually updates while it's open — see conversation_log.gd's own header.
## Before this suite it only ever rebuilt itself on visibility_changed, so
## a line recorded while the panel was already open would silently sit
## missing until the player closed and reopened it.
##
## Instantiates conversation_log.tscn directly rather than going through
## UIStack/MainRoot (not present in the headless runner — see
## ai_test_case.gd's own note on this), and drives it exactly the way
## production does: UIStack.push()/pop() just set screen.visible, so
## toggling log.visible here IS the real code path, not a stand-in for it.
## Lines are recorded through DialogueManager.record_line() (the real
## autoload, the real formatting), not by hand-appending strings — record_line
## already writes transcript[-1] BEFORE emitting line_shown, which is the
## exact ordering conversation_log.gd's _on_line_shown() depends on.
##
## DialogueManager.transcript/participants are shared autoload state, saved
## and restored around this run like test_gaze_follows_the_speaker.gd
## already does for participants.

var _saved_transcript: Array[String] = []
var _saved_participants: Dictionary = {}
var _log: Control = null
var _text_label: RichTextLabel = null


func run() -> void:
	_saved_transcript = DialogueManager.transcript.duplicate()
	_saved_participants = DialogueManager.participants.duplicate()
	# Emptied rather than left alone — record_line() looks a speaker token
	# up in participants and falls back to token.capitalize() only when
	# nothing is bound there. Clearing it makes that fallback the only
	# path, so the formatting this suite asserts on can't drift depending
	# on what an earlier suite happened to leave bound to "npc"/"player".
	DialogueManager.participants = {}
	DialogueManager.transcript.clear()

	# A baseline BEFORE the widget exists at all, so the teardown check at
	# the bottom can assert the connection count returns to exactly this,
	# not just "some number lower than right before freeing."
	var connections_before_widget: int = DialogueManager.line_shown.get_connections().size()

	DialogueManager.record_line("First line.", "npc")
	DialogueManager.record_line("Second line.", "player")

	_log = load("res://systems/dialogue_system/conversation_log.tscn").instantiate()
	_root.add_child(_log)
	await get_tree().process_frame
	_text_label = _log.get_node("PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/RichTextLabel")

	check("the widget connects to line_shown on _ready",
		DialogueManager.line_shown.get_connections().size() == connections_before_widget + 1,
		"connection count is %d, expected %d" % [
			DialogueManager.line_shown.get_connections().size(), connections_before_widget + 1])

	# --- opening shows everything already said --------------------------
	check("closed by default", not _log.visible)
	check("nothing rendered while closed", _text_label.text == "")

	_log.visible = true
	await get_tree().process_frame

	check("opening the log shows a line already in the transcript before it opened",
		_text_label.text.contains("First line."),
		"text was: %s" % _text_label.text)
	check("and the other one too",
		_text_label.text.contains("Second line."),
		"text was: %s" % _text_label.text)
	check("exactly the 2 pre-existing lines, not more or fewer",
		_entry_count() == 2,
		"got %d entries" % _entry_count())

	# --- a line recorded while open appears without reopening -----------
	var count_before_live: int = _entry_count()
	DialogueManager.record_line("Third line.", "npc")
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
	DialogueManager.record_line("Fourth line.", "player")
	await get_tree().process_frame
	check("and again for a second line, same delta",
		_entry_count() == count_before_second + 1,
		"was %d entries, now %d" % [count_before_second, _entry_count()])

	# --- system echo (empty speaker token) is dimmed italic; a spoken
	# line is not ----------------------------------------------------------
	DialogueManager.record_line("(you feel uneasy)")
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
	_log.queue_free()
	_log = null
	await get_tree().process_frame
	await get_tree().process_frame

	# Mirrors tests/combat/test_selection_is_a_node.gd's own dangling-
	# connection check: get_object() on a callable whose target was freed
	# comes back null rather than erroring, which is itself the leak
	# signature — a genuinely-disconnected signal has no entry here at all.
	var leaked: bool = false
	for connection in DialogueManager.line_shown.get_connections():
		var callable: Callable = connection["callable"]
		var target: Object = callable.get_object()
		if target == null or not is_instance_valid(target):
			leaked = true
		elif target.get_instance_id() == log_id:
			leaked = true
	check("no connection targeting the freed widget survives it exiting the tree",
		not leaked,
		"line_shown still holds a callable bound to the freed log widget")
	check("and the connection count is back to exactly what it was before the widget existed",
		DialogueManager.line_shown.get_connections().size() == connections_before_widget,
		"connection count is %d, expected %d" % [
			DialogueManager.line_shown.get_connections().size(), connections_before_widget])

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
		_log.queue_free()
	DialogueManager.transcript = _saved_transcript
	DialogueManager.participants = _saved_participants
