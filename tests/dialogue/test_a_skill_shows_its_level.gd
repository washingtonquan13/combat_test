extends AiTestCase
## The user's one requested change to an approved dialogue-UI mockup:
## "untrained skills should show skill levels like trained skills do."
## DialogueFormat.skill_tag used to print the literal word "untrained"
## whenever SkillCalculator.get_skill_level's can_use_skill came back
## false, discarding a real, honest number in the process for every
## skill in data/skills/* — every one of them defaults off an ATTRIBUTE
## source, which always resolves, so can_use_skill was already true (and
## a real number already showing) for the untrained-but-defaulted case;
## the only place a number was ever actually being replaced by a word
## was the genuinely-nothing-to-show case (no skill_data at all, or a
## default that never resolves). See skill_tag's own header for the
## resulting 3-case rendering this suite exercises directly.
##
## Also covers Task 2's two new non-BBCode surfaces: DialogueFormat
## .skill_parts() (the raw Dictionary a discrete Control row needs) and
## DialogueEffect.cost_tag()/DialogueChoice.cost_tags() (the "what does
## this choice cost me" preview that today only ever appears AFTER the
## player has already committed to a choice).
##
## wants_world() is not overridden — every check here goes through
## SkillCalculator/DialogueFormat/DialogueChoice directly, none of it
## touches WorldManager or navigation.
##
## DialogueManager.participants is real autoload state, shared with
## every other dialogue suite — saved and restored around this run the
## same way test_gaze_follows_the_speaker.gd already does.

var _saved_participants: Dictionary = {}


