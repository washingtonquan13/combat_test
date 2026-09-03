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
## Persisted via save_state()/load_state() below — see SaveManager, the
## one caller of both. Serializing this single flat dictionary carries
## quest progress (quest.gd derives "which stage" from these flags at
## READ time rather than storing it separately — see that file's own
## header) and all of AreaState's per-area records (phase 2 put those
## behind this same dictionary, under a reserved "areastate/" prefix)
## along for free, with no separate save path for either.

var _flags: Dictionary = {}


## Registered from HERE rather than named by SaveManager: adding a system
## that persists should never be an edit to the save system again, and a
## hand-maintained list somewhere else is a second place to remember
## something.
##
## DEFERRED because this autoload is created BEFORE SaveManager (see
## project.godot's [autoload] order) — the `SaveManager` identifier cannot
## be resolved yet while this _ready() runs. A deferred call lands once
## every autoload is up, which is still long before anything can ask for a
## save.
func _ready() -> void:
	_register_persistence.call_deferred()


## No `after`: load_state() below is a single assignment off the save's own
## dictionary and reads no other system's restored state, so nothing but
## registration order orders it.
func _register_persistence() -> void:
	SaveManager.register(&"flags", self)


## duplicate(true) — a DEEP copy, not the live dictionary. AreaState's
## own values are themselves Dictionaries (a stash's item list, e.g.),
## so a shallow copy would hand the caller (SaveManager, about to write
## this to a ConfigFile) a container that still aliases this file's own
## nested data.
func save_state() -> Dictionary:
	return _flags.duplicate(true)


func load_state(state: Dictionary) -> void:
	_flags = state.duplicate(true)


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
