class_name TerminalEntry
extends Resource
## One line of a TerminalMenu. Opening it does the first of these that is
## set: runs exam, goes down into submenu, or shows page. Setting more than
## one is an authoring error; the others are ignored.

@export var label: String = ""
## A page of text, in BBCode (a log entry, a memo).
@export_multiline var page: String = ""
@export var submenu: TerminalMenu = null
## A multiple-choice exam (see TerminalExam).
@export var exam: TerminalExam = null
## Set to true when the entry is opened: reading a log is story state that
## dialogue or a quest can ask about.
@export var sets_flag: String = ""
## Only listed while this flag is set (a password found, a door unlocked).
@export var requires_flag: String = ""


func is_shown() -> bool:
	return requires_flag.is_empty() or bool(FlagManager.get_flag(requires_flag, false))
