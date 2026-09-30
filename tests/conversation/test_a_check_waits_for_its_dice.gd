extends AiTestCase
## Pins the one thing dialogue has that negotiation does not: a choice
## that rolls dice and waits for the player to see them before it goes
## on. The rewrite has to keep the pause where it is (after the roll,
## before the result line and the routing), keep the number rolled
## against honest (skill plus at most one assist), and keep the contest's
## tie rule. If a check ever resolves before its dice are dismissed, the
## player reads the result line before the dice have landed.
##
## The dice here are the driver's stand-in presenter (hold_dice), not the
## popup: the popup's own two-click flow is pinned in
## test_the_band_follows_the_conversation. Every roll is pinned through
## the driver, on the conversation's own dice; see its header.
##
## Bare battlefield. Everything goes through conversation_driver.gd.

const Driver := preload("res://tests/conversation/conversation_driver.gd")

var d: Driver
var ada: Unit
var npc: Unit
var cato: Unit
var k_root: DialogueNode


func run() -> void:
	d = Driver.new()
	add_child(d)
	d.begin()
	ada = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3.ZERO)
	ada.display_name = "Ada"
	npc = spawn_unit(&"neutral", 10, 10, 10, [melee()], Vector3(2, 0, 0))
	npc.display_name = "Brom"
	cato = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(-2, 0, 0))
	cato.display_name = "Cato"

	_register_tree()
	await _cannot_attempt()
	await _check_waits()
	await _check_fails_to_its_branch()
	await _second_pick_while_waiting()
	await _contest()
	await _contest_untrained_still_rolls()

	d.finish()


func _register_tree() -> void:
	k_root = d.node("k_root", "Convince me.", [
			d.skill_check("Try.", "Persuasion", "k_yes", "k_no"),
			d.skill_check("Weave a basket.", "Basket Weaving", "k_yes", "k_no"),
			d.contest("Out-talk me.", "Persuasion", "Insight", "k_yes", "k_no"),
			d.contest("Out-weave me.", "Basket Weaving", "Insight", "k_yes", "k_no")])
	d.register_dialogue([k_root,
		d.node("k_yes", "You win.", [d.line("Bye.")]),
		d.node("k_no", "You lose.", [d.line("Bye.")]),
	])


func _start(with_cato: bool) -> void:
	var who: Dictionary = {"player": ada, "npc": npc}
	if with_cato:
		who["cato"] = cato
	d.start_dialogue(k_root, who)


## dlg_skill_check_cannot_use.
func _cannot_attempt() -> void:
	d.hold_dice()
	_start(false)
	await d.choose("Weave a basket.")
	check("a skill nobody has cannot be attempted: it goes to the failure branch",
		d.current_node_id() == "k_no", d.current_node_id())
	check("with a line saying so",
		d.transcript_texts().has("(Basket Weaving has no way to attempt this.)"), str(d.transcript_texts()))
	check("and no dice", d.dice_requests.is_empty())
	d.end_dialogue()
	d.release_dice()


## dlg_skill_check_roll, dlg_dice_wait, dlg_companion_assist,
## dlg_used_choices_marked_before_resolve.
func _check_waits() -> void:
	d.hold_dice()
	d.clear_events()
	_start(true)
	check("setup: Persuasion can be attempted by a blank unit", d.can_attempt(ada, "Persuasion"))
	check("a present companion who can use the skill assists", d.assistant_for("Persuasion") == cato)
	var target: int = d.skill_target(ada, "Persuasion") + d.assist_bonus()
	check("the assist is a flat +1", d.assist_bonus() == 1)

	var said_before: int = d.transcript().size()
	d.pin_skill_roll(target, true)
	d.choose("Try.")
	check("the check stops at its dice", d.dice_waiting() and d.dice_requests.size() == 1)
	check("the dice are asked for with the skill and the roll made",
		d.dice_requests[0].skill == "Persuasion" and d.dice_requests[0].roll.target == target,
		str(d.dice_requests[0]))
	check("the choice is already marked used while the dice are up", d.was_used("k_root", 0))
	check("no result line before the dice are dismissed", d.transcript().size() == said_before)
	check("and no routing either", d.current_node_id() == "k_root")

	d.finish_dice()
	await get_tree().process_frame
	var roll: Dictionary = d.dice_requests[0].roll
	var result: String = d.transcript_texts()[said_before]
	check("dismissing the dice records the result, crediting the helper",
		result.ends_with(" at a Persuasion check (Cato helped) — rolled %d vs target %d" % [roll.roll, target])
		and (result.begins_with("Succeeded") or result.begins_with("Critically succeeded")), result)
	check("then routes by the roll", d.current_node_id() == "k_yes", d.current_node_id())
	d.end_dialogue()
	d.release_dice()


