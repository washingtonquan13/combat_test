extends Node
## Autoload singleton. Register as "FlagManager" under Project > Project
## Settings > AutoLoad.
##
## Global, string-keyed world state: "did X happen," "has this been
## seen," anything dialogue — and, later, any other system — needs to
## remember beyond a single moment. Deliberately NOT owned by
## DialogueManager: DialogueManager's own state (used_choices,
## transcript) is explicitly PER-CONVERSATION and clears on every
## start_dialogue() call, which is the opposite of what a flag needs to
## do. A flag is world state, not conversation state — it has to survive
## leaving and re-entering a conversation, and it has to be settable by
## things that aren't dialogue at all (an item pickup, a fight's outcome)
## without those systems needing to know DialogueManager exists.
##
## Not persisted to disk — this project has no save system yet, so flags
## currently live only for the running session, same as everything else
## un-saved right now.

var _flags: Dictionary = {}


## value defaults to true for the common "did this happen yet" case, so
## the call site reads naturally: set_flag("met_npc"). Still accepts any
## Variant (an int counter, a string state) for a flag that ends up
## needing more than yes/no, without this API needing to change later.
func set_flag(flag_name: String, value: Variant = true) -> void:
	_flags[flag_name] = value


func get_flag(flag_name: String, default: Variant = false) -> Variant:
	return _flags.get(flag_name, default)


func has_flag(flag_name: String) -> bool:
	return _flags.has(flag_name)


func clear_flag(flag_name: String) -> void:
	_flags.erase(flag_name)


## Every currently-set flag name starting with prefix — lets a consumer
## that owns a reserved namespace within this flat dictionary (see
## AreaState's "areastate/" prefix) enumerate and clear its own flags as
## a unit, without this file needing to know that namespace exists.
func get_flag_names_with_prefix(prefix: String) -> Array[String]:
	var matches: Array[String] = []
	for flag_name in _flags:
		if flag_name.begins_with(prefix):
			matches.append(flag_name)
	return matches