func run() -> void:
	_saved_participants = DialogueManager.participants.duplicate()

	var actor: Unit = spawn_unit(&"player", 10, 12, 20, [melee()], Vector3.ZERO)
	var companion: Unit = spawn_unit(&"player", 10, 10, 20, [melee()], Vector3(2.0, 0.0, 0.0))
	companion.display_name = "Helper"
	await get_tree().process_frame
	await _the_dice_never_hang_without_a_popup()

	# Stealth (data/skills/stealth.tres): AVERAGE (-1) difficulty. Trained
	# level for DX 12, levels_purchased 1 (the base):
	# 12 + (-1) + (1 - 1) = 11 — see SkillInstance.get_relative_skill_level.
	# Acrobatics (data/skills/acrobatics.tres) is left UNTRAINED on this
	# same actor and used for the case-2 checks below instead of Stealth
	# itself, so the trained/untrained checks can't be satisfied by
	# accidentally reading the same number twice. Its default is DX-6:
	# 12 + (-6) = 6.
	var stealth: Skill = load("res://data/skills/stealth.tres")
	var stealth_instance: SkillInstance = SkillInstance.new()
	stealth_instance.skill_data = stealth
	stealth_instance.levels_purchased = 1
	_root.add_child(stealth_instance)
	actor.add_skill(stealth_instance)

	DialogueManager.participants = {"player": actor}

	# --- case 1: trained shows its level, plainly -----------------------
	var trained_choice: SkillCheckChoice = SkillCheckChoice.new()
	trained_choice.skill_name = "Stealth"
	trained_choice.text = "Sneak past."

	var trained_calc: SkillCheckResult = SkillCalculator.get_skill_level(actor, "Stealth")
	check("SETUP: SkillCalculator actually trained Stealth (is_trained)",
		trained_calc.is_trained,
		"is_trained is false — the SkillInstance never got wired to the unit")
	check("SETUP: trained level is the real computed 11, not a placeholder",
		trained_calc.skill_level == 11,
		"got %d" % trained_calc.skill_level)

	var trained_parts: Dictionary = DialogueFormat.skill_parts(trained_choice)
	check("a trained skill's target is the real computed level",
		trained_parts.target == 11,
		"got %d" % trained_parts.target)
	check("skill_parts.can_use is true for a trained skill",
		trained_parts.can_use)
	check("skill_parts.attemptable is true for a trained skill",
		trained_parts.attemptable)

	var trained_label: String = DialogueFormat.choice_label(trained_choice)
	check("the trained skill's BBCode label shows the plain number",
		trained_label.contains("Stealth 11"),
		"label was: %s" % trained_label)
	check("a trained skill's label carries no untrained annotation",
		not trained_label.contains("untrained"),
		"label was: %s" % trained_label)
	# SABOTAGE PROPOSAL: hardcode skill_tag to always append "(untrained)"
	# regardless of is_trained. Caught here — this exact check fails red.

	# --- case 2: untrained but a default resolves — a NUMBER, not the
	# word, marked untrained rather than replaced by it -------------------
	var untrained_choice: SkillCheckChoice = SkillCheckChoice.new()
	untrained_choice.skill_name = "Acrobatics"
	untrained_choice.text = "Vault the railing."

	var untrained_calc: SkillCheckResult = SkillCalculator.get_skill_level(actor, "Acrobatics")
	check("SETUP: the unit never trained Acrobatics",
		not untrained_calc.is_trained,
		"is_trained is true — this case is testing the wrong skill")
	check("SETUP: untrained default level is the real computed 6, not a placeholder",
		untrained_calc.skill_level == 6,
		"got %d" % untrained_calc.skill_level)

	var untrained_parts: Dictionary = DialogueFormat.skill_parts(untrained_choice)
	check("an untrained-but-defaulted skill still reports can_use",
		untrained_parts.can_use)
	check("and attemptable, since a real default resolved",
		untrained_parts.attemptable)
	check("its target is the real computed default level, not 0",
		untrained_parts.target == 6,
		"got %d" % untrained_parts.target)

	var untrained_label: String = DialogueFormat.choice_label(untrained_choice)
	check("THE FIX: an untrained-but-attemptable skill shows a NUMBER, not the bare word",
		untrained_label.contains("Acrobatics 6"),
		"label was: %s" % untrained_label)
	check("...marked untrained rather than replaced by the word",
		untrained_label.contains("(untrained)"),
		"label was: %s" % untrained_label)
	# SABOTAGE PROPOSAL: revert skill_tag to the old 2-case
	# "%d if can_use else 'untrained'" body (attemptable and is_trained
	# collapsed back onto the old can_use). Caught here — the label would
	# read "Acrobatics untrained" with no number at all, failing the
	# "shows a NUMBER" check above.

	check("skill_parts and the BBCode tag never disagree about the untrained number",
		untrained_label.contains("Acrobatics %d" % untrained_parts.target),
		"parts.target=%d but label was: %s" % [untrained_parts.target, untrained_label])

	# --- case 3: genuinely impossible — no skill_data at all, so no
	# default could ever resolve. The honest treatment chosen is a plain
	# non-numeric word ("cannot attempt"), never a 0. ---------------------
	var impossible_choice: SkillCheckChoice = SkillCheckChoice.new()
	impossible_choice.skill_name = "Nonexistent Skill Xyzzy"
	impossible_choice.text = "Attempt the impossible."

	var impossible_calc: SkillCheckResult = SkillCalculator.get_skill_level(actor, "Nonexistent Skill Xyzzy")
	check("SETUP: the nonexistent skill really has no data to resolve",
		not impossible_calc.can_use_skill and not impossible_calc.attemptable,
		"can_use=%s attemptable=%s — SkillDatabase found something unexpected" % [
			impossible_calc.can_use_skill, impossible_calc.attemptable])

	var impossible_parts: Dictionary = DialogueFormat.skill_parts(impossible_choice)
	check("a genuinely impossible skill is not attemptable",
		not impossible_parts.attemptable)
	check("and not usable",
		not impossible_parts.can_use)

	var impossible_label: String = DialogueFormat.choice_label(impossible_choice)
	check("the impossible case's chosen honest treatment renders",
		impossible_label.contains("cannot attempt"),
		"label was: %s" % impossible_label)
	check("and NEVER prints a fake target number for it",
		not impossible_label.contains("Nonexistent Skill Xyzzy 0"),
		"label was: %s" % impossible_label)
	# SABOTAGE PROPOSAL: make skill_tag fall through to "%d" % target
	# whenever attemptable is unset/defaulted true instead of explicitly
	# false. Caught here — the label would read "...Xyzzy 0", a genuine
	# lie about an unresolvable skill, and both checks above go red.

	# --- assist: a present companion's bonus is folded into the number
	# AND the assistant is named on the row -------------------------------
	DialogueManager.participants = {"player": actor, "ally": companion}

	var assisted_parts: Dictionary = DialogueFormat.skill_parts(trained_choice)
	check("a present, qualifying companion is named as the assistant",
		assisted_parts.assistant == "Helper",
		"assistant was: '%s'" % assisted_parts.assistant)
	check("...and their flat bonus is folded into the target",
		assisted_parts.target == trained_parts.target + DialogueManager.ASSIST_BONUS,
		"was %d, now %d, expected %d" % [
			trained_parts.target, assisted_parts.target, trained_parts.target + DialogueManager.ASSIST_BONUS])

	var assisted_label: String = DialogueFormat.choice_label(trained_choice)
	check("skill_parts and skill_tag agree on the assisted number too",
		assisted_label.contains("Stealth %d" % assisted_parts.target),
		"parts.target=%d but label was: %s" % [assisted_parts.target, assisted_label])
	check("with no companion present, no one is named",
		trained_parts.assistant == "",
		"assistant was '%s' with no companion in participants" % trained_parts.assistant)
	# SABOTAGE PROPOSAL: have find_assisting_companion's bonus keep
	# folding into skill_parts.target but stop populating the assistant
	# field (leave it ""). Caught here — the assistant-name check goes
	# red even though the numeric target check alone would still pass,
	# which is why both are asserted rather than just the number.

	DialogueManager.participants = {"player": actor}

	# --- Task 2b: cost previews ------------------------------------------
	var priced_choice: LineChoice = LineChoice.new()
	priced_choice.text = "Offer blood."
	var hp_cost: SacrificeHpEffect = SacrificeHpEffect.new()
	hp_cost.amount = 5
	priced_choice.effects.append(hp_cost)

	var priced_tags: PackedStringArray = priced_choice.cost_tags()
	check("a choice with a sacrifice effect reports a non-empty cost tag",
		priced_tags.size() == 1,
		"got %d tags: %s" % [priced_tags.size(), priced_tags])
	check("...with the real amount baked in, not a placeholder",
		priced_tags.size() > 0 and priced_tags[0] == "-5 HP",
		"got: %s" % priced_tags)

	var pricier_choice: LineChoice = LineChoice.new()
	pricier_choice.text = "Offer more blood."
	var pricier_hp_cost: SacrificeHpEffect = SacrificeHpEffect.new()
	pricier_hp_cost.amount = 12
	pricier_choice.effects.append(pricier_hp_cost)
	check("the cost tag actually reflects the effect's own amount, not a fixed string",
		pricier_choice.cost_tags()[0] == "-12 HP" and pricier_choice.cost_tags()[0] != priced_tags[0],
		"5-cost tag: %s, 12-cost tag: %s" % [priced_tags[0], pricier_choice.cost_tags()[0]])
	# SABOTAGE PROPOSAL: hardcode SacrificeHpEffect.cost_tag() to return
	# "-5 HP" unconditionally instead of using `amount`. Caught here — the
	# 12-cost choice would report "-5 HP" too, failing the inequality half
	# of the check above.

	var plain_choice: LineChoice = LineChoice.new()
	plain_choice.text = "Just talk."
	check("a plain choice with no effects reports no cost at all",
		plain_choice.cost_tags().is_empty(),
		"got: %s" % plain_choice.cost_tags())

	var give_choice: LineChoice = LineChoice.new()
	give_choice.text = "Receive a gift."
	var grant: GiveItemEffect = GiveItemEffect.new()
	give_choice.effects.append(grant)
	check("a GRANTING effect (not a cost) reports no cost tag either",
		give_choice.cost_tags().is_empty(),
		"got: %s" % give_choice.cost_tags())
	# SABOTAGE PROPOSAL: make DialogueEffect's base cost_tag() return a
	# non-empty placeholder like "?" instead of "". Caught here — both the
	# plain-choice and the granting-effect checks above go red.

	_cleanup()


