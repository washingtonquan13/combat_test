class_name TerminalMenu
extends Resource
## A list of choices on a Terminal's screen, like a Fallout terminal's: a
## line of text over a column of entries, one highlighted. Up/Down or the
## mouse picks one, Enter or a click opens it, Tab goes back a level.
## Terminal.menu is the top one; an entry can open another (a submenu).

## Shown over the entries, in BBCode: a greeting, a status line.
@export_multiline var intro: String = ""
@export var entries: Array[TerminalEntry] = []


## The entries the player can see now (TerminalEntry.requires_flag).
func shown_entries() -> Array[TerminalEntry]:
	var shown: Array[TerminalEntry] = []
	for entry in entries:
		if entry and entry.is_shown():
			shown.append(entry)
	return shown
