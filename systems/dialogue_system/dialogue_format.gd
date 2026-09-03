class_name DialogueFormat
extends RefCounted
## Small BBCode-formatting helpers for the dialogue UI — same role
## log_format.gd already plays for the combat log, kept as its own file
## since dialogue's palette (alignment tags, skill tags, pass/fail) has
## nothing to do with SystemLog's (player/enemy/damage/heal). Ported
## from the old GURPS-project DialogueBox's format_* methods, which hung
## these off the UI Control itself — relocated here as static helpers so
## both the overlay AND the conversation log can call the same
## formatting without either one owning it.

## Four tags, not six — Good/Evil dropped. This project's alignment model
## is two independent axes (see Unit.alignment/tendency): Chaos-Neutral-
## Law and Dark-Neutral-Light. There's no separate good/evil spectrum,
## so a choice tag can only ever be one of these four (or "" for no
## shift) — matches what Unit.apply_alignment_tag() actually recognizes.
static var alignment_colors: Dictionary = {
	"Light": Color(0.541, 0.706, 1.0),
	"Dark": Color(0.6, 0.4, 0.8),
	"Lawful": Color(0.706, 0.706, 0.706),
	"Chaotic": Color(0.490, 0.627, 0.769),
}
static var skill_tag_color: Color = Color(0.5, 1.0, 0.5)
static var success_color: Color = Color(0.533, 0.8, 0.533)
static var failure_color: Color = Color(0.8, 0.533, 0.533)


static func alignment_tag(alignment_name: String) -> String:
	if alignment_name == "" or not alignment_colors.has(alignment_name):
		return alignment_name
	return "[color=#%s](%s)[/color]" % [alignment_colors[alignment_name].to_html(false), alignment_name]


## Bold name on its own line, then the text — a long line wrapping to
## multiple lines never risks the name blending into the paragraph the
## way an inline "Name: text" would. Split from speaker_line() below so
## dialogue_overlay.gd's live SpeakerLabel (name pinned above the
## scrolling body text, not part of it) can use just the name half —
## the transcript still gets both together via speaker_line(), so
## neither can drift into its own near-identical format of "who said
## this."
static func speaker_name_tag(speaker_name: String) -> String:
	return "[b]%s[/b]" % speaker_name


static func speaker_line(speaker_name: String, text: String) -> String:
	return "%s\n%s" % [speaker_name_tag(speaker_name), text]


## target/attemptable turn this into the DC/modifier preview — this is a
## roll-UNDER system (SuccessRoll: 3d6 <= target succeeds), so target IS
## the full number to beat, not a DC alongside a separate modifier.
## No separate assist marker: a present companion's bonus (see
## DialogueManager.find_assisting_companion) is already folded into
## target by the caller, so the number shown is already the real one —
## a "+" suffix here would misread as d20-style "need 12 or higher,"
## backwards for a system where lower rolls are better.
##
## 2026-09 rework (the one approved-mockup change: "untrained skills
## should show skill levels like trained skills do") — three cases, not
## the old two:
## - attemptable && is_trained: plain number, exactly as before.
## - attemptable && !is_trained: the number IS shown now (this is the
##   actual fix), annotated "(untrained)" rather than replaced by the
##   word — SkillCalculator.get_skill_level already computes a real,
##   honest target for a default-derived attempt; hiding it behind a
##   word was the bug, per the user's own request.
## - !attemptable: skill_level is a pure floor with zero information
##   behind it (see SkillCheckResult.attemptable) — printing it as a
##   number would be the misleading-0 this file's old comment already
##   worried about, just reached a different way. "cannot attempt" is
##   the honest word for THIS case; it's deliberately not "untrained"
##   any more, now that "untrained" means something more specific above.
## is_trained defaults to true so a 3-arg call (attemptable standing in
## for the old can_use) renders exactly as before — nothing outside this
## file currently calls skill_tag directly, but the signature stays
## backward-compatible on purpose.
static func skill_tag(skill_name: String, target: int, attemptable: bool, is_trained: bool = true) -> String:
	if skill_name == "":
		return ""
	var target_text: String
	if not attemptable:
		target_text = "cannot attempt"
	elif is_trained:
		target_text = "%d" % target
	else:
		target_text = "%d (untrained)" % target
	return "[color=#%s]|%s %s|[/color]" % [skill_tag_color.to_html(false), skill_name, target_text]


## The full response-button label for one choice — alignment tag (if
## any) + skill tag/DC preview (if any, and only if that check isn't
## hidden) + the response text itself. A hidden SkillCheckChoice/
## QuickContestChoice (show_to_player == false) collapses to "???"
## instead, same as the old system.
static func choice_label(choice: DialogueChoice) -> String:
	if (choice is SkillCheckChoice or choice is QuickContestChoice) and not choice.show_to_player:
		return "???"

	var tags: Array[String] = []
	var alignment: String = alignment_tag(choice.alignment_name)
	if alignment != "":
		tags.append(alignment)
	if choice is SkillCheckChoice or choice is QuickContestChoice:
		tags.append(_skill_preview_tag(choice))
	tags.append(choice.text)
	return " ".join(tags)


## Shared by SkillCheckChoice and QuickContestChoice — both just need
## "what's MY side's number." A contest's NPC-side target is
## deliberately not previewed here — unknown information going in,
## same as the player never sees an enemy's exact defenses ahead of an
## attack roll.
##
## Routes through _resolve_skill_preview() — the same private resolver
## skill_parts() below calls — so this BBCode tag and that Dictionary
## can never disagree about the number.
static func _skill_preview_tag(choice: DialogueChoice) -> String:
	var raw: Dictionary = _resolve_skill_preview(choice)
	if raw.skill == "":
		return ""
	if raw.hidden:
		return skill_tag(raw.skill, 0, false)
	return skill_tag(raw.skill, raw.target, raw.attemptable, raw.is_trained)


