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

static var alignment_colors: Dictionary = {
	"Light": Color(0.541, 0.706, 1.0),
	"Dark": Color(0.6, 0.4, 0.8),
	"Good": Color(0.812, 0.686, 0.431),
	"Evil": Color(0.631, 0.224, 0.180),
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


## The shared "who said this" formatting — a bold name on its own line,
## then the line itself, so a long line wrapping to multiple lines never
## risks the name blending into the paragraph the way an inline
## "Name: text" would. Used by BOTH dialogue_overlay.gd (the current
## line) and DialogueManager.record_line (the transcript) so they can
## never drift into two near-identical formats of the same thing.
static func speaker_line(speaker_name: String, text: String) -> String:
	return "[b]%s[/b]\n%s" % [speaker_name, text]


static func skill_tag(skill_name: String) -> String:
	if skill_name == "":
		return ""
	return "[color=#%s]|%s|[/color]" % [skill_tag_color.to_html(false), skill_name]


## The full response-button label for one choice — alignment tag (if
## any) + skill tag (if any, and only if that check isn't hidden) +
## the response text itself. A hidden SkillCheckChoice (show_to_player
## == false) collapses to "???" instead, same as the old system.
static func choice_label(choice: DialogueChoice) -> String:
	if choice is SkillCheckChoice and not choice.show_to_player:
		return "???"

	var tags: Array[String] = []
	var alignment: String = alignment_tag(choice.alignment_name)
	if alignment != "":
		tags.append(alignment)
	if choice is SkillCheckChoice:
		var skill: String = skill_tag(choice.skill_name)
		if skill != "":
			tags.append(skill)
	tags.append(choice.text)
	return " ".join(tags)


static func skill_result(skill_name: String, rolled: int, target: int, success: bool) -> String:
	var color: Color = success_color if success else failure_color
	var verdict: String = "Succeeded" if success else "Failed"
	return "[color=#%s]%s[/color] at a [color=#FFFFFF]%s[/color] check — rolled %d vs target %d" % [
		color.to_html(false), verdict, skill_name, rolled, target
	]