func _check_fails_to_its_branch() -> void:
	_start(false)
	var target: int = d.skill_target(ada, "Persuasion")
	check("no companion, no assist", d.assistant_for("Persuasion") == null)
	d.pin_skill_roll(target, false)
	await d.choose("Try.")
	var result: String = d.last_said(1)
	check("a failed roll goes to the failure branch", d.current_node_id() == "k_no")
	check("with no helper credited and the unassisted target",
		not result.contains("helped") and result.ends_with("vs target %d" % target), result)
	check("with nothing listening for dice, a check does not wait at all", d.events.back() == "choices:1")
	d.end_dialogue()


## dlg_choose_no_reentrancy_guard. The old manager took a second pick
## while the first waited on its dice, and both resolved on one dismissal.
## The conversation refuses a pick while it is resolving or waiting, so
## this now pins the guard instead of the hole.
func _second_pick_while_waiting() -> void:
	d.hold_dice()
	d.clear_events()
	_start(false)
	var said_before: int = d.transcript().size()
	d.choose("Try.")
	d.choose_row(0)
	check("a second pick while the first is at its dice is refused",
		d.dice_requests.size() == 1, str(d.dice_requests.size()))
	d.finish_dice()
	await get_tree().process_frame
	var rolled: int = 0
	for text in d.transcript_texts().slice(said_before):
		if text.contains(" rolled "):
			rolled += 1
	check("and one dismissal resolves the one pick", rolled == 1, str(d.transcript_texts()))
	d.end_dialogue()
	d.release_dice()


## dlg_contest_roll.
func _contest() -> void:
	d.hold_dice()
	d.clear_events()
	_start(false)
	var mine: int = d.skill_target(ada, "Persuasion")
	var theirs: int = d.skill_target(npc, "Insight")
	d.pin_contest(mine, theirs, true, true)
	d.choose("Out-talk me.")
	check("a contest shows one set of dice, the actor's",
		d.dice_requests.size() == 1 and d.dice_requests[0].roll.target == mine, str(d.dice_requests))
	d.finish_dice()
	await get_tree().process_frame
	var line: String = d.last_said(1)
	check("a tie goes to the actor", d.current_node_id() == "k_yes", line)
	check("and the line reports both sides",
		line.begins_with("You win the contest — your Persuasion rolled ")
		and line.contains(", their Insight rolled ") and line.ends_with(" vs %d" % theirs), line)
	d.end_dialogue()

	_start(false)
	d.clear_events()
	d.pin_contest(mine, theirs, false)
	d.choose("Out-talk me.")
	d.finish_dice()
	await get_tree().process_frame
	check("losing a contest goes to the failure branch", d.current_node_id() == "k_no")
	check("and says so", d.last_said(1).begins_with("You lose the contest"),
		d.last_said(1))
	d.end_dialogue()
	d.release_dice()


## dlg_contest_no_cannot_use_branch.
func _contest_untrained_still_rolls() -> void:
	d.hold_dice()
	d.dice_requests.clear()
	_start(false)
	d.choose("Out-weave me.")
	check("a contest in a skill nobody has still rolls, at its floor",
		d.dice_requests.size() == 1 and d.dice_requests[0].roll.target == 0, str(d.dice_requests))
	d.finish_dice()
	await get_tree().process_frame
	d.end_dialogue()
	d.release_dice()