func _cleanup() -> void:
	DialogueManager.participants = _saved_participants


## A skill check must not hang when nothing is presenting the dice.
##
## The popup is the only listener for dice_roll_requested and the only
## emitter of dice_roll_finished. Both choice types used to emit and then
## await that pair directly, so in any scene with no popup — this one, a
## stripped export, a frame before the popup is ready — the await never
## returned and the conversation stopped forever with no timeout. The
## guard lives in DialogueManager.present_dice_roll.
##
## Asserted in BOTH directions, because a guard that always skips the wait
## would pass the first check on its own.
func _the_dice_never_hang_without_a_popup() -> void:
	check("SETUP: nothing in this scene is presenting dice",
		DialogueManager.dice_roll_requested.get_connections().is_empty(),
		"something is connected, so the unattended case is not what is " +
		"being tested here")

	var unattended: Dictionary = {"done": false}
	_present(unattended)
	await get_tree().process_frame
	await get_tree().process_frame
	check("a check resolves with no dice popup in the tree",
		unattended["done"],
		"present_dice_roll never returned — this is the hang: an await on " +
		"a signal whose only emitter does not exist")

	# Positive control: a listener that answers must still be waited for.
	var answered: Dictionary = {"done": false, "saw": false}
	var listener: Callable = func(_skill: String, _roll: Dictionary) -> void:
		answered["saw"] = true
	DialogueManager.dice_roll_requested.connect(listener)
	_present(answered)
	await get_tree().process_frame
	check("SETUP: the listener was reached",
		answered["saw"],
		"the emit never got to a connected listener")
	check("and a presented roll is actually waited for",
		not answered["done"],
		"present_dice_roll returned without waiting even though something " +
		"was listening, so the guard is skipping unconditionally")
	DialogueManager.dice_roll_finished.emit()
	await get_tree().process_frame
	check("until the presentation reports finished",
		answered["done"],
		"the wait never ended after dice_roll_finished")
	DialogueManager.dice_roll_requested.disconnect(listener)


## Started, deliberately not awaited: the point is whether it comes back.
func _present(flag: Dictionary) -> void:
	await DialogueManager.present_dice_roll("Stealth", {
		"success": true, "roll": 9, "target": 11, "margin": 2})
	flag["done"] = true