## Full internal resolution for one choice's skill-check preview —
## everything both _skill_preview_tag (BBCode, for the response button/
## transcript) and skill_parts (raw Dictionary, for a discrete Control
## row) need, computed exactly once so neither can drift from the
## other. Not part of the public API: skill_parts strips this down to
## the 6 keys a view actually needs (an assistant Unit, not just its
## name; is_trained, which skill_parts intentionally does not expose —
## see that function's own header).
static func _resolve_skill_preview(choice: DialogueChoice) -> Dictionary:
	var is_check: bool = choice is SkillCheckChoice or choice is QuickContestChoice
	if not is_check:
		return {"skill": "", "target": 0, "can_use": false, "attemptable": false,
			"is_trained": false, "assistant": null, "hidden": false}

	var hidden: bool = not choice.show_to_player
	var actor: Unit = DialogueManager.participants.get("player")
	if not actor:
		return {"skill": choice.skill_name, "target": 0, "can_use": false, "attemptable": false,
			"is_trained": false, "assistant": null, "hidden": hidden}

	var result: SkillCheckResult = SkillCalculator.get_skill_level(actor, choice.skill_name)
	var assistant: Unit = DialogueManager.find_assisting_companion(choice.skill_name)
	var target: int = result.skill_level + (DialogueManager.ASSIST_BONUS if assistant else 0)
	return {
		"skill": choice.skill_name,
		"target": target,
		"can_use": result.can_use_skill,
		"attemptable": result.attemptable,
		"is_trained": result.is_trained,
		"assistant": assistant,
		"hidden": hidden,
	}


## Non-BBCode view of the same "what does this choice's check look
## like" data _skill_preview_tag renders as a string — the discrete-
## Control rewrite needs raw fields to lay out and color itself, not a
## baked BBCode fragment it would have to re-parse. Reuses
## _resolve_skill_preview() (same resolution _skill_preview_tag itself
## now routes through), so the number shown here can never disagree
## with the one still baked into choice_label's BBCode string.
##
## Returns exactly:
## - skill: String — "" when choice isn't a check at all (LineChoice,
##   NegotiationLineChoice, etc.), the "this isn't a check" case.
## - target: int — the roll-under target, assist bonus already folded
##   in, same value skill_result()/skill_check_choice.gd will actually
##   roll against.
## - can_use: bool — SkillCalculator's own can_use_skill: the roll can
##   actually be attempted at this target, even when that target is an
##   honest 0.
## - attemptable: bool — strictly narrower than can_use (see
##   SkillCheckResult.attemptable); false only in the rare case where
##   can_use is true purely because the skill isn't learned_only and
##   lists some defaults, but none of them actually resolved. A row
##   should treat !attemptable as "cannot attempt," not as a defaulted
##   0 — see skill_tag's own header for the full 3-case rendering this
##   mirrors.
## - assistant: String — the assisting companion's display name, or ""
##   with no one helping. Surfaced as its own field, not folded into a
##   BBCode aside the way skill_result()'s assist_note is, because the
##   approved row design names who's helping ON the row itself, before
##   the roll — today that name only appears afterward, in the result
##   line.
## - hidden: bool — true when show_to_player is false (SkillCheckChoice/
##   QuickContestChoice); a discrete row still needs to know to render
##   "???" in place of the real preview, same as choice_label already
##   does inline for the BBCode path.
static func skill_parts(choice: DialogueChoice) -> Dictionary:
	var raw: Dictionary = _resolve_skill_preview(choice)
	var assistant: Unit = raw.assistant
	return {
		"skill": raw.skill,
		"target": raw.target,
		"can_use": raw.can_use,
		"attemptable": raw.attemptable,
		"assistant": assistant.get_display_name() if assistant else "",
		"hidden": raw.hidden,
	}


## roll is the full SuccessRoll.roll_vs() Dictionary — surfaces the
## critical success/failure GURPS already computes there (the old
## signature took separate rolled/target/success values and silently
## dropped that information). assistant is whoever's
## find_assisting_companion() bonus applied, if any, credited by name.
static func skill_result(skill_name: String, roll: Dictionary, assistant: Unit = null) -> String:
	var color: Color = success_color if roll.success else failure_color
	var verdict: String = "Failed"
	if roll.critical_success:
		verdict = "Critically succeeded"
	elif roll.critical_failure:
		verdict = "Critically failed"
	elif roll.success:
		verdict = "Succeeded"
	var assist_note: String = " (%s helped)" % assistant.get_display_name() if assistant else ""
	return "[color=#%s]%s[/color] at a [color=#FFFFFF]%s[/color] check%s — rolled %d vs target %d" % [
		color.to_html(false), verdict, skill_name, assist_note, roll.roll, roll.target
	]


## The GURPS Quick Contest readout — both sides' own roll vs their own
## target, side by side, so a loss against a strong NPC reads as
## exactly that rather than a bare pass/fail. See
## QuickContestChoice._wins_contest for how actor_wins gets decided.
static func contest_result(actor_skill_name: String, actor_roll: Dictionary, npc_skill_name: String, npc_roll: Dictionary, actor_wins: bool) -> String:
	var color: Color = success_color if actor_wins else failure_color
	var verdict: String = "You win the contest" if actor_wins else "You lose the contest"
	return "[color=#%s]%s[/color] — your [color=#FFFFFF]%s[/color] rolled %d vs %d, their [color=#FFFFFF]%s[/color] rolled %d vs %d" % [
		color.to_html(false), verdict, actor_skill_name, actor_roll.roll, actor_roll.target, npc_skill_name, npc_roll.roll, npc_roll.target
	]
