extends AiTestCase
## Pins how a dialogue opens, what it refuses, and what it leaves behind
## when it closes. Written ahead of the conversation rewrite, when opening
## was where the two old engines differed most (dialogue had no
## re-entrancy guard, negotiation did). The rewrite changed three pins
## here on purpose, each marked where it stands: a conversation is active
## before its start is announced, a second start is refused, and ending
## with nothing open announces nothing. Anything else going red here is a
## finding, not a port.
##
## Bare battlefield: talking needs no world, and a dialogue refuses only
## its own participants being in a fight, which test_talking_needs_no_fight
## covers with a real one.
##
## Everything goes through conversation_driver.gd. See its header.

const Driver := preload("res://tests/conversation/conversation_driver.gd")

var d: Driver
var ada: Unit
var npc: Unit


func run() -> void:
	d = Driver.new()
	add_child(d)
	d.begin()
	ada = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3.ZERO)
	ada.display_name = "Ada"
	npc = spawn_unit(&"neutral", 10, 10, 10, [melee()], Vector3(2, 0, 0))
	npc.display_name = "Brom"

	await _refusals()
	await _signal_order_and_state()
	await _restart_wipes_everything()
	await _interjection_on_root()
	await _end_keeps_the_record()
	await _transcript_format()
	await _stash_and_dialogue_exclude_each_other()
	await _participant_prereq()
	await _return_to_root_asks_who_is_here()

	d.finish()


func _pair() -> Dictionary:
	return {"player": ada, "npc": npc}


## dlg_start_refuse_null_root, dlg_start_refuse_stash_open.
func _refusals() -> void:
	d.clear_events()
	d.start_dialogue(null, _pair())
	check("a null root starts nothing", not d.dialogue_active())
	check("and emits nothing", d.events.is_empty(), str(d.events))
	# The same refusal, asked of Conversations.begin itself rather than of
	# the Talk verb's starter: it is begin that owns it, so no starter has
	# to remember to check first.
	d.begin_bare(null, _pair())
	check("begin itself refuses a conversation with no root",
		not d.dialogue_active() and d.events.is_empty(), str(d.events))
	# A seed pinned for "the next conversation" belongs to the next one
	# that actually begins. A refused begin still takes it, so it cannot
	# leak into some later conversation the pin was never meant for.
	d.seed_rng(4242)
	check("setup: a seed is waiting", d.pending_seed() == 4242)
	d.begin_bare(null, _pair())
	check("a refused begin does not carry the pinned seed forward",
		d.pending_seed() == -1, str(d.pending_seed()))

	var stash := StashComponent.new()
	StashManager.open_stash(stash, ada)
	check("setup: a stash is open", StashManager.is_active())
	d.start_dialogue(d.node("r_stash", "Hello."), _pair())
	check("an open stash refuses a dialogue", not d.dialogue_active())
	check("and nothing is emitted", d.event_count("dialogue_started") == 0, str(d.events))
	StashManager.close_stash()
	stash.free()


## dlg_start_signal_order, dlg_is_active_derived, mode_dialogue_derived.
func _signal_order_and_state() -> void:
	d.clear_events()
	var root: DialogueNode = d.node("r_order", "Well met.", [d.line("Bye.")])
	d.start_dialogue(root, _pair())
	check("started, then the line, then the choices",
		d.events.slice(0, 3) == ["dialogue_started:r_order", "line:npc:Well met.", "choices:1"],
		str(d.events))
	# Changed by the rewrite: Conversations.current is set before began is
	# emitted, so a listener already sees the conversation it hears about.
	check("already active while dialogue_started is being heard",
		d.state_at("dialogue_started").get("dialogue_active") == true)
	check("active once the node is up", d.dialogue_active())
	check("the game is in DIALOGUE mode while it runs", d.mode() == "DIALOGUE", d.mode())
	check("the root is the current node", d.current_node_id() == "r_order")
	d.end_dialogue()
	check("inactive once ended", not d.dialogue_active())
	check("mode leaves DIALOGUE when it ends", d.mode() != "DIALOGUE", d.mode())


## dlg_start_no_reentrancy_guard, dlg_start_resets_state. Changed by the
## rewrite: the old manager restarted in place, wiping the first
## conversation without ending it. Conversations.begin now refuses while
## one runs, so the first is left exactly as it was.
func _restart_wipes_everything() -> void:
	var first: DialogueNode = d.node("r_first", "First.", [d.line("Pick me.", "r_first"), d.line("Bye.")])
	d.register_dialogue([first])
	d.start_dialogue(first, _pair())
	await d.choose("Pick me.")
	check("setup: a used choice is on the record", d.was_used("r_first", 0))

	var other := spawn_unit(&"neutral", 10, 10, 10, [melee()], Vector3(4, 0, 0))
	other.display_name = "Cato"
	d.clear_events()
	d.start_dialogue(d.node("r_second", "Second.", [d.line("Bye.")]), {"player": ada, "npc": other})
	check("a second start while one runs is refused",
		d.dialogue_active() and d.current_node_id() == "r_first", d.current_node_id())
	check("nothing is announced: the first neither ends nor restarts",
		d.event_count("dialogue_ended") == 0 and d.event_count("dialogue_started") == 0, str(d.events))
	check("the transcript is the first conversation's, untouched",
		not d.transcript_texts().has("Second.") and d.transcript_texts().has("First."), str(d.transcript_texts()))
	check("used choices are kept", d.was_used("r_first", 0))
	check("participants are kept", d.participants().get("npc") == npc)
	d.end_dialogue()


