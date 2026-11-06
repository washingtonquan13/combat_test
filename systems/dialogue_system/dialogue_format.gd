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
## Conversation.find_assisting_companion) is already folded into
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


## The full response label for one snapshot choice entry (see
## Conversation.describe_choice) — alignment tag (if any) + skill tag/
## target preview (if any, and only if that check isn't hidden) + the
## response text itself. A hidden check collapses to "???", same as the
## old system. Works from display data, not from the DialogueChoice
## resource: the conversation already computed the number with the same
## code that rolls, so nothing here touches SkillCalculator.
static func choice_label(entry: Dictionary) -> String:
	var check: Dictionary = entry.get("check", {})
	if check.get("hidden", false):
		return "???"

	var tags: Array[String] = []
	var alignment: String = alignment_tag(entry.get("alignment", ""))
	if alignment != "":
		tags.append(alignment)
	if not check.is_empty():
		tags.append(skill_tag(check.skill, check.target, check.attemptable, check.is_trained))
	tags.append(entry.get("text", ""))
	return " ".join(tags)


## The verdict word for a finished roll — shared by the transcript's
## result aside and anything else that names a roll's outcome.
static func skill_verdict(roll: Dictionary) -> String:
	if roll.critical_success:
		return "Critically succeeded"
	if roll.critical_failure:
		return "Critically failed"
	return "Succeeded" if roll.success else "Failed"


## Plain text, no BBCode: this goes into the structured transcript, and
## entry_bbcode() colors the verdict and the skill name when a presenter
## wants them colored. roll is the full SuccessRoll.roll_vs() Dictionary,
## so a critical success/failure is named rather than dropped. assistant
## is whoever's assist bonus applied, credited by name.
static func skill_result(skill_name: String, roll: Dictionary, assistant: Unit = null) -> String:
	var assist_note: String = " (%s helped)" % assistant.get_display_name() if assistant else ""
	return "%s at a %s check%s — rolled %d vs target %d" % [
		skill_verdict(roll), skill_name, assist_note, roll.roll, roll.target
	]


## The GURPS Quick Contest readout — both sides' own roll vs their own
## target, side by side, so a loss against a strong NPC reads as exactly
## that rather than a bare pass/fail. Plain text, same reason as
## skill_result(). See QuickContestChoice._wins_contest for how
## actor_wins gets decided.
static func contest_result(actor_skill_name: String, actor_roll: Dictionary, npc_skill_name: String, npc_roll: Dictionary, actor_wins: bool) -> String:
	var verdict: String = "You win the contest" if actor_wins else "You lose the contest"
	return "%s — your %s rolled %d vs %d, their %s rolled %d vs %d" % [
		verdict, actor_skill_name, actor_roll.roll, actor_roll.target, npc_skill_name, npc_roll.roll, npc_roll.target
	]


## One transcript entry (see Conversation.record) as BBCode — the single
## place the transcript's look is decided, shared by the conversation log
## and by the negotiation's echo to SystemLog. The transcript itself
## holds no BBCode, so a different presenter can style it differently.
##   line: bold speaker name on its own line, then the text
##   alignment aside: the "(Lawful)" part in that alignment's color
##   check aside: the verdict in success/failure color, and each skill
##     named in the entry's skills extra in white
##   any other aside (a mood note, a pardon): the text as-is
static func entry_bbcode(entry: Dictionary) -> String:
	var text: String = entry.get("text", "")
	if entry.get("kind", &"aside") == &"line":
		return speaker_line(entry.get("name", ""), text)

	match entry.get("tag", &""):
		&"alignment":
			var alignment: String = entry.get("alignment", "")
			return text.replace("(%s)" % alignment, alignment_tag(alignment))
		&"check":
			var verdict: String = entry.get("verdict", "")
			var color: Color = success_color if entry.get("success", false) else failure_color
			var styled: String = text
			if verdict != "" and styled.begins_with(verdict):
				styled = "[color=#%s]%s[/color]%s" % [color.to_html(false), verdict, styled.substr(verdict.length())]
			# Each skill name named in the extras, in order, in white — the
			# cursor keeps "Persuasion vs Persuasion" from whitening one
			# occurrence twice.
			var cursor: int = verdict.length()
			for skill in entry.get("skills", []):
				var at: int = styled.find(skill, cursor)
				if at < 0:
					continue
				var white: String = "[color=#FFFFFF]%s[/color]" % skill
				styled = styled.substr(0, at) + white + styled.substr(at + skill.length())
				cursor = at + white.length()
			return styled
	return text


## One transcript entry as the conversation log shows it: a line as
## entry_bbcode() renders it, an aside additionally dimmed and italic so
## the log reads spoken words apart from the system's own notes.
static func log_bbcode(entry: Dictionary) -> String:
	var styled: String = entry_bbcode(entry)
	if entry.get("kind", &"aside") == &"line":
		return styled
	return "[color=#A0A0A0][i]%s[/i][/color]" % styled
