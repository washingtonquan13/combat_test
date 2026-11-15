class_name FlagPrerequisite
extends PrerequisiteRule
## Requires a FlagManager flag to be set — or, if requires_absent, to NOT
## be set. Lives alongside skill_prerequisite.gd/count_prerequisite.gd
## rather than in a separate condition system of its own: PrerequisiteRule's
## composition (CountPrerequisite's AND/OR/N-of-M, already nestable
## arbitrarily deep) was already general enough to reuse for dialogue-
## choice gating without building a second, competing mechanism. Folder
## location is a leftover of PrerequisiteRule having been built for
## skills first — nothing about the base class or CountPrerequisite is
## actually skill-specific.
##
## Ignores the unit parameter entirely, unlike every other current
## PrerequisiteRule subclass — a flag is global world state, not
## per-character, so which unit is asking doesn't change the answer.

## What this is called in a dialogue file (see DialogueScript).
const SCRIPT_WORDS: PackedStringArray = ["flag", "noflag"]

@export var flag_name: String = ""
@export var requires_absent: bool = false


func is_satisfied(_unit: Unit) -> bool:
	var flag_set: bool = FlagManager.has_flag(flag_name)
	return not flag_set if requires_absent else flag_set


## "flag met_the_mayor", or "noflag met_the_mayor" for its absence.
func read_script(word: String, args: PackedStringArray, _where: String) -> String:
	if args.size() != 1:
		return "'%s' is followed by one flag name." % word
	flag_name = args[0]
	requires_absent = word == "noflag"
	return ""