## dlg_start_interjection_on_root.
func _interjection_on_root() -> void:
	var root: DialogueNode = d.node("r_root", "The usual.", [d.line("Bye.")])
	var cut_in: DialogueNode = d.node("r_cut_in", "Wait, before that!", [d.line("Go on.", "r_root")])
	d.interject(root, cut_in)
	d.register_dialogue([root, cut_in])
	d.start_dialogue(root, _pair())
	check("a satisfied interjection replaces the root at start",
		d.current_node_id() == "r_cut_in", d.current_node_id())
	await d.choose("Go on.")
	check("and fires once: going to the root again shows the root",
		d.current_node_id() == "r_root", d.current_node_id())
	d.end_dialogue()


## dlg_end_cleanup, dlg_end_callable_when_inactive.
func _end_keeps_the_record() -> void:
	var root: DialogueNode = d.node("r_end", "Goodbye soon.", [d.line("Again.", "r_end"), d.line("Bye.")])
	d.register_dialogue([root])
	d.start_dialogue(root, _pair())
	await d.choose("Again.")
	d.end_dialogue()
	check("ending clears the current node", d.current_node_id() == "")
	check("ending clears the participants", d.participants().is_empty())
	check("ending keeps the transcript until the next start",
		d.transcript_texts().has("Goodbye soon."), str(d.transcript_texts()))
	check("ending keeps the used choices until the next start", d.was_used("r_end", 0))

	d.clear_events()
	d.end_dialogue()
	# Changed by the rewrite: there is no manager left to announce an end
	# for; with nothing running, ending touches nothing.
	check("ending with nothing open announces nothing",
		d.events.is_empty(), str(d.events))


## dlg_record_line_transcript_format, dlg_empty_text_still_recorded.
func _transcript_format() -> void:
	var root: DialogueNode = d.node("r_fmt", "Name first.", [
		d.line("Tagged.", "r_empty", {"alignment": "Lawful", "spoken": "I say so."})])
	var empty: DialogueNode = d.node("r_empty", "", [d.line("Bye.")])
	d.register_dialogue([root, empty])
	d.start_dialogue(root, _pair())
	await d.choose("Tagged.")
	var raw: Array[String] = d.transcript_raw()
	check("a speaker line is the bold display name, a newline, then the text",
		raw[0] == "[b]Brom[/b]\nName first.", raw[0])
	check("an unspoken line is grey italic",
		raw[1].begins_with("[color=#A0A0A0][i]") and raw[1].ends_with("[/i][/color]"), raw[1])
	check("the player's spoken line is under the player's name",
		raw[2] == "[b]Ada[/b]\nI say so.", raw[2])
	check("a node with no text still leaves a transcript entry",
		raw.size() == 4 and raw[3] == "[b]Brom[/b]\n", str(raw))
	check("and still announces the line with its speaker",
		d.event_index("line:npc:") >= 0 and d.events.has("line:npc:"), str(d.events))

	d.end_dialogue()
	d.start_dialogue(d.node("r_nobody", "Who?", [d.line("Bye.")], "stranger"), _pair())
	check("a speaker token nobody is bound to shows as the capitalised token",
		d.transcript_raw()[0] == "[b]Stranger[/b]\nWho?", d.transcript_raw()[0])
	d.end_dialogue()


## stash_refused_during_dialogue.
func _stash_and_dialogue_exclude_each_other() -> void:
	d.start_dialogue(d.node("r_stash2", "Hold on.", [d.line("Bye.")]), _pair())
	var stash = StashManager.current_stash
	var box := StashComponent.new()
	StashManager.open_stash(box, ada)
	check("a stash cannot open during a conversation", not StashManager.is_active())
	d.end_dialogue()
	box.free()
	check("setup: no stash was left open", StashManager.current_stash == stash)


## dlg_participant_present_prereq.
func _participant_prereq() -> void:
	var needs_leader: PrerequisiteRule = d.needs_participant("leader")
	check("no conversation: a participant check fails", not d.satisfied(needs_leader, ada))
	d.start_dialogue(d.node("r_pp", "Hm.", [d.line("Bye.")]), {"player": ada, "npc": npc, "leader": ada})
	check("a bound token satisfies it", d.satisfied(needs_leader, ada))
	check("an unbound token does not", not d.satisfied(d.needs_participant("wren"), ada))
	d.end_dialogue()


## Which entry an NPC opens on is asked of the conversation, not of the
## player alone, so a gate on who is present holds when a line routes back
## to the root mid-conversation, the same as it does in a line's own gate.
func _return_to_root_asks_who_is_here() -> void:
	var cato: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(-2, 0, 0))
	cato.display_name = "Cato"
	var with_wren: DialogueNode = d.node("r_with_wren", "And Wren, too.", [d.line("Bye.")])
	var plain: DialogueNode = d.node("r_plain", "You again.", [d.line("Start over.", "", {"to_root": true}), d.line("Bye.")])
	d.register_dialogue([with_wren, plain])
	d.give_dialogues(npc, [[with_wren, d.needs_participant("wren")], [plain, null]])
	d.start_dialogue(plain, {"player": ada, "npc": npc, "wren": cato})
	await d.choose("Start over.")
	check("routing back to the root opens the entry gated on a present companion",
		d.current_node_id() == "r_with_wren", d.current_node_id())
	d.end_dialogue()
	d.silence(npc)
	remove_spawned(cato)
	await get_tree().process_frame
