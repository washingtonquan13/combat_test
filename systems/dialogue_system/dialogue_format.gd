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


## target/can_use turn this into the DC/modifier preview — this is a
## roll-UNDER system (SuccessRoll: 3d6 <= target succeeds), so target
## IS the full number to beat, not a DC alongside a separate modifier —
## just the plain skill name and that number, "untrained" instead of a
## misleading 0 if there's no way to attempt it at all. No separate
## assist marker: a present companion's bonus (see
## DialogueManager.find_assisting_companion) is already folded into
## target by the caller, so the number shown is already the real one —
## a "+" suffix here would misread as d20-style "need 12 or higher,"
## backwards for a system where lower rolls are better.
static func skill_tag(skill_name: String, target: int, can_use: bool) -> String:
	if skill_name == "":
		return ""
	var target_text: String = "%d" % target if can_use else "untrained"
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
static func _skill_preview_tag(choice: DialogueChoice) -> String:
	var actor: Unit = DialogueManager.participants.get("player")
	if not actor:
		return skill_tag(choice.skill_name, 0, false)
	var result: SkillCheckResult = SkillCalculator.get_skill_level(actor, choice.skill_name)
	var assistant: Unit = DialogueManager.find_assisting_companion(choice.skill_name)
	var target: int = result.skill_level + (DialogueManager.ASSIST_BONUS if assistant else 0)
	return skill_tag(choice.skill_name, target, result.can_use_skill)


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
